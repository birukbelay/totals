import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:totals/repositories/runtime_lock_repository.dart';
import 'package:totals/services/data_export_import_service.dart';
import 'package:totals/services/google_drive_backup/drive_api_client.dart';
import 'package:totals/services/google_drive_backup/drive_backup_models.dart';
import 'package:totals/services/google_drive_backup/drive_backup_schedule.dart';
import 'package:totals/services/google_drive_backup/drive_backup_settings_service.dart';
import 'package:totals/services/notification_settings_service.dart';
import 'package:totals/services/telegram_backup/telegram_backup_crypto.dart';
import 'package:totals_google_auth/totals_google_auth.dart';

typedef DriveApiClientFactory = DriveApiClient Function(
  DriveAccessTokenProvider tokenProvider,
);

enum DriveBackupAttemptResult {
  skipped,
  succeeded,
  retry,
}

class DriveBackupException implements Exception {
  final String message;

  const DriveBackupException(this.message);

  @override
  String toString() => message;
}

/// Drive already holds encrypted backups made with a recovery key this
/// device does not have.
class DriveRecoveryKeyRequiredException extends DriveBackupException {
  const DriveRecoveryKeyRequiredException()
      : super(
          'Your Google Drive already has encrypted Totals backups. Enter '
          'their recovery key to use them on this device.',
        );
}

class DriveRecoveryKeyInvalidException extends DriveBackupException {
  const DriveRecoveryKeyInvalidException(super.message);
}

/// Grants the `drive.appdata` scope.
abstract class DriveAuthenticator {
  /// Returns null when the user has not granted access and [interactive] is
  /// false, or when the user cancelled.
  Future<GoogleAuthorization?> authorize({required bool interactive});

  Future<void> clearToken(String accessToken);
}

class PlayServicesDriveAuthenticator implements DriveAuthenticator {
  const PlayServicesDriveAuthenticator();

  static const String driveAppDataScope =
      'https://www.googleapis.com/auth/drive.appdata';

  @override
  Future<GoogleAuthorization?> authorize({required bool interactive}) {
    return TotalsGoogleAuth.authorize(
      scopes: const [driveAppDataScope],
      interactive: interactive,
    );
  }

  @override
  Future<void> clearToken(String accessToken) {
    return TotalsGoogleAuth.clearToken(accessToken);
  }
}

class DriveConnectionResult {
  final DriveBackupConfig config;
  final String formattedRecoveryKey;

  /// True when a new recovery key was created that the user must save.
  final bool shouldShowRecoveryKey;
  final int existingBackupCount;

  const DriveConnectionResult({
    required this.config,
    required this.formattedRecoveryKey,
    required this.shouldShowRecoveryKey,
    required this.existingBackupCount,
  });
}

/// Backs up Totals to the hidden app folder of the user's own Google Drive.
class DriveBackupService {
  DriveBackupService({
    DriveBackupSettingsService? settings,
    TelegramBackupCrypto? crypto,
    DataExportImportService? exportImportService,
    DriveAuthenticator? authenticator,
    DriveApiClientFactory? apiFactory,
    RuntimeLockRepository? runtimeLocks,
  })  : _settings = settings ?? DriveBackupSettingsService.instance,
        _crypto = crypto ?? TelegramBackupCrypto(),
        _exportImportService = exportImportService ?? DataExportImportService(),
        _authenticator =
            authenticator ?? const PlayServicesDriveAuthenticator(),
        _apiFactory = apiFactory ??
            ((tokenProvider) => DriveApiClient(tokenProvider: tokenProvider)),
        _runtimeLocks = runtimeLocks ?? RuntimeLockRepository();

  static final DriveBackupService instance = DriveBackupService();

  final DriveBackupSettingsService _settings;
  final TelegramBackupCrypto _crypto;
  final DataExportImportService _exportImportService;
  final DriveAuthenticator _authenticator;
  final DriveApiClientFactory _apiFactory;
  final RuntimeLockRepository _runtimeLocks;

  static const String _runtimeLockName = 'google_drive_backup';
  static const Duration _runtimeLockTtl = Duration(minutes: 15);

  Future<void> _operationQueue = Future<void>.value();
  String? _cachedToken;

