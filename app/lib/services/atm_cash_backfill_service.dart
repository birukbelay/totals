import 'package:shared_preferences/shared_preferences.dart';
import 'package:totals/constants/cash_constants.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/repositories/account_repository.dart';
import 'package:totals/repositories/profile_repository.dart';
import 'package:totals/repositories/transaction_repository.dart';
import 'package:totals/repositories/transaction_source_sms_repository.dart';
import 'package:totals/utils/atm_cash_transfers.dart';
import 'package:totals/utils/transaction_amounts.dart';

/// Creates Cash Wallet entries for ATM withdrawals that were parsed before
/// the cash pocket existed, from the stored transactions and their source
/// SMS. Nothing is reparsed from the inbox.
class AtmCashBackfillService {
  static const String _enabledPrefPrefix = 'atm_cash_backfill_enabled_profile_';
  // Written by SmsService; withdrawals before it get no cash entry unless the
  // user opted in to the backfill.
  static const String _cutoffPrefPrefix =
      'atm_cash_transfer_cutoff_iso_profile_';

  final TransactionRepository _transactionRepository;
  final TransactionSourceSmsRepository _sourceSmsRepository;
  final AccountRepository _accountRepository;

  AtmCashBackfillService({
    TransactionRepository? transactionRepository,
    TransactionSourceSmsRepository? sourceSmsRepository,
    AccountRepository? accountRepository,
  })  : _transactionRepository =
            transactionRepository ?? TransactionRepository(),
        _sourceSmsRepository =
            sourceSmsRepository ?? TransactionSourceSmsRepository(),
        _accountRepository = accountRepository ?? AccountRepository();

  /// Whether the active profile asked for cash entries of past withdrawals.
  /// Once it has, withdrawals before the cash cutoff keep their entries.
  static Future<bool> isEnabledForActiveProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(await _enabledPrefKey()) ?? false;
  }

  static Future<String> _enabledPrefKey() =>
      _profilePrefKey(_enabledPrefPrefix);

  static Future<String> _profilePrefKey(String prefix) async {
    final profileId = await ProfileRepository().getActiveProfileId();
    return profileId != null ? '$prefix$profileId' : '${prefix}default';
  }

  /// Creates the missing cash entries and returns how many were added.
  Future<int> backfill() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(await _enabledPrefKey(), true);
    return _createMissingLegs();
  }

  /// Creates the cash entries a newly labeled account would have received
  /// had it been registered when its SMS arrived: every withdrawal when the
  /// user opted in to the backfill, otherwise only those after the cash
  /// cutoff. Returns how many were added.
  Future<int> createLegsForLabeledAccount() async {
    if (await isEnabledForActiveProfile()) return _createMissingLegs();
    final prefs = await SharedPreferences.getInstance();
    final cutoff = DateTime.tryParse(
      prefs.getString(await _profilePrefKey(_cutoffPrefPrefix)) ?? '',
    );
    if (cutoff == null) return 0;
    return _createMissingLegs(notBefore: cutoff);
  }

  Future<int> _createMissingLegs({DateTime? notBefore}) async {
    final transactions = await _transactionRepository.getTransactions(
      includeUnlabeled: false,
    );
    final references = {
      for (final transaction in transactions) transaction.reference,
    };
    final candidates = transactions.where((transaction) {
      final bankId = transaction.bankId;
      if (notBefore != null) {
        final time = DateTime.tryParse(transaction.time ?? '');
        if (time == null || time.isBefore(notBefore)) return false;
      }
      return transaction.type == 'DEBIT' &&
          bankId != null &&
          bankId != CashConstants.bankId &&
          !references.contains(
            CashConstants.buildAtmReference(transaction.reference),
          );
    }).toList(growable: false);
    if (candidates.isEmpty) return 0;

    final sources = await _sourceSmsRepository.getForTransactionReferences(
      candidates.map((transaction) => transaction.reference),
    );
    final bodyByReference = {
      for (final source in sources) source.transactionReference: source.body,
    };
    final withdrawals = candidates
        .where(
          (transaction) => looksLikeAtmWithdrawal(
            type: transaction.type,
            body: bodyByReference[transaction.reference],
            fallbackText: [transaction.creditor, transaction.receiver],
          ),
        )
        .toList(growable: false);
    if (withdrawals.isEmpty) return 0;

    final accounts = await _accountRepository.getAccounts();
    final openingBalance = accounts
        .where((account) => account.bank == CashConstants.bankId)
        .fold<double>(0.0, (sum, account) => sum + account.balance);
    final cashTransactions = transactions
        .where((transaction) => transaction.bankId == CashConstants.bankId);
    final legs = buildBackfilledCashLegs(
      withdrawals: withdrawals,
      cashTransactions: cashTransactions,
      openingBalance: openingBalance,
    );
    await _transactionRepository.saveAllTransactions(legs);
    return legs.length;
  }
}

/// Cash legs for [withdrawals], each with the cash pocket's running balance
/// after it, counting the existing [cashTransactions] in time order.
List<Transaction> buildBackfilledCashLegs({
  required Iterable<Transaction> withdrawals,
  required Iterable<Transaction> cashTransactions,
  required double openingBalance,
}) {
  final timeline = <_CashEvent>[
    for (final transaction in cashTransactions)
      _CashEvent(transaction, withdrawal: null),
    for (final withdrawal in withdrawals)
      _CashEvent(
        buildAtmCashLeg(withdrawal, cashBalanceAfter: 0),
        withdrawal: withdrawal,
      ),
  ]..sort((a, b) => a.time.compareTo(b.time));

  var balance = openingBalance;
  final legs = <Transaction>[];
  for (final event in timeline) {
    balance += transactionBalanceDelta(event.transaction);
    final withdrawal = event.withdrawal;
    if (withdrawal != null) {
      legs.add(buildAtmCashLeg(withdrawal, cashBalanceAfter: balance));
    }
  }
  return legs;
}

class _CashEvent {
  final Transaction transaction;
  final Transaction? withdrawal;
  final String time;

  _CashEvent(this.transaction, {required this.withdrawal})
      : time = transaction.time ?? '';
}
