import 'package:totals/models/account.dart';
import 'package:totals/models/bank.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/utils/account_identity.dart';

/// Saved transactions of one bank account the user has not registered yet.
class UnlabeledAccountGroup {
  final int bankId;

  /// The account number as parsed from the SMS, or null when the messages
  /// don't name one (or the bank is a SIM wallet, whose parsed numbers are
  /// often the counterparty).
  final String? accountNumber;
  final List<Transaction> transactions;
  final String? holderNameSuggestion;

  const UnlabeledAccountGroup({
    required this.bankId,
    required this.accountNumber,
    required this.transactions,
    this.holderNameSuggestion,
  });

  int get count => transactions.length;

  DateTime? get firstTime => _edgeTime(latest: false);

  DateTime? get lastTime => _edgeTime(latest: true);

  /// The balance reported by the newest message that has one.
  double? get latestBalance => latestReportedBalance(transactions);

  DateTime? _edgeTime({required bool latest}) {
    DateTime? edge;
    for (final transaction in transactions) {
      final time = DateTime.tryParse(transaction.time ?? '');
      if (time == null) continue;
      if (edge == null || (latest ? time.isAfter(edge) : time.isBefore(edge))) {
        edge = time;
      }
    }
    return edge;
  }
}

/// Groups unlabeled [transactions] by bank and account number, merging
/// masked variants of the same number. Banks missing from [banksById] are
/// skipped. Groups are sorted by message count, largest first.
List<UnlabeledAccountGroup> buildUnlabeledAccountGroups(
  Iterable<Transaction> transactions, {
  required Map<int, Bank> banksById,
  Map<String, String> bodyByReference = const {},
}) {
  final builders = <_GroupBuilder>[];
  for (final transaction in transactions) {
    final bankId = transaction.bankId;
    final bank = bankId == null ? null : banksById[bankId];
    if (bank == null) continue;

    final accountNumber = bank.simBased == true
        ? null
        : canonicalAccountNumber(bank, transaction.accountNumber) == null
            ? null
            : transaction.accountNumber!.trim();
    _GroupBuilder? target;
    for (final builder in builders) {
      if (builder.bank.id != bank.id) continue;
      final sameAccount = accountNumber == null
          ? builder.accountNumber == null
          : builder.accountNumber != null &&
              accountNumbersMatch(bank, builder.accountNumber, accountNumber);
      if (sameAccount) {
        target = builder;
        break;
      }
    }
    if (target == null) {
      target = _GroupBuilder(bank, accountNumber);
      builders.add(target);
    }
    target.transactions.add(transaction);
    final body = bodyByReference[transaction.reference];
    final suggestion =
        body == null ? null : suggestedAccountHolderNameFromSms(body);
    if (suggestion != null) {
      target.suggestions[suggestion] =
          (target.suggestions[suggestion] ?? 0) + 1;
    }
  }

  final groups = builders.map((builder) => builder.build()).toList();
  groups.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    return a.bankId.compareTo(b.bankId);
  });
  return groups;
}

/// Decides which unlabeled [transactions] of [bank] now belong to one of
/// [accounts], using the same rules as a newly received SMS. Returns the
/// references to label, keyed by owner account number. Rows that still match
/// no account are left out.
Map<String, List<String>> assignUnlabeledTransactions({
  required Bank bank,
  required Iterable<Account> accounts,
  required Iterable<Transaction> transactions,
  Map<String, String> bodyByReference = const {},
}) {
  final bankAccounts =
      accounts.where((account) => account.bank == bank.id).toList();
  final assignments = <String, List<String>>{};
  if (bankAccounts.isEmpty) return assignments;

  for (final transaction in transactions) {
    if (transaction.bankId != bank.id) continue;
    final body = bodyByReference[transaction.reference];
    final owner = body != null
        ? resolveSmsOwnership(
            bank: bank,
            accounts: bankAccounts,
            messageBody: body,
            parsedAccountNumber: transaction.accountNumber,
            sourceSubscriptionId: transaction.sourceSubscriptionId,
          )
        : _ownerWithoutBody(bank, bankAccounts, transaction);
    if (owner == null) continue;
    assignments
        .putIfAbsent(owner.accountNumber, () => <String>[])
        .add(transaction.reference);
  }
  return assignments;
}

/// The newest parseable `currentBalance` in [transactions].
double? latestReportedBalance(Iterable<Transaction> transactions) {
  double? balance;
  DateTime? balanceTime;
  for (final transaction in transactions) {
    final value = _parseBalance(transaction.currentBalance);
    if (value == null) continue;
    final time = DateTime.tryParse(transaction.time ?? '');
    if (balance == null ||
        (time != null && (balanceTime == null || time.isAfter(balanceTime)))) {
      balance = value;
      balanceTime = time;
    }
  }
  return balance;
}

Account? _ownerWithoutBody(
  Bank bank,
  List<Account> bankAccounts,
  Transaction transaction,
) {
  final owner = resolveAccountOwnership(
    bank: bank,
    accounts: bankAccounts,
    parsedAccountNumber:
        bank.simBased == true ? null : transaction.accountNumber,
    sourceSubscriptionId: transaction.sourceSubscriptionId,
  );
  if (owner != null) return owner;
  // A parsed number that matches no account names another account of the
  // bank, so the default must not claim it.
  if (bank.simBased != true &&
      canonicalAccountNumber(bank, transaction.accountNumber) != null) {
    return null;
  }
  final defaults = bankAccounts.where((account) => account.isDefault).toList();
  return defaults.length == 1 ? defaults.single : null;
}

double? _parseBalance(String? raw) {
  final cleaned = raw?.replaceAll(RegExp(r'[^0-9.\-]'), '');
  if (cleaned == null || cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

class _GroupBuilder {
  final Bank bank;
  final String? accountNumber;
  final List<Transaction> transactions = [];
  final Map<String, int> suggestions = {};

  _GroupBuilder(this.bank, this.accountNumber);

  UnlabeledAccountGroup build() {
    String? suggestion;
    var best = 0;
    suggestions.forEach((name, count) {
      if (count > best) {
        best = count;
        suggestion = name;
      }
    });
    return UnlabeledAccountGroup(
      bankId: bank.id,
      accountNumber: accountNumber,
      transactions: List<Transaction>.unmodifiable(transactions),
      holderNameSuggestion: suggestion,
    );
  }
}