  /// Signs in to Google and connects Drive backup.
  ///
  /// Reuses the recovery key of this device, or [recoveryKey], when Drive
  /// already holds encrypted backups. Throws
  /// [DriveRecoveryKeyRequiredException] when it holds backups for a key
  /// this device does not have, unless [startFresh] creates a new key; the
  /// old backups then stay in Drive but can only be opened with their key.
  Future<DriveConnectionResult?> connect({
    String? recoveryKey,
    bool startFresh = false,
  }) {
    return _serialized(() async {
      final authorization = await _authorize(interactive: true);
      if (authorization == null) return null;

      final api = _api(interactive: true);
      try {
        final email =
            authorization.email ?? (await api.getUser()).email?.trim();
        final backups = await _listEntries(api);

        String? key;
        if (recoveryKey != null && recoveryKey.trim().isNotEmpty) {
          try {
            key = _crypto.normalizeRecoveryKey(recoveryKey);
          } on TelegramBackupCryptoException catch (error) {
            throw DriveRecoveryKeyInvalidException(error.message);
          }
        } else if (!startFresh) {
          key = await _settings.readRecoveryKey();
        }

        final existingKeyIds = backups
            .where((entry) => entry.encrypted && entry.keyId != null)
            .map((entry) => entry.keyId!)
            .toSet();
        var createdKey = false;
        if (key != null && existingKeyIds.isNotEmpty) {
          final keyId = await _keyId(key);
          if (!existingKeyIds.contains(keyId)) {
            if (recoveryKey != null) {
              throw const DriveRecoveryKeyInvalidException(
                'That recovery key does not match the backups in your '
                'Google Drive.',
              );
            }
            if (!startFresh) throw const DriveRecoveryKeyRequiredException();
            key = null;
          }
        } else if (key == null && existingKeyIds.isNotEmpty && !startFresh) {
          throw const DriveRecoveryKeyRequiredException();
        }
        if (key == null) {
          key = _crypto.generateRecoveryKey();
          createdKey = true;
        }

        await _settings.saveRecoveryKey(key);
        final now = DateTime.now().toUtc();
        final config = DriveBackupConfig(
          accountEmail: email,
          connectedAt: now,
          scheduleAnchorAt: now,
          lastBackupAt: backups.isEmpty ? null : backups.first.createdAt,
        );
        await _settings.saveConnection(config);
        return DriveConnectionResult(
          config: config,
          formattedRecoveryKey: _crypto.formatRecoveryKey(key),
          shouldShowRecoveryKey: createdKey,
          existingBackupCount: backups.length,
        );
      } on DriveApiException catch (error) {
        throw DriveBackupException(error.message);
      } finally {
        api.close();
      }
    });
  }

  /// The key ID of this device's recovery key, used to tell which backups
  /// it can open.
  Future<String?> currentKeyId() async {
    final key = await _settings.readRecoveryKey();
    return key == null ? null : _keyId(key);
  }

  Future<List<DriveBackupEntry>> listBackups() {
    return _serialized(() async {
      await _requireConfig();
      final api = _api();
      try {
        return await _listEntries(api);
      } on DriveApiException catch (error) {
        throw DriveBackupException(error.message);
      } finally {
        api.close();
      }
    });
  }

  Future<DriveBackupEntry> backupNow() {
    return _serialized(() => _withDeviceBackupLock(_performBackup));
  }

  /// Downloads [entry] and returns its export JSON. Backups made with
  /// another recovery key need [recoveryKey].
  Future<String> downloadBackup(
    DriveBackupEntry entry, {
    String? recoveryKey,
  }) {
    return _serialized(() async {
      await _requireConfig();
      String? key;
      if (entry.encrypted) {
        if (recoveryKey != null) {
          try {
            key = _crypto.normalizeRecoveryKey(recoveryKey);
          } on TelegramBackupCryptoException catch (error) {
            throw DriveRecoveryKeyInvalidException(error.message);
          }
        } else {
          key = await _settings.readRecoveryKey();
        }
        if (key == null ||
            (entry.keyId != null && entry.keyId != await _keyId(key))) {
          if (recoveryKey != null) {
            throw const DriveRecoveryKeyInvalidException(
              'That recovery key does not open this backup.',
            );
          }
          throw const DriveRecoveryKeyRequiredException();
        }
      }

      final api = _api();
      try {
        final bytes = await api.downloadFile(entry.fileId);
        final expectedHash = entry.sha256;
        if (expectedHash != null &&
            (await _crypto.sha256Hex(bytes)).toLowerCase() !=
                expectedHash.toLowerCase()) {
          throw const DriveBackupException(
            'This Google Drive backup is incomplete or was changed.',
          );
        }
        if (!entry.encrypted) return utf8.decode(bytes);
        final plain = await _crypto.decrypt(
          bytes,
          recoveryKey: key!,
          expectedContentType: TelegramBackupCrypto.backupContentType,
        );
        return utf8.decode(plain);
      } on DriveBackupException {
        rethrow;
      } on DriveApiException catch (error) {
        throw DriveBackupException(error.message);
      } on TelegramBackupCryptoException catch (error) {
        throw DriveBackupException(_cryptoMessage(error));
      } on FormatException {
        throw const DriveBackupException(
          'This Google Drive backup is damaged or unsupported.',
        );
      } finally {
        api.close();
      }
    });
  }

