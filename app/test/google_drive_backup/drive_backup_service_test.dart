import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:totals/repositories/runtime_lock_repository.dart';
import 'package:totals/services/data_export_import_service.dart';
import 'package:totals/services/google_drive_backup/drive_api_client.dart';
import 'package:totals/services/google_drive_backup/drive_backup_models.dart';
import 'package:totals/services/google_drive_backup/drive_backup_service.dart';
import 'package:totals/services/google_drive_backup/drive_backup_settings_service.dart';
import 'package:totals/services/telegram_backup/telegram_backup_crypto.dart';
import 'package:totals_google_auth/totals_google_auth.dart';

const String _exportJson = '{"schemaVersion":12,"transactions":[]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connecting creates a recovery key and the first backup restores',
      () async {
    final harness = await _createHarness();

    final connection = await harness.service.connect();

    expect(connection, isNotNull);
    expect(connection!.shouldShowRecoveryKey, isTrue);
    expect(connection.existingBackupCount, 0);
    expect(connection.config.accountEmail, 'me@example.com');
    expect(await harness.settings.readRecoveryKey(), isNotNull);

    final entry = await harness.service.backupNow();
    final stored = harness.drive.files.values.single;

    expect(entry.encrypted, isTrue);
    expect(entry.keyId, await harness.service.currentKeyId());
    expect(stored.name, endsWith('.totals'));
    expect(utf8.decode(stored.bytes, allowMalformed: true),
        isNot(contains('schemaVersion')));
    expect(harness.settings.config.value?.lastBackupAt, entry.createdAt);

    final backups = await harness.service.listBackups();
    expect(backups.single.fileId, entry.fileId);
    expect(await harness.service.downloadBackup(backups.single), _exportJson);
  });

  test('plain backups upload readable JSON', () async {
    final harness = await _createHarness();
    await harness.service.connect();
    await harness.service.setEncrypt(false);

    final entry = await harness.service.backupNow();

    expect(entry.encrypted, isFalse);
    expect(entry.keyId, isNull);
    final stored = harness.drive.files[entry.fileId]!;
    expect(stored.name, endsWith('.json'));
    expect(utf8.decode(stored.bytes), _exportJson);
    expect(await harness.service.downloadBackup(entry), _exportJson);
  });

  test('a changed backup file is rejected', () async {
    final harness = await _createHarness();
    await harness.service.connect();
    final entry = await harness.service.backupNow();
    harness.drive.files[entry.fileId]!.bytes[0] ^= 0xff;

    await expectLater(
      harness.service.downloadBackup(entry),
      throwsA(
        isA<DriveBackupException>().having(
          (error) => error.message,
          'message',
          contains('changed'),
        ),
      ),
    );
  });

  test('old backups beyond the keep count are deleted', () async {
    final harness = await _createHarness();
    await harness.service.connect();
    await harness.service.setKeepCount(3);

    final created = <DriveBackupEntry>[];
    for (var i = 0; i < 5; i++) {
      created.add(await harness.service.backupNow());
      // Keeps creation times distinct so newest-first order is defined.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    final remaining = await harness.service.listBackups();
    expect(
      remaining.map((entry) => entry.fileId),
      created.reversed.take(3).map((entry) => entry.fileId),
    );
  });

  test('another device needs the recovery key of existing backups', () async {
    final first = await _createHarness();
    final firstConnection = await first.service.connect();
    await first.service.backupNow();

    // A fresh install sees the same Drive without the recovery key.
    final second = await _createHarness(drive: first.drive);

    await expectLater(
      second.service.connect(),
      throwsA(isA<DriveRecoveryKeyRequiredException>()),
    );
    await expectLater(
      second.service.connect(
        recoveryKey: TelegramBackupCrypto().generateRecoveryKey(),
      ),
      throwsA(isA<DriveRecoveryKeyInvalidException>()),
    );

    final connection = await second.service.connect(
      recoveryKey: firstConnection!.formattedRecoveryKey,
    );
    expect(connection!.shouldShowRecoveryKey, isFalse);
    expect(connection.existingBackupCount, 1);
    final backup = (await second.service.listBackups()).single;
    expect(await second.service.downloadBackup(backup), _exportJson);
  });

  test('starting fresh keeps old backups but makes a new key', () async {
    final first = await _createHarness();
    await first.service.connect();
    final oldBackup = await first.service.backupNow();

    final second = await _createHarness(drive: first.drive, seed: 8);
    final connection = await second.service.connect(startFresh: true);

    expect(connection!.shouldShowRecoveryKey, isTrue);
    expect(await second.service.currentKeyId(), isNot(oldBackup.keyId));
    await expectLater(
      second.service.downloadBackup(oldBackup),
      throwsA(isA<DriveRecoveryKeyRequiredException>()),
    );
  });

  test('a cancelled Google sign-in does not connect', () async {
    final harness = await _createHarness();
    harness.authenticator.cancel = true;

    expect(await harness.service.connect(), isNull);
    expect(harness.settings.config.value, isNull);
  });

  test('scheduled backups run only once they are due', () async {
    final harness = await _createHarness();
    await harness.service.connect();
    const summaryTime = TimeOfDay(hour: 20, minute: 0);
    final now = DateTime.now();

    expect(
      await harness.service.backupIfDue(
        now: now.add(const Duration(days: 30)),
        summaryTime: summaryTime,
      ),
      DriveBackupAttemptResult.succeeded,
    );
    expect(harness.drive.files, hasLength(1));

    await harness.service.setSchedule(DriveBackupSchedule.manual);
    expect(
      await harness.service.backupIfDue(
        now: now.add(const Duration(days: 60)),
        summaryTime: summaryTime,
      ),
      DriveBackupAttemptResult.skipped,
    );

    await harness.service.setSchedule(DriveBackupSchedule.daily);
    expect(
      await harness.service.backupIfDue(now: now, summaryTime: summaryTime),
      DriveBackupAttemptResult.skipped,
    );
    expect(harness.drive.files, hasLength(1));
  });

  test('failed uploads are recorded and retried later', () async {
    final harness = await _createHarness();
    await harness.service.connect();
    harness.drive.failUploads = true;

    expect(
      await harness.service.backupIfDue(
        now: DateTime.now().add(const Duration(days: 30)),
        summaryTime: const TimeOfDay(hour: 20, minute: 0),
      ),
      DriveBackupAttemptResult.retry,
    );
    expect(
      harness.settings.config.value?.lastBackupError,
      contains('full'),
    );
  });

  test('disconnecting keeps the recovery key', () async {
    final harness = await _createHarness();
    await harness.service.connect();
    final keyId = await harness.service.currentKeyId();

    await harness.service.disconnect();

    expect(harness.settings.config.value, isNull);
    expect(await harness.service.currentKeyId(), keyId);
    expect(harness.authenticator.clearedTokens, ['token-1']);
  });
}

