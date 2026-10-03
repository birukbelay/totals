import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:totals/_redesign/screens/data_sync/data_sync_widgets.dart';
import 'package:totals/_redesign/theme/app_colors.dart';
import 'package:totals/_redesign/theme/app_icons.dart';
import 'package:totals/_redesign/widgets/telegram_recovery_key_dialog.dart';
import 'package:totals/l10n/app_localizations.dart';
import 'package:totals/providers/transaction_provider.dart';
import 'package:totals/services/data_export_import_service.dart';
import 'package:totals/services/google_drive_backup/drive_backup_models.dart';
import 'package:totals/services/google_drive_backup/drive_backup_scheduler.dart';
import 'package:totals/services/google_drive_backup/drive_backup_service.dart';
import 'package:totals/services/google_drive_backup/drive_backup_settings_service.dart';
import 'package:totals/services/notification_settings_service.dart';
import 'package:totals/widgets/data_import_options_sheet.dart';
import 'package:totals_google_auth/totals_google_auth.dart';

class GoogleDriveBackupPage extends StatefulWidget {
  const GoogleDriveBackupPage({super.key});

  @override
  State<GoogleDriveBackupPage> createState() => _GoogleDriveBackupPageState();
}

class _GoogleDriveBackupPageState extends State<GoogleDriveBackupPage> {
  final DriveBackupService _service = DriveBackupService.instance;
  final DriveBackupSettingsService _settings =
      DriveBackupSettingsService.instance;
  final DataExportImportService _exportImportService =
      DataExportImportService();

  DriveBackupConfig? _config;
  List<DriveBackupEntry> _backups = const [];
  String? _currentKeyId;
  bool _loading = true;
  bool _connecting = false;
  bool _creatingBackup = false;
  bool _refreshing = false;
  String? _restoringId;
  String? _listError;
  TimeOfDay _summaryTime = const TimeOfDay(hour: 20, minute: 0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _settings.ensureLoaded();
    final summaryTime =
        await NotificationSettingsService.instance.getDailySummaryTime();
    final keyId = await _service.currentKeyId();
    if (!mounted) return;
    setState(() {
      _config = _settings.config.value;
      _summaryTime = summaryTime;
      _currentKeyId = keyId;
      _loading = false;
    });
    if (_config != null) await _refreshBackups();
  }