  Future<String> formattedRecoveryKey() async {
    final key = await _settings.readRecoveryKey();
    if (key == null) {
      throw const DriveBackupException(
        'The recovery key is not available on this device.',
      );
    }
    try {
      return _crypto.formatRecoveryKey(key);
    } on TelegramBackupCryptoException catch (error) {
      throw DriveBackupException(error.message);
    }
  }

  Future<DriveBackupAttemptResult> backupIfDue({
    DateTime? now,
    TimeOfDay? summaryTime,
  }) async {
    await _settings.reload();
    var config = _settings.config.value;
    if (config == null || config.schedule == DriveBackupSchedule.manual) {
      return DriveBackupAttemptResult.skipped;
    }
    final current = now ?? DateTime.now();
    config = await _settings.ensureScheduleAnchor(now: current);
    if (config == null) return DriveBackupAttemptResult.skipped;
    final scheduledTime = summaryTime ??
        await NotificationSettingsService.instance.getDailySummaryTime();
    if (!isDriveBackupDue(
      config: config,
      now: current,
      summaryTime: scheduledTime,
    )) {
      return DriveBackupAttemptResult.skipped;
    }

    return _serialized(
      () => _withDeviceBackupLock(
        () async {
          // Re-read after taking the lease so only one isolate uploads the
          // backup for a due boundary.
          await _settings.reload();
          final lockedConfig = _settings.config.value;
          if (lockedConfig == null ||
              lockedConfig.schedule == DriveBackupSchedule.manual ||
              !isDriveBackupDue(
                config: lockedConfig,
                now: current,
                summaryTime: scheduledTime,
              )) {
            return DriveBackupAttemptResult.skipped;
          }
          try {
            await _performBackup();
            return DriveBackupAttemptResult.succeeded;
          } catch (_) {
            return DriveBackupAttemptResult.retry;
          }
        },
        onBusy: () => DriveBackupAttemptResult.skipped,
      ),
    );
  }

  /// Disconnects this device. Backups stay in Drive and the recovery key
  /// stays on the device, so reconnecting can still open them.
  Future<void> disconnect() {
    return _serialized(
      () => _withDeviceBackupLock(() async {
        final token = _cachedToken;
        _cachedToken = null;
        if (token != null) {
          try {
            await _authenticator.clearToken(token);
          } catch (_) {}
        }
        await _settings.disconnect();
      }),
    );
  }

  Future<void> setSchedule(DriveBackupSchedule schedule) {
    return _serialized(
      () => _withDeviceBackupLock(() => _settings.setSchedule(schedule)),
    );
  }

  Future<void> setEncrypt(bool encrypt) {
    return _serialized(() => _settings.setEncrypt(encrypt));
  }

  Future<void> setKeepCount(int keepCount) {
    return _serialized(() => _settings.setKeepCount(keepCount));
  }

  Future<DriveBackupEntry> _performBackup() async {
    final config = await _requireConfig();
    final api = _api();
    try {
      final createdAt = DateTime.now().toUtc();
      final exported = await _exportImportService.exportAllData();
      final plain = utf8.encode(exported);

      final List<int> bytes;
      String? keyId;
      if (config.encrypt) {
        final key = await _settings.readRecoveryKey();
        if (key == null) {
          throw const DriveBackupException(
            'The recovery key is missing on this device. Reconnect Google '
            'Drive backup.',
          );
        }
        bytes = await _crypto.encrypt(
          plain,
          recoveryKey: key,
          contentType: TelegramBackupCrypto.backupContentType,
        );
        keyId = await _keyId(key);
      } else {
        bytes = plain;
      }
      final draft = DriveBackupEntry(
        fileId: '',
        name: _backupFileName(createdAt.toLocal(), encrypted: config.encrypt),
        createdAt: createdAt,
        size: bytes.length,
        exportSchemaVersion: DataExportImportService.currentSchemaVersion,
        encrypted: config.encrypt,
        sha256: await _crypto.sha256Hex(bytes),
        keyId: keyId,
      );

      final file = await api.uploadFile(
        name: draft.name,
        bytes: bytes,
        mimeType:
            config.encrypt ? 'application/octet-stream' : 'application/json',
        appProperties: draft.toAppProperties(),
      );
      final entry = DriveBackupEntry(
        fileId: file.id,
        name: draft.name,
        createdAt: createdAt,
        size: file.size > 0 ? file.size : bytes.length,
        exportSchemaVersion: draft.exportSchemaVersion,
        encrypted: draft.encrypted,
        sha256: draft.sha256,
        keyId: keyId,
      );
      await _settings.recordBackupSuccess(createdAt);
      await _prune(api, keepCount: config.keepCount);
      return entry;
    } catch (error) {
      final message = switch (error) {
        DriveApiException(:final message) => message,
        DriveBackupException(:final message) => message,
        TelegramBackupCryptoException() => _cryptoMessage(error),
        GoogleAuthException() => _authMessage(error),
        _ => 'Could not create the Google Drive backup.',
      };
      await _settings.recordBackupFailure(message);
      throw DriveBackupException(message);
    } finally {
      api.close();
    }
  }