Future<_Harness> _createHarness({_MemoryDrive? drive, int seed = 7}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  FlutterSecureStorage.setMockInitialValues(<String, String>{});

  final settings = DriveBackupSettingsService.instance;
  await settings.disconnect(forgetKey: true);
  final memoryDrive = drive ?? _MemoryDrive();
  final authenticator = _FakeAuthenticator();
  final service = DriveBackupService(
    settings: settings,
    crypto: TelegramBackupCrypto(random: Random(seed)),
    exportImportService: _FakeExportService(),
    authenticator: authenticator,
    apiFactory: (tokenProvider) => _FakeDriveApiClient(
      memoryDrive,
      tokenProvider,
    ),
    runtimeLocks: _AlwaysAvailableRuntimeLockRepository(),
  );
  return _Harness(
    settings: settings,
    drive: memoryDrive,
    authenticator: authenticator,
    service: service,
  );
}

class _Harness {
  const _Harness({
    required this.settings,
    required this.drive,
    required this.authenticator,
    required this.service,
  });

  final DriveBackupSettingsService settings;
  final _MemoryDrive drive;
  final _FakeAuthenticator authenticator;
  final DriveBackupService service;
}

class _StoredFile {
  _StoredFile(this.file, this.bytes);

  final DriveFile file;
  final List<int> bytes;

  String get name => file.name;
}

class _MemoryDrive {
  final Map<String, _StoredFile> files = {};
  bool failUploads = false;
  int _nextId = 1;
}

class _FakeDriveApiClient extends DriveApiClient {
  _FakeDriveApiClient(this.drive, DriveAccessTokenProvider tokenProvider)
      : _tokenProvider = tokenProvider,
        super(tokenProvider: tokenProvider);

  final _MemoryDrive drive;
  final DriveAccessTokenProvider _tokenProvider;

  Future<void> _requireToken() async {
    final token = await _tokenProvider();
    if (token == null) {
      throw const DriveApiException('Signed out', statusCode: 401);
    }
  }

  @override
  Future<DriveUser> getUser() async {
    await _requireToken();
    return const DriveUser(email: 'me@example.com');
  }

  @override
  Future<List<DriveFile>> listFiles() async {
    await _requireToken();
    return drive.files.values.map((stored) => stored.file).toList();
  }

  @override
  Future<DriveFile> uploadFile({
    required String name,
    required List<int> bytes,
    String mimeType = 'application/octet-stream',
    Map<String, String> appProperties = const {},
  }) async {
    await _requireToken();
    if (drive.failUploads) {
      throw const DriveApiException(
        'Your Google Drive is full. Free up space and try again.',
        statusCode: 403,
        reason: 'storageQuotaExceeded',
      );
    }
    final file = DriveFile(
      id: 'file-${drive._nextId++}',
      name: name,
      size: bytes.length,
      appProperties: Map<String, String>.from(appProperties),
    );
    drive.files[file.id] = _StoredFile(file, List<int>.from(bytes));
    return file;
  }

  @override
  Future<List<int>> downloadFile(
    String fileId, {
    int maximumBytes = DriveApiClient.maxDownloadBytes,
  }) async {
    await _requireToken();
    final stored = drive.files[fileId];
    if (stored == null) {
      throw const DriveApiException('Missing', statusCode: 404);
    }
    return List<int>.from(stored.bytes);
  }

  @override
  Future<void> deleteFile(String fileId) async {
    await _requireToken();
    drive.files.remove(fileId);
  }

  @override
  void close() {}
}

class _FakeAuthenticator implements DriveAuthenticator {
  bool cancel = false;
  int _tokenNumber = 0;
  final List<String> clearedTokens = [];

  @override
  Future<GoogleAuthorization?> authorize({required bool interactive}) async {
    if (cancel) return null;
    _tokenNumber++;
    return GoogleAuthorization(accessToken: 'token-$_tokenNumber');
  }

  @override
  Future<void> clearToken(String accessToken) async {
    clearedTokens.add(accessToken);
  }
}

class _FakeExportService extends DataExportImportService {
  @override
  Future<String> exportAllData({
    DataExportOptions options = const DataExportOptions(),
  }) async {
    return _exportJson;
  }
}

class _AlwaysAvailableRuntimeLockRepository extends RuntimeLockRepository {
  @override
  Future<RuntimeLockLease?> tryAcquire(
    String name, {
    Duration ttl = const Duration(minutes: 15),
  }) async {
    return RuntimeLockLease(name: name, owner: 'test');
  }

  @override
  Future<void> release(RuntimeLockLease lease) async {}
}
