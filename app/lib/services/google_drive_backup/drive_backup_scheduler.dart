import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'package:totals/services/google_drive_backup/drive_backup_models.dart';
import 'package:totals/services/google_drive_backup/drive_backup_settings_service.dart';

const String googleDriveBackupCheckTask = 'googleDriveBackupCheck';
const String googleDriveBackupCheckUniqueName = 'googleDriveBackupCheckUnique';
const String googleDriveBackupAfterSummaryUniqueName =
    'googleDriveBackupAfterSummaryUnique';

class DriveBackupScheduler {
  DriveBackupScheduler._();

  // Like Telegram backups, WorkManager only provides opportunistic checks;
  // the service applies the summary-time daily/weekly rule before uploading.
  @visibleForTesting
  static const Duration checkFrequency = Duration(minutes: 15);

  @visibleForTesting
  static const NetworkType requiredNetworkType = NetworkType.connected;

  @visibleForTesting
  static const ExistingPeriodicWorkPolicy existingWorkPolicy =
      ExistingPeriodicWorkPolicy.update;

  @visibleForTesting
  static const ExistingWorkPolicy summaryTriggerExistingWorkPolicy =
      ExistingWorkPolicy.keep;

  @visibleForTesting
  static const Duration summaryTriggerBackoff = Duration(minutes: 1);

  @visibleForTesting
  static const Map<String, dynamic> summaryTriggerInputData = <String, dynamic>{
    'trigger': 'summary',
    'skipSmsCatchup': true,
  };

  @visibleForTesting
  static bool shouldSchedule(DriveBackupConfig? config) {
    return config != null && config.schedule != DriveBackupSchedule.manual;
  }

  static Future<void> sync() async {
    if (kIsWeb) return;
    try {
      await DriveBackupSettingsService.instance.ensureLoaded();
      final config = DriveBackupSettingsService.instance.config.value;
      if (!shouldSchedule(config)) {
        await Workmanager().cancelByUniqueName(
          googleDriveBackupCheckUniqueName,
        );
        await Workmanager().cancelByUniqueName(
          googleDriveBackupAfterSummaryUniqueName,
        );
        return;
      }

      await DriveBackupSettingsService.instance.ensureScheduleAnchor();
      await Workmanager().registerPeriodicTask(
        googleDriveBackupCheckUniqueName,
        googleDriveBackupCheckTask,
        existingWorkPolicy: existingWorkPolicy,
        frequency: checkFrequency,
        constraints: Constraints(networkType: requiredNetworkType),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
            'debug: Failed to sync Google Drive backup schedule: $error');
      }
    }
  }

  /// Requests a due backup right after a spending summary is delivered. It
  /// shares the periodic task's due check and device lock, so overlapping
  /// runs cannot upload duplicate backups.
  static Future<void> enqueueAfterSummary() async {
    if (kIsWeb) return;
    try {
      await DriveBackupSettingsService.instance.ensureLoaded();
      if (!shouldSchedule(DriveBackupSettingsService.instance.config.value)) {
        return;
      }
      await Workmanager().registerOneOffTask(
        googleDriveBackupAfterSummaryUniqueName,
        googleDriveBackupCheckTask,
        inputData: summaryTriggerInputData,
        existingWorkPolicy: summaryTriggerExistingWorkPolicy,
        constraints: Constraints(networkType: requiredNetworkType),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: summaryTriggerBackoff,
        outOfQuotaPolicy: OutOfQuotaPolicy.runAsNonExpeditedWorkRequest,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          'debug: Failed to request Google Drive backup after summary: $error',
        );
      }
    }
  }
}
