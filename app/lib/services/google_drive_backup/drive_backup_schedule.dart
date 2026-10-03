import 'package:flutter/material.dart';
import 'package:totals/services/google_drive_backup/drive_backup_models.dart';
import 'package:totals/services/telegram_backup/telegram_backup_schedule.dart';

/// Whether an automatic Drive backup is due, using the same daily summary
/// boundaries as Telegram backups.
bool isDriveBackupDue({
  required DriveBackupConfig config,
  required DateTime now,
  required TimeOfDay summaryTime,
}) {
  final anchor = config.scheduleAnchorAt?.toLocal();
  if (anchor == null) return false;

  final boundary = telegramBackupBoundaryAtOrBefore(
    schedule: config.schedule,
    now: now,
    summaryTime: summaryTime,
  );
  if (boundary == null || !boundary.isAfter(anchor)) return false;

  final lastBackup = config.lastBackupAt?.toLocal();
  return lastBackup == null || lastBackup.isBefore(boundary);
}

/// The backups to delete so only the newest [keepCount] remain.
List<DriveBackupEntry> driveBackupsToPrune(
  Iterable<DriveBackupEntry> backups, {
  required int keepCount,
}) {
  final sorted = backups.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  if (keepCount < 1 || sorted.length <= keepCount) return const [];
  return sorted.sublist(keepCount);
}
