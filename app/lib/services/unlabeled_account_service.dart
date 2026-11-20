import 'package:flutter/foundation.dart';
import 'package:totals/models/account.dart';
import 'package:totals/models/bank.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/repositories/account_repository.dart';
import 'package:totals/repositories/transaction_repository.dart';
import 'package:totals/repositories/transaction_source_sms_repository.dart';
import 'package:totals/services/atm_cash_backfill_service.dart';
import 'package:totals/services/bank_config_service.dart';
import 'package:totals/services/person_matcher_service.dart';
import 'package:totals/utils/unlabeled_accounts.dart';

/// What [UnlabeledAccountService.labelSavedTransactions] changed.
class UnlabeledLabelResult {
  final int labeled;
  final int cashLegs;
  final double? balance;

  const UnlabeledLabelResult({
    this.labeled = 0,
    this.cashLegs = 0,
    this.balance,
  });
}

/// Moves SMS transactions saved before their account was registered onto
/// the account, from the stored rows and their source SMS. Nothing is
/// reparsed from the inbox.
class UnlabeledAccountService {
  final TransactionRepository _transactionRepository;
  final TransactionSourceSmsRepository _sourceSmsRepository;
  final AccountRepository _accountRepository;
  final BankConfigService _bankConfigService;

  UnlabeledAccountService({
    TransactionRepository? transactionRepository,
    TransactionSourceSmsRepository? sourceSmsRepository,
    AccountRepository? accountRepository,
    BankConfigService? bankConfigService,
  })  : _transactionRepository =
            transactionRepository ?? TransactionRepository(),
        _sourceSmsRepository =
            sourceSmsRepository ?? TransactionSourceSmsRepository(),
        _accountRepository = accountRepository ?? AccountRepository(),
        _bankConfigService = bankConfigService ?? BankConfigService();

  /// Groups the unlabeled transactions of the active profile by account.
  Future<List<UnlabeledAccountGroup>> loadGroups() async {
    final transactions =
        await _transactionRepository.getUnlabeledTransactions();
    if (transactions.isEmpty) return const [];
    final banks = await _bankConfigService.getBanks(allowRemoteFetch: false);
    return buildUnlabeledAccountGroups(
      transactions,
      banksById: {for (final bank in banks) bank.id: bank},
      bodyByReference: await _bodiesFor(
        transactions.map((transaction) => transaction.reference),
      ),
    );
  }

  /// Labels the saved rows of [bankId] that belong to one of its registered
  /// accounts, sets the balance of [accountNumber] from its newest message
  /// when it has none yet, and adds the cash entries and person links the
  /// rows would have received on arrival.
  Future<UnlabeledLabelResult> labelSavedTransactions({
    required int bankId,
    required String accountNumber,
  }) {
    return labelSavedTransactionsForAccounts(
      bankId: bankId,
      accountNumbers: [accountNumber],
    );
  }

  /// [labelSavedTransactions] for several accounts of [bankId] added
  /// together. Labeling once after all of them exist keeps the bank's default
  /// account from claiming rows that name one of the others. The result's
  /// balance is the one set on the first of [accountNumbers].
  Future<UnlabeledLabelResult> labelSavedTransactionsForAccounts({
    required int bankId,
    required List<String> accountNumbers,
  }) async {
    final transactions =
        await _transactionRepository.getUnlabeledTransactions(bankId: bankId);
    if (transactions.isEmpty) return const UnlabeledLabelResult();

    final bank = await _bankFor(bankId);
    if (bank == null) return const UnlabeledLabelResult();
    final accounts = await _accountRepository.getAccounts();
    final assignments = assignUnlabeledTransactions(
      bank: bank,
      accounts: accounts,
      transactions: transactions,
      bodyByReference: await _bodiesFor(
        transactions.map((transaction) => transaction.reference),
      ),
    );

    var labeled = 0;
    for (final entry in assignments.entries) {
      labeled += await _transactionRepository.labelTransactions(
        references: entry.value,
        ownerAccountNumber: entry.key,
      );
    }
    if (labeled == 0) return const UnlabeledLabelResult();

    double? balance;
    for (var i = 0; i < accountNumbers.length; i++) {
      final applied = await _applyLatestBalance(
        accounts: accounts,
        bankId: bankId,
        accountNumber: accountNumbers[i],
        ownReferences: assignments[accountNumbers[i]] ?? const <String>[],
        transactions: transactions,
      );
      if (i == 0) balance = applied;
    }

    var cashLegs = 0;
    try {
      cashLegs = await AtmCashBackfillService().createLegsForLabeledAccount();
    } catch (error) {
      debugPrint('debug: Could not add cash entries after labeling: $error');
    }
    try {
      await PersonMatcherService.instance.backfill();
    } catch (error) {
      debugPrint('debug: Could not match people after labeling: $error');
    }
    return UnlabeledLabelResult(
      labeled: labeled,
      cashLegs: cashLegs,
      balance: balance,
    );
  }

  Future<double?> _applyLatestBalance({
    required List<Account> accounts,
    required int bankId,
    required String accountNumber,
    required List<String> ownReferences,
    required List<Transaction> transactions,
  }) async {
    if (ownReferences.isEmpty) return null;
    Account? account;
    for (final candidate in accounts) {
      if (candidate.bank == bankId &&
          candidate.accountNumber == accountNumber) {
        account = candidate;
        break;
      }
    }
    // Only a fresh account is filled in; a later SMS keeps it current.
    if (account == null || account.balance.abs() >= 0.0001) return null;

    final references = ownReferences.toSet();
    final balance = latestReportedBalance(
      transactions
          .where((transaction) => references.contains(transaction.reference)),
    );
    if (balance == null) return null;
    await _accountRepository.saveAccount(
      Account(
        accountNumber: account.accountNumber,
        bank: account.bank,
        balance: balance,
        accountHolderName: account.accountHolderName,
        settledBalance: account.settledBalance,
        pendingCredit: account.pendingCredit,
        profileId: account.profileId,
        smsSubscriptionId: account.smsSubscriptionId,
      ),
    );
    return balance;
  }

  Future<Bank?> _bankFor(int bankId) async {
    final banks = await _bankConfigService.getBanks(allowRemoteFetch: false);
    for (final bank in banks) {
      if (bank.id == bankId) return bank;
    }
    return null;
  }

  Future<Map<String, String>> _bodiesFor(Iterable<String> references) async {
    final sources =
        await _sourceSmsRepository.getForTransactionReferences(references);
    return {
      for (final source in sources) source.transactionReference: source.body,
    };
  }
}