  Future<void> _refreshBackups() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _listError = null;
    });
    try {
      final backups = await _service.listBackups();
      await _settings.reload();
      if (!mounted) return;
      setState(() {
        _config = _settings.config.value;
        _backups = backups;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _listError = _message(error));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      final result = await _connectWithRecoveryKey();
      if (result == null || !mounted) return;
      await DriveBackupScheduler.sync();
      final keyId = await _service.currentKeyId();
      if (!mounted) return;
      setState(() {
        _config = result.config;
        _currentKeyId = keyId;
        _backups = const [];
        _listError = null;
      });
      if (result.shouldShowRecoveryKey) {
        await _showRecoveryKey(result.formattedRecoveryKey, firstTime: true);
      }
      if (mounted) await _refreshBackups();
    } catch (error) {
      if (mounted) _showError(_message(error));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<DriveConnectionResult?> _connectWithRecoveryKey() async {
    String? recoveryKey;
    var startFresh = false;
    while (mounted) {
      try {
        return await _service.connect(
          recoveryKey: recoveryKey,
          startFresh: startFresh,
        );
      } on DriveRecoveryKeyRequiredException {
        recoveryKey = await _askForRecoveryKey();
      } on DriveRecoveryKeyInvalidException catch (error) {
        recoveryKey = await _askForRecoveryKey(error: error.message);
      }
      if (recoveryKey == null) {
        startFresh = await _confirmStartFresh();
        if (!startFresh) return null;
      }
    }
    return null;
  }

  Future<String?> _askForRecoveryKey({String? error}) async {
    return showTelegramRecoveryKeyDialog(
      context: context,
      title: context.l10nTextRead('Recovery key needed'),
      description: context.l10nTextRead(
        'Your Google Drive already has encrypted Totals backups. Enter '
        'their recovery key to use them on this device.',
      ),
      recoveryKeyLabel: context.l10nTextRead('Recovery key'),
      invalidKeyMessage: context.l10nTextRead(
        'Enter the 64-character Totals recovery key.',
      ),
      chooseFileLabel: context.l10nTextRead('Upload recovery key .txt'),
      invalidFileMessage: context.l10nTextRead(
        'That file does not contain a valid Totals recovery key.',
      ),
      fileReadErrorMessage: context.l10nTextRead(
        'Could not read the recovery key file.',
      ),
      cancelLabel: context.l10nTextRead('Cancel'),
      connectLabel: context.l10nTextRead('Connect'),
      error: error,
    );
  }

  Future<bool> _confirmStartFresh() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10nText('Start with a new key?')),
        content: Text(
          dialogContext.l10nText(
            'Totals will create a new recovery key for future backups. The '
            'existing backups stay in your Google Drive but can only be '
            'restored with their old key.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10nText('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10nText('Use a new key')),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _createBackup() async {
    if (_creatingBackup) return;
    setState(() => _creatingBackup = true);
    try {
      await _service.backupNow();
      if (!mounted) return;
      _showSnack(context.l10nTextRead('Backup saved to Google Drive'));
      await _refreshBackups();
    } catch (error) {
      if (mounted) _showError(_message(error));
    } finally {
      if (mounted) {
        setState(() {
          _creatingBackup = false;
          _config = _settings.config.value;
        });
      }
    }
  }

  Future<void> _restore(DriveBackupEntry entry) async {
    if (_restoringId != null) return;
    setState(() => _restoringId = entry.fileId);
    try {
      final jsonData = await _downloadWithRecoveryKey(entry);
      if (jsonData == null || !mounted) return;
      final summary = DataExportImportService.inspectImportPayload(jsonData);
      final options = await showDataImportOptionsSheet(
        context: context,
        summary: summary,
      );
      if (options == null || !mounted) return;
      await _exportImportService.importAllData(jsonData, options: options);
      if (!mounted) return;
      try {
        await Provider.of<TransactionProvider>(
          context,
          listen: false,
        ).loadData();
      } catch (_) {}
      if (mounted) {
        _showSnack(context.l10nTextRead('Data imported successfully'));
      }
    } catch (error) {
      if (mounted) {
        _showError(
          '${context.l10nTextRead('Import failed')}: ${_message(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _restoringId = null);
    }
  }

  Future<String?> _downloadWithRecoveryKey(DriveBackupEntry entry) async {
    String? recoveryKey;
    while (mounted) {
      try {
        return await _service.downloadBackup(entry, recoveryKey: recoveryKey);
      } on DriveRecoveryKeyRequiredException {
        recoveryKey = await _askForRecoveryKey();
      } on DriveRecoveryKeyInvalidException catch (error) {
        recoveryKey = await _askForRecoveryKey(error: error.message);
      }
      if (recoveryKey == null) return null;
    }
    return null;
  }

  Future<void> _changeSchedule(DriveBackupSchedule? schedule) async {
    if (schedule == null) return;
    await _service.setSchedule(schedule);
    await DriveBackupScheduler.sync();
    if (mounted) setState(() => _config = _settings.config.value);
  }

  Future<void> _changeEncrypt(bool encrypt) async {
    if (!encrypt) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(dialogContext.l10nText('Turn off encryption?')),
          content: Text(
            dialogContext.l10nText(
              'Backups are stored in a hidden folder only Totals can open, '
              'but without encryption anyone who gets into your Google '
              'account could read them with the right tools.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dialogContext.l10nText('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(dialogContext.l10nText('Turn off')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _service.setEncrypt(encrypt);
    if (mounted) setState(() => _config = _settings.config.value);
  }

  Future<void> _changeKeepCount(int? keepCount) async {
    if (keepCount == null) return;
    await _service.setKeepCount(keepCount);
    if (mounted) setState(() => _config = _settings.config.value);
  }

  Future<void> _revealRecoveryKey() async {
    try {
      final key = await _service.formattedRecoveryKey();
      if (mounted) await _showRecoveryKey(key);
    } catch (error) {
      if (mounted) _showError(_message(error));
    }
  }

  Future<void> _showRecoveryKey(
    String recoveryKey, {
    bool firstTime = false,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: !firstTime,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          dialogContext.l10nText(
            firstTime ? 'Save your recovery key' : 'Recovery key',
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dialogContext.l10nText(
                'This key is the only way to open your encrypted Google '
                'Drive backups on another device. Totals never uploads it.',
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceColor(dialogContext),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.borderColor(dialogContext),
                ),
              ),
              child: SelectableText(
                recoveryKey,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              dialogContext.l10nText(
                'Keep it somewhere separate from this phone and your Google '
                'account.',
              ),
              style: TextStyle(
                color: AppColors.textSecondary(dialogContext),
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: recoveryKey));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      dialogContext.l10nTextRead('Recovery key copied'),
                    ),
                  ),
                );
              }
            },
            icon: const Icon(AppIcons.copy, size: 18),
            label: Text(dialogContext.l10nText('Copy')),
          ),
          TextButton.icon(
            onPressed: () => _saveRecoveryKey(recoveryKey),
            icon: const Icon(AppIcons.download_rounded, size: 18),
            label: Text(dialogContext.l10nText('Save')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.l10nText('Done')),
          ),
        ],
      ),
    );
  }

  Future<void> _saveRecoveryKey(String recoveryKey) async {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final fileName = 'totals_drive_recovery_key_'
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}.txt';
    final contents = [
      'Totals Google Drive Backup recovery key',
      '',
      recoveryKey,
      '',
      'Keep this file private and separate from your phone.',
      'Totals cannot recover this key for you.',
    ].join('\n');

    try {
      final bytes = Uint8List.fromList(utf8.encode(contents));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Totals recovery key',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['txt'],
        bytes: bytes,
      );
      if (path == null || path.isEmpty) return;
      if (!Platform.isAndroid && !Platform.isIOS) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (mounted) _showSnack(context.l10nTextRead('Recovery key saved'));
    } catch (error) {
      if (mounted) {
        _showError(
          '${context.l10nTextRead('Could not save')}: ${_message(error)}',
        );
      }
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10nText('Disconnect Google Drive Backup?')),
        content: Text(
          dialogContext.l10nText(
            'Backups stay in your Google Drive. You can reconnect later; '
            'encrypted backups need this recovery key.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10nText('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10nText('Disconnect')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.disconnect();
    await DriveBackupScheduler.sync();
    if (!mounted) return;
    setState(() {
      _config = null;
      _backups = const [];
      _listError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background(context),
      appBar: AppBar(
        title: Text(context.l10nText('Google Drive Backup')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _config == null
              ? _buildSetup()
              : _buildConnected(_config!),
    );
  }

  Widget _buildSetup() {
    final supported = TotalsGoogleAuth.isSupported;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        DataSyncCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.add_to_drive_rounded,
                      color: AppColors.primaryLight,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.l10nText(
                        'Back up to your own Google Drive',
                      ),
                      style: TextStyle(
                        color: AppColors.textPrimary(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                context.l10nText(
                  'Totals only asks for access to its own hidden app folder '
                  'in your Drive. It cannot see your other files, and the '
                  'backups do not use a Totals server. Backups are encrypted '
                  'on this device with a recovery key by default.',
                ),
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _connecting || !supported ? null : _connect,
                  icon: _connecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.link_rounded),
                  label: Text(
                    context.l10nText(
                      _connecting ? 'Connecting…' : 'Connect Google Drive',
                    ),
                  ),
                ),
              ),
              if (!supported) ...[
                const SizedBox(height: 8),
                Text(
                  context.l10nText(
                    'Google Drive backup is available on Android.',
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary(context),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          context.l10nText(
            'Automatic backups start weekly after your summary time, over '
            'Wi-Fi or mobile data. Older backups are deleted to keep the '
            'newest 10.',
          ),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textTertiary(context),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildConnected(DriveBackupConfig config) {
    return RefreshIndicator(
      onRefresh: _refreshBackups,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          DataSyncCard(
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.incomeSuccess.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.add_to_drive_rounded,
                        color: AppColors.incomeSuccess,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            config.accountEmail ??
                                context.l10nText('Google account'),
                            style: TextStyle(
                              color: AppColors.textPrimary(context),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            context.l10nText('Hidden Totals app folder'),
                            style: TextStyle(
                              color: AppColors.textSecondary(context),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _creatingBackup ? null : _createBackup,
                    icon: _creatingBackup
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(AppIcons.upload_rounded),
                    label: Text(
                      context.l10nText(
                        _creatingBackup ? 'Uploading…' : 'Back up now',
                      ),
                    ),
                  ),
                ),
                if (config.lastBackupAt != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${context.l10nText('Last backup')}: '
                    '${_formatDriveBackupDate(context, config.lastBackupAt!)}',
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 12,
                    ),
                  ),
                ],
                if (config.lastBackupError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    config.lastBackupError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.red,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          DataSyncSectionHeader(context.l10nText('Automatic backups')),
          DataSyncCard(
            child: Column(
              children: [
                _SettingRow(
                  title: context.l10nText('Schedule'),
                  subtitle: _scheduleDescription(config.schedule),
                  trailing: DropdownButton<DriveBackupSchedule>(
                    value: config.schedule,
                    underline: const SizedBox.shrink(),
                    onChanged: _changeSchedule,
                    items: [
                      for (final schedule in DriveBackupSchedule.values)
                        DropdownMenuItem(
                          value: schedule,
                          child: Text(_scheduleLabel(schedule)),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                _SettingRow(
                  title: context.l10nText('Keep backups'),
                  subtitle: context.l10nText(
                    'Older backups are deleted from Drive',
                  ),
                  trailing: DropdownButton<int>(
                    value: DriveBackupConfig.keepCountOptions
                            .contains(config.keepCount)
                        ? config.keepCount
                        : null,
                    hint: Text('${config.keepCount}'),
                    underline: const SizedBox.shrink(),
                    onChanged: _changeKeepCount,
                    items: [
                      for (final count in DriveBackupConfig.keepCountOptions)
                        DropdownMenuItem(
                          value: count,
                          child: Text('$count'),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                _SettingRow(
                  title: context.l10nText('Encrypt backups'),
                  subtitle: context.l10nText(
                    config.encrypt
                        ? 'Restoring on another device needs the recovery key'
                        : 'Backups are stored as readable JSON',
                  ),
                  trailing: Switch(
                    value: config.encrypt,
                    onChanged: _changeEncrypt,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          DataSyncTile(
            icon: Icons.key_rounded,
            title: context.l10nText('Recovery key'),
            subtitle: context.l10nText('Reveal, copy, or save your key'),
            showChevron: true,
            onTap: _revealRecoveryKey,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: DataSyncSectionHeader(
                  context.l10nText('Backups in Google Drive'),
                ),
              ),
              if (_refreshing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  tooltip: context.l10nText('Refresh'),
                  onPressed: _refreshBackups,
                  icon: const Icon(AppIcons.refresh, size: 20),
                ),
            ],
          ),
          if (_listError != null)
            _ErrorCard(message: _listError!, onRetry: _refreshBackups)
          else if (_backups.isEmpty && !_refreshing)
            DataSyncCard(
              child: Column(
                children: [
                  Icon(
                    AppIcons.cloud_download,
                    color: AppColors.textTertiary(context),
                    size: 30,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10nText('No backups yet'),
                    style: TextStyle(
                      color: AppColors.textPrimary(context),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.l10nText(
                      'Tap Back up now to create the first backup.',
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary(context),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            )
          else
            for (final backup in _backups) ...[
              _BackupTile(
                entry: backup,
                otherKey: backup.encrypted &&
                    backup.keyId != null &&
                    backup.keyId != _currentKeyId,
                restoring: _restoringId == backup.fileId,
                restoreEnabled: _restoringId == null,
                onRestore: () => _restore(backup),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 22),
          TextButton(
            onPressed: _disconnect,
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: Text(context.l10nText('Disconnect Google Drive Backup')),
          ),
        ],
      ),
    );
  }

  String _scheduleLabel(DriveBackupSchedule schedule) {
    switch (schedule) {
      case DriveBackupSchedule.manual:
        return context.l10nText('Manual');
      case DriveBackupSchedule.daily:
        return context.l10nText('Daily');
      case DriveBackupSchedule.weekly:
        return context.l10nText('Weekly');
    }
  }

  String _scheduleDescription(DriveBackupSchedule schedule) {
    final formattedTime =
        MaterialLocalizations.of(context).formatTimeOfDay(_summaryTime);
    switch (schedule) {
      case DriveBackupSchedule.manual:
        return context.l10nText('Create backups whenever you choose');
      case DriveBackupSchedule.daily:
        return '${context.l10nText('After your daily summary time')} · '
            '$formattedTime';
      case DriveBackupSchedule.weekly:
        return '${context.l10nText('Sundays after')} $formattedTime';
    }
  }

  String _message(Object error) {
    if (error is GoogleAuthException) return error.message;
    return error.toString().replaceFirst('Exception: ', '').trim();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.red,
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget trailing;

  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: AppColors.textPrimary(context),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: AppColors.textSecondary(context),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        trailing,
      ],
    );
  }
}

class _BackupTile extends StatelessWidget {
  final DriveBackupEntry entry;
  final bool otherKey;
  final bool restoring;
  final bool restoreEnabled;
  final VoidCallback onRestore;

  const _BackupTile({
    required this.entry,
    required this.otherKey,
    required this.restoring,
    required this.restoreEnabled,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final details = [
      _formatDriveBackupBytes(entry.size),
      'Schema v${entry.exportSchemaVersion}',
      context.l10nText(entry.encrypted ? 'Encrypted' : 'Not encrypted'),
      if (otherKey) context.l10nText('Other recovery key'),
    ].join(' · ');
    return DataSyncCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.primaryLight.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              entry.encrypted ? Icons.lock_rounded : AppIcons.cloud_download,
              color: AppColors.primaryLight,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatDriveBackupDate(context, entry.createdAt),
                  style: TextStyle(
                    color: AppColors.textPrimary(context),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  style: TextStyle(
                    color: AppColors.textSecondary(context),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: restoring || !restoreEnabled ? null : onRestore,
            child: restoring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.l10nText('Restore')),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorCard({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return DataSyncCard(
      child: Column(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.red),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary(context),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onRetry,
            child: Text(context.l10nText('Retry')),
          ),
        ],
      ),
    );
  }
}

String _formatDriveBackupDate(BuildContext context, DateTime date) {
  final local = date.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatMediumDate(local)} · '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

String _formatDriveBackupBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
