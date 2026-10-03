import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:totals/services/google_drive_backup/drive_backup_models.dart';

class DriveBackupSettingsService {
  DriveBackupSettingsService._();

  static final DriveBackupSettingsService instance =
      DriveBackupSettingsService._();

  static const String _configKey = 'google_drive_backup_config_v1';
  static const String _recoveryKey = 'google_drive_backup_recovery_key_v1';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final ValueNotifier<DriveBackupConfig?> config =
      ValueNotifier<DriveBackupConfig?>(null);

  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await reload();
  }

  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    config.value = _decodeConfig(prefs.getString(_configKey));
    _loaded = true;
  }

  Future<void> saveConnection(DriveBackupConfig value) => _writeConfig(value);

  Future<String?> readRecoveryKey() async {
    final value = await _secureStorage.read(key: _recoveryKey);
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> saveRecoveryKey(String recoveryKey) async {
    await _secureStorage.write(key: _recoveryKey, value: recoveryKey.trim());
  }

  Future<void> setSchedule(DriveBackupSchedule schedule) async {
    await reload();
    final current = config.value;
    if (current == null || current.schedule == schedule) return;
    await _writeConfig(
      current.copyWith(
        schedule: schedule,
        scheduleAnchorAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> setEncrypt(bool encrypt) async {
    await reload();
    final current = config.value;
    if (current == null || current.encrypt == encrypt) return;
    await _writeConfig(current.copyWith(encrypt: encrypt));
  }

  Future<void> setKeepCount(int keepCount) async {
    await reload();
    final current = config.value;
    if (current == null || keepCount < 1 || current.keepCount == keepCount) {
      return;
    }
    await _writeConfig(current.copyWith(keepCount: keepCount));
  }

  Future<DriveBackupConfig?> ensureScheduleAnchor({DateTime? now}) async {
    await reload();
    final current = config.value;
    if (current == null || current.scheduleAnchorAt != null) return current;
    final anchored = current.copyWith(
      scheduleAnchorAt: current.lastBackupAt ?? (now ?? DateTime.now()).toUtc(),
    );
    await _writeConfig(anchored);
    return anchored;
  }

  Future<void> recordBackupSuccess(DateTime completedAt) async {
    await reload();
    final current = config.value;
    if (current == null) return;
    await _writeConfig(
      current.copyWith(
        lastBackupAt: completedAt.toUtc(),
        clearLastBackupError: true,
      ),
    );
  }

  Future<void> recordBackupFailure(String message) async {
    await reload();
    final current = config.value;
    if (current == null) return;
    await _writeConfig(
      current.copyWith(lastBackupError: _safeError(message)),
    );
  }

  /// Forgets the connection. The recovery key is kept unless [forgetKey],
  /// so reconnecting can still open the backups already in Drive.
  Future<void> disconnect({bool forgetKey = false}) async {
    if (forgetKey) await _secureStorage.delete(key: _recoveryKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_configKey);
    config.value = null;
    _loaded = true;
  }

  Future<void> _writeConfig(DriveBackupConfig value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(value.toJson()));
    config.value = value;
    _loaded = true;
  }

  static DriveBackupConfig? _decodeConfig(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return DriveBackupConfig.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static String _safeError(String message) {
    final normalized = message.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.length <= 240) return normalized;
    return '${normalized.substring(0, 237)}...';
  }
}
