import 'package:totals/services/google_drive_backup/drive_api_client.dart';
import 'package:totals/services/telegram_backup/telegram_backup_models.dart';

/// Drive backups share the Telegram backup schedule options and timing.
typedef DriveBackupSchedule = TelegramBackupSchedule;

class DriveBackupConfig {
  static const int defaultKeepCount = 10;
  static const List<int> keepCountOptions = [3, 5, 10, 20];

  final String? accountEmail;
  final DateTime connectedAt;
  final DriveBackupSchedule schedule;
  final bool encrypt;
  final int keepCount;
  final DateTime? scheduleAnchorAt;
  final DateTime? lastBackupAt;
  final String? lastBackupError;

  const DriveBackupConfig({
    required this.connectedAt,
    this.accountEmail,
    this.schedule = DriveBackupSchedule.recommended,
    this.encrypt = true,
    this.keepCount = defaultKeepCount,
    this.scheduleAnchorAt,
    this.lastBackupAt,
    this.lastBackupError,
  });

  DriveBackupConfig copyWith({
    String? accountEmail,
    DriveBackupSchedule? schedule,
    bool? encrypt,
    int? keepCount,
    DateTime? scheduleAnchorAt,
    DateTime? lastBackupAt,
    String? lastBackupError,
    bool clearLastBackupError = false,
  }) {
    return DriveBackupConfig(
      accountEmail: accountEmail ?? this.accountEmail,
      connectedAt: connectedAt,
      schedule: schedule ?? this.schedule,
      encrypt: encrypt ?? this.encrypt,
      keepCount: keepCount ?? this.keepCount,
      scheduleAnchorAt: scheduleAnchorAt ?? this.scheduleAnchorAt,
      lastBackupAt: lastBackupAt ?? this.lastBackupAt,
      lastBackupError: clearLastBackupError
          ? null
          : (lastBackupError ?? this.lastBackupError),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'accountEmail': accountEmail,
      'connectedAt': connectedAt.toUtc().toIso8601String(),
      'schedule': schedule.storageValue,
      'encrypt': encrypt,
      'keepCount': keepCount,
      'scheduleAnchorAt': scheduleAnchorAt?.toUtc().toIso8601String(),
      'lastBackupAt': lastBackupAt?.toUtc().toIso8601String(),
      'lastBackupError': lastBackupError,
    };
  }

  factory DriveBackupConfig.fromJson(Map<String, dynamic> json) {
    final keepCount = (json['keepCount'] as num?)?.toInt();
    final schedule = json['schedule'] as String?;
    return DriveBackupConfig(
      accountEmail: json['accountEmail'] as String?,
      connectedAt: DateTime.tryParse(json['connectedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      schedule: schedule == null
          ? DriveBackupSchedule.recommended
          : DriveBackupSchedule.fromStorage(schedule),
      encrypt: json['encrypt'] as bool? ?? true,
      keepCount:
          keepCount == null || keepCount < 1 ? defaultKeepCount : keepCount,
      scheduleAnchorAt:
          DateTime.tryParse(json['scheduleAnchorAt'] as String? ?? ''),
      lastBackupAt: DateTime.tryParse(json['lastBackupAt'] as String? ?? ''),
      lastBackupError: json['lastBackupError'] as String?,
    );
  }
}

/// A Totals backup stored in the user's Drive app folder.
class DriveBackupEntry {
  static const String format = 'totals.backup';

  final String fileId;
  final String name;
  final DateTime createdAt;
  final int size;
  final int exportSchemaVersion;
  final bool encrypted;
  final String? sha256;

  /// Fingerprint of the recovery key that encrypted the backup.
  final String? keyId;

  const DriveBackupEntry({
    required this.fileId,
    required this.name,
    required this.createdAt,
    required this.size,
    required this.exportSchemaVersion,
    required this.encrypted,
    this.sha256,
    this.keyId,
  });

  Map<String, String> toAppProperties() {
    return <String, String>{
      'format': format,
      'schemaVersion': '$exportSchemaVersion',
      'encrypted': encrypted ? '1' : '0',
      'createdAt': createdAt.toUtc().toIso8601String(),
      if (sha256 != null) 'sha256': sha256!,
      if (keyId != null) 'keyId': keyId!,
    };
  }

  /// The entry for [file], or null when it is not a Totals backup.
  static DriveBackupEntry? fromDriveFile(DriveFile file) {
    final properties = file.appProperties;
    if (properties['format'] != format || file.id.isEmpty) return null;
    final createdAt = DateTime.tryParse(properties['createdAt'] ?? '') ??
        file.createdTime ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final sha = properties['sha256']?.trim();
    final keyId = properties['keyId']?.trim();
    return DriveBackupEntry(
      fileId: file.id,
      name: file.name,
      createdAt: createdAt,
      size: file.size,
      exportSchemaVersion: int.tryParse(properties['schemaVersion'] ?? '') ?? 0,
      encrypted: properties['encrypted'] != '0',
      sha256: sha == null || sha.isEmpty ? null : sha,
      keyId: keyId == null || keyId.isEmpty ? null : keyId,
    );
  }
}
