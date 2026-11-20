import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:totals/models/account.dart';
import 'package:totals/models/bank.dart';
import 'package:totals/repositories/account_repository.dart';
import 'package:totals/repositories/profile_repository.dart';
import 'package:totals/repositories/transaction_repository.dart';
import 'package:totals/repositories/transaction_source_sms_repository.dart';
import 'package:totals/services/bank_config_service.dart';
import 'package:totals/services/sms_service.dart';
import 'package:totals/services/unlabeled_account_service.dart';
import 'package:totals/utils/auto_accounts.dart';
import 'package:totals/utils/unlabeled_accounts.dart';

/// What one [AutoAccountService.run] did.
class AutoAccountResult {
  final int messagesAdded;
  final int accountsAdded;
  final int transactionsLabeled;

  const AutoAccountResult({
    this.messagesAdded = 0,
    this.accountsAdded = 0,
    this.transactionsLabeled = 0,
  });

  bool get changedData =>
      messagesAdded > 0 || accountsAdded > 0 || transactionsLabeled > 0;
}

/// Reads every bank SMS once and adds the accounts the messages belong to,
/// so transactions show up without the user adding accounts by hand.
class AutoAccountService {
  static const String _fullImportPrefPrefix = 'auto_account_full_import_v1_';
  static const String _addedKeysPrefPrefix = 'auto_account_added_keys_v1_';

  /// True while a run is reading messages or adding accounts.
  static final ValueNotifier<bool> running = ValueNotifier<bool>(false);
  static bool _hasRunThisLaunch = false;

  final SmsService? _smsService;
  final TransactionRepository _transactionRepository;
  final TransactionSourceSmsRepository _sourceSmsRepository;
  final AccountRepository _accountRepository;
  final BankConfigService _bankConfigService;
  final UnlabeledAccountService _unlabeledAccountService;

  AutoAccountService({
    SmsService? smsService,
    TransactionRepository? transactionRepository,
    TransactionSourceSmsRepository? sourceSmsRepository,
    AccountRepository? accountRepository,
    BankConfigService? bankConfigService,
    UnlabeledAccountService? unlabeledAccountService,
  })  : _smsService = smsService,
        _transactionRepository =
            transactionRepository ?? TransactionRepository(),
        _sourceSmsRepository =
            sourceSmsRepository ?? TransactionSourceSmsRepository(),
        _accountRepository = accountRepository ?? AccountRepository(),
        _bankConfigService = bankConfigService ?? BankConfigService(),
        _unlabeledAccountService =
            unlabeledAccountService ?? UnlabeledAccountService();

  /// Runs once per app launch: the first launch of a profile reads the whole
  /// inbox, later ones only add accounts for messages that arrived since.
  static Future<AutoAccountResult?> runOnAppOpen() async {
    if (_hasRunThisLaunch || running.value) return null;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    if (!(await Permission.sms.status).isGranted) return null;
    _hasRunThisLaunch = true;
    try {
      return await AutoAccountService(smsService: SmsService()).run();
    } catch (error) {
      debugPrint('debug: Automatic account setup failed: $error');
      return null;
    }
  }

  /// Imports the inbox when it has not been read in full yet (or always,
  /// with [fullImport]), then adds the accounts found in the messages.
  Future<AutoAccountResult> run({bool fullImport = false}) async {
    if (running.value) return const AutoAccountResult();
    running.value = true;
    try {
      await _bankConfigService.initializeBanks();
      final prefs = await SharedPreferences.getInstance();
      final importKey = await _profilePrefKey(_fullImportPrefPrefix);

      var messagesAdded = 0;
      final smsService = _smsService;
      if (smsService != null &&
          (fullImport || !(prefs.getBool(importKey) ?? false))) {
        final imported = await smsService.importAllBankSms();
        messagesAdded = imported.added;
        if (!imported.permissionDenied) {
          await prefs.setBool(importKey, true);
        }
      }

      final registered = await addDetectedAccounts();
      return AutoAccountResult(
        messagesAdded: messagesAdded,
        accountsAdded: registered.accountsAdded,
        transactionsLabeled: registered.transactionsLabeled,
      );
    } finally {
      running.value = false;
    }
  }

  /// Adds an account for each account found in the saved unlabeled
  /// messages and moves the messages onto it. Accounts added before are not
  /// added again, even after the user deleted them.
  Future<AutoAccountResult> addDetectedAccounts() async {
    final transactions =
        await _transactionRepository.getUnlabeledTransactions();
    if (transactions.isEmpty) return const AutoAccountResult();

    final banks = await _bankConfigService.getBanks(allowRemoteFetch: false);
    final banksById = <int, Bank>{for (final bank in banks) bank.id: bank};
    final bodyByReference = await _bodiesFor(
      transactions.map((transaction) => transaction.reference),
    );
    final groups = buildUnlabeledAccountGroups(
      transactions,
      banksById: banksById,
      bodyByReference: bodyByReference,
    );

    final prefs = await SharedPreferences.getInstance();
    final addedKeysKey = await _profilePrefKey(_addedKeysPrefPrefix);
    final addedKeys =
        (prefs.getStringList(addedKeysKey) ?? const <String>[]).toSet();
    final candidates = planAutoAccounts(
      groups: groups,
      banksById: banksById,
      accounts: await _accountRepository.getAccounts(),
      bodyByReference: bodyByReference,
      skipKeys: addedKeys,
    );
    if (candidates.isEmpty) return const AutoAccountResult();

    // All accounts of a bank exist before its messages are labeled, so the
    // first one (the bank's default) doesn't take the others' messages.
    final addedByBank = <int, List<String>>{};
    for (final candidate in candidates) {
      if (await _accountRepository.accountExists(
        candidate.accountNumber,
        candidate.bankId,
      )) {
        continue;
      }
      await _accountRepository.saveAccount(
        Account(
          accountNumber: candidate.accountNumber,
          bank: candidate.bankId,
          balance: 0.0,
          accountHolderName: candidate.accountHolderName,
        ),
      );
      addedKeys.add(candidate.key(banksById[candidate.bankId]!));
      addedByBank
          .putIfAbsent(candidate.bankId, () => <String>[])
          .add(candidate.accountNumber);
    }
    await prefs.setStringList(addedKeysKey, addedKeys.toList()..sort());

    var labeled = 0;
    for (final entry in addedByBank.entries) {
      try {
        final result =
            await _unlabeledAccountService.labelSavedTransactionsForAccounts(
          bankId: entry.key,
          accountNumbers: entry.value,
        );
        labeled += result.labeled;
      } catch (error) {
        debugPrint('debug: Could not label messages of bank ${entry.key}: '
            '$error');
      }
    }

    final accountsAdded =
        addedByBank.values.fold<int>(0, (sum, numbers) => sum + numbers.length);
    debugPrint('debug: Added $accountsAdded accounts from bank SMS, '
        'labeled $labeled transactions');
    return AutoAccountResult(
      accountsAdded: accountsAdded,
      transactionsLabeled: labeled,
    );
  }

  Future<Map<String, String>> _bodiesFor(Iterable<String> references) async {
    final sources =
        await _sourceSmsRepository.getForTransactionReferences(references);
    return {
      for (final source in sources) source.transactionReference: source.body,
    };
  }

  static Future<String> _profilePrefKey(String prefix) async {
    final profileId = await ProfileRepository().getActiveProfileId();
    return profileId != null ? '$prefix$profileId' : '${prefix}default';
  }
}
