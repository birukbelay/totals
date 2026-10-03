import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:totals/services/google_drive_backup/drive_api_client.dart';
import 'package:totals/services/google_drive_backup/drive_backup_models.dart';
import 'package:totals/services/google_drive_backup/drive_backup_schedule.dart';
import 'package:totals/services/google_drive_backup/drive_backup_scheduler.dart';

void main() {
  const summaryTime = TimeOfDay(hour: 20, minute: 0);

  DriveBackupEntry entry(String id, DateTime createdAt) {
    return DriveBackupEntry(
      fileId: id,
      name: '$id.totals',
      createdAt: createdAt,
      size: 10,
      exportSchemaVersion: 12,
      encrypted: true,
    );
  }

  test('config survives a JSON round trip', () {
    final config = DriveBackupConfig(
      accountEmail: 'me@example.com',
      connectedAt: DateTime.utc(2026, 7, 1),
      schedule: DriveBackupSchedule.daily,
      encrypt: false,
      keepCount: 5,
      scheduleAnchorAt: DateTime.utc(2026, 7, 2),
      lastBackupAt: DateTime.utc(2026, 7, 3),
      lastBackupError: 'Offline',
    );

    final decoded = DriveBackupConfig.fromJson(config.toJson());

    expect(decoded.accountEmail, 'me@example.com');
    expect(decoded.connectedAt, DateTime.utc(2026, 7, 1));
    expect(decoded.schedule, DriveBackupSchedule.daily);
    expect(decoded.encrypt, isFalse);
    expect(decoded.keepCount, 5);
    expect(decoded.scheduleAnchorAt, DateTime.utc(2026, 7, 2));
    expect(decoded.lastBackupAt, DateTime.utc(2026, 7, 3));
    expect(decoded.lastBackupError, 'Offline');
    expect(
      decoded.copyWith(clearLastBackupError: true).lastBackupError,
      isNull,
    );
  });

  test('config defaults to encrypted weekly backups keeping 10', () {
    final decoded = DriveBackupConfig.fromJson(const {'keepCount': 0});

    expect(decoded.schedule, DriveBackupSchedule.weekly);
    expect(decoded.encrypt, isTrue);
    expect(decoded.keepCount, DriveBackupConfig.defaultKeepCount);
  });

  test('only Totals backups are read from the app folder', () {
    final original = DriveBackupEntry(
      fileId: 'f1',
      name: 'totals_backup.totals',
      createdAt: DateTime.utc(2026, 7, 1, 8),
      size: 99,
      exportSchemaVersion: 12,
      encrypted: true,
      sha256: 'abc',
      keyId: 'key1',
    );

    final parsed = DriveBackupEntry.fromDriveFile(
      DriveFile(
        id: 'f1',
        name: 'totals_backup.totals',
        size: 99,
        appProperties: original.toAppProperties(),
      ),
    )!;

    expect(parsed.createdAt, original.createdAt);
    expect(parsed.exportSchemaVersion, 12);
    expect(parsed.encrypted, isTrue);
    expect(parsed.sha256, 'abc');
    expect(parsed.keyId, 'key1');
    expect(
      DriveBackupEntry.fromDriveFile(
        const DriveFile(id: 'x', name: 'notes.txt'),
      ),
      isNull,
    );
  });

  test('plain backups are marked as not encrypted', () {
    final parsed = DriveBackupEntry.fromDriveFile(
      const DriveFile(
        id: 'f2',
        name: 'totals_backup.json',
        appProperties: {
          'format': 'totals.backup',
          'encrypted': '0',
          'schemaVersion': '12',
        },
      ),
    )!;

    expect(parsed.encrypted, isFalse);
    expect(parsed.keyId, isNull);
  });

  test('pruning keeps the newest backups', () {
    final backups = [
      entry('b', DateTime.utc(2026, 7, 2)),
      entry('d', DateTime.utc(2026, 7, 4)),
      entry('a', DateTime.utc(2026, 7, 1)),
      entry('c', DateTime.utc(2026, 7, 3)),
    ];

    expect(
      driveBackupsToPrune(backups, keepCount: 2).map((e) => e.fileId),
      ['b', 'a'],
    );
    expect(driveBackupsToPrune(backups, keepCount: 4), isEmpty);
    expect(driveBackupsToPrune(backups, keepCount: 0), isEmpty);
  });

  test('daily backups are due after the first summary time', () {
    final config = DriveBackupConfig(
      connectedAt: DateTime(2026, 7, 24, 10),
      schedule: DriveBackupSchedule.daily,
      scheduleAnchorAt: DateTime(2026, 7, 24, 10),
    );

    expect(
      isDriveBackupDue(
        config: config,
        now: DateTime(2026, 7, 24, 19, 59),
        summaryTime: summaryTime,
      ),
      isFalse,
    );
    expect(
      isDriveBackupDue(
        config: config,
        now: DateTime(2026, 7, 24, 20),
        summaryTime: summaryTime,
      ),
      isTrue,
    );
    expect(
      isDriveBackupDue(
        config: config.copyWith(lastBackupAt: DateTime(2026, 7, 24, 20, 5)),
        now: DateTime(2026, 7, 24, 23),
        summaryTime: summaryTime,
      ),
      isFalse,
    );
  });

  test('manual backups are never due or scheduled', () {
    final config = DriveBackupConfig(
      connectedAt: DateTime(2026, 7, 1),
      schedule: DriveBackupSchedule.manual,
      scheduleAnchorAt: DateTime(2026, 7, 1),
    );

    expect(
      isDriveBackupDue(
        config: config,
        now: DateTime(2026, 8, 1),
        summaryTime: summaryTime,
      ),
      isFalse,
    );
    expect(DriveBackupScheduler.shouldSchedule(config), isFalse);
    expect(DriveBackupScheduler.shouldSchedule(null), isFalse);
    expect(
      DriveBackupScheduler.shouldSchedule(
        config.copyWith(schedule: DriveBackupSchedule.weekly),
      ),
      isTrue,
    );
  });
}