  /// Deletes the oldest backups beyond [keepCount]. A failed delete only
  /// leaves an extra backup behind.
  Future<void> _prune(DriveApiClient api, {required int keepCount}) async {
    try {
      final stale = driveBackupsToPrune(
        await _listEntries(api),
        keepCount: keepCount,
      );
      for (final entry in stale) {
        await api.deleteFile(entry.fileId);
      }
    } catch (error) {
      debugPrint('debug: Could not prune old Drive backups: $error');
    }
  }

  Future<List<DriveBackupEntry>> _listEntries(DriveApiClient api) async {
    final entries = <DriveBackupEntry>[];
    for (final file in await api.listFiles()) {
      final entry = DriveBackupEntry.fromDriveFile(file);
      if (entry != null) entries.add(entry);
    }
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }

  Future<DriveBackupConfig> _requireConfig() async {
    await _settings.reload();
    final config = _settings.config.value;
    if (config == null) {
      throw const DriveBackupException(
        'Connect Google Drive backup first.',
      );
    }
    return config;
  }

  DriveApiClient _api({bool interactive = false}) {
    return _apiFactory(
      ({bool forceRefresh = false}) => _accessToken(
        forceRefresh: forceRefresh,
        interactive: interactive,
      ),
    );
  }

  Future<GoogleAuthorization?> _authorize({required bool interactive}) async {
    try {
      final authorization =
          await _authenticator.authorize(interactive: interactive);
      _cachedToken = authorization?.accessToken;
      return authorization;
    } on GoogleAuthException catch (error) {
      throw DriveBackupException(_authMessage(error));
    }
  }

  Future<String?> _accessToken({
    required bool forceRefresh,
    required bool interactive,
  }) async {
    final cached = _cachedToken;
    if (!forceRefresh && cached != null) return cached;
    if (forceRefresh && cached != null) {
      _cachedToken = null;
      try {
        await _authenticator.clearToken(cached);
      } catch (_) {}
    }
    return (await _authorize(interactive: interactive))?.accessToken;
  }

  Future<String> _keyId(String recoveryKey) async {
    final normalized = _crypto.normalizeRecoveryKey(recoveryKey);
    final hash = await _crypto.sha256Hex(
      utf8.encode('totals.drive.key-id:$normalized'),
    );
    return hash.substring(0, 16);
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _operationQueue = _operationQueue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<T> _withDeviceBackupLock<T>(
    Future<T> Function() action, {
    T Function()? onBusy,
  }) async {
    final lease = await _runtimeLocks.tryAcquire(
      _runtimeLockName,
      ttl: _runtimeLockTtl,
    );
    if (lease == null) {
      if (onBusy != null) return onBusy();
      throw const DriveBackupException(
        'Another Google Drive backup is already running.',
      );
    }
    try {
      return await action();
    } finally {
      try {
        await _runtimeLocks.release(lease);
      } catch (_) {}
    }
  }

  static String _backupFileName(DateTime date, {required bool encrypted}) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'totals_backup_${date.year}${two(date.month)}${two(date.day)}_'
        '${two(date.hour)}${two(date.minute)}${two(date.second)}'
        '${encrypted ? '.totals' : '.json'}';
  }

  static String _cryptoMessage(TelegramBackupCryptoException error) {
    // The shared crypto names Telegram in its file errors.
    if (error.message.contains('Telegram')) {
      return 'This Google Drive backup is damaged or unsupported.';
    }
    return error.message;
  }

  static String _authMessage(GoogleAuthException error) {
    switch (error.code) {
      case 'api_10':
        return 'Google sign-in is not set up for this build of Totals. '
            'Register its signing certificate in Google Cloud.';
      case 'api_7':
        return 'Could not reach Google. Check your connection.';
      case 'api_16':
      case 'api_12501':
        return 'Google sign-in was cancelled.';
      default:
        return error.message;
    }
  }
}
