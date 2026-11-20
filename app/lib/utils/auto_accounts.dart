import 'package:totals/constants/cash_constants.dart';
import 'package:totals/models/account.dart';
import 'package:totals/models/bank.dart';
import 'package:totals/utils/account_identity.dart';
import 'package:totals/utils/unlabeled_accounts.dart';

/// An account found in bank SMS that Totals can add on the user's behalf.
class AutoAccountCandidate {
  final int bankId;
  final String accountNumber;
  final String accountHolderName;

  const AutoAccountCandidate({
    required this.bankId,
    required this.accountNumber,
    required this.accountHolderName,
  });

  /// Identifies the account across runs, so one the user deleted is not
  /// added again.
  String key(Bank bank) =>
      '${bank.id}|${canonicalAccountNumber(bank, accountNumber) ?? accountNumber}';
}

/// Decides which accounts to add for the unlabeled [groups].
///
/// - A group with an account number becomes an account with that number,
///   unless the bank already has an account matching it.
/// - Groups without a number (SIM wallets, or messages that don't name the
///   account) become one account per bank, only when the bank has none yet.
///   A wallet takes the number its messages call "your account"; otherwise
///   it gets the bank's short name as a placeholder.
/// - The holder name is the most common greeting name, so later messages
///   greeting that person find the account. Without one it is the bank's
///   short name.
///
/// Keys in [skipKeys] (see [AutoAccountCandidate.key]) are left out. Within
/// each kind, groups keep their order (busiest first), so the busiest
/// account of a bank, added first, becomes its default.
List<AutoAccountCandidate> planAutoAccounts({
  required List<UnlabeledAccountGroup> groups,
  required Map<int, Bank> banksById,
  required Iterable<Account> accounts,
  Map<String, String> bodyByReference = const {},
  Set<String> skipKeys = const {},
}) {
  final planned = <AutoAccountCandidate>[];
  final existing = accounts.toList(growable: false);

  bool bankHasAccount(int bankId) =>
      existing.any((account) => account.bank == bankId) ||
      planned.any((candidate) => candidate.bankId == bankId);

  bool numberTaken(Bank bank, String number) =>
      existing.any((account) =>
          account.bank == bank.id &&
          accountNumbersMatch(bank, account.accountNumber, number)) ||
      planned.any((candidate) =>
          candidate.bankId == bank.id &&
          accountNumbersMatch(bank, candidate.accountNumber, number));

  // Numbered groups go first: once a bank has a real account, its messages
  // that name no account fall to that account as the bank's default.
  final ordered = [
    ...groups.where((group) => group.accountNumber != null),
    ...groups.where((group) => group.accountNumber == null),
  ];
  for (final group in ordered) {
    if (group.bankId == CashConstants.bankId) continue;
    final bank = banksById[group.bankId];
    if (bank == null) continue;

    final String number;
    if (group.accountNumber != null) {
      number = _mostRevealingNumber(bank, group);
      if (numberTaken(bank, number)) continue;
    } else {
      if (bankHasAccount(bank.id)) continue;
      final ownNumber = bank.simBased == true
          ? _mostCommonOwnNumber(bank, group, bodyByReference)
          : null;
      number = ownNumber ?? _placeholderNumber(bank);
    }

    final holder = group.holderNameSuggestion?.trim();
    final candidate = AutoAccountCandidate(
      bankId: bank.id,
      accountNumber: number,
      accountHolderName:
          holder == null || holder.isEmpty ? bank.shortName : holder,
    );
    if (skipKeys.contains(candidate.key(bank))) continue;
    planned.add(candidate);
  }
  return planned;
}

/// The variant of the group's number that shows the most digits, since
/// masks can differ between messages of one account.
String _mostRevealingNumber(Bank bank, UnlabeledAccountGroup group) {
  var best = group.accountNumber!.trim();
  var bestDigits = _digitCount(best);
  for (final transaction in group.transactions) {
    final value = transaction.accountNumber?.trim();
    if (value == null || value.isEmpty) continue;
    if (!accountNumbersMatch(bank, value, best)) continue;
    final digits = _digitCount(value);
    if (digits > bestDigits) {
      best = value;
      bestDigits = digits;
    }
  }
  return best;
}

String? _mostCommonOwnNumber(
  Bank bank,
  UnlabeledAccountGroup group,
  Map<String, String> bodyByReference,
) {
  final counts = <String, int>{};
  for (final transaction in group.transactions) {
    final body = bodyByReference[transaction.reference];
    if (body == null) continue;
    for (final raw in ownerAccountNumbersFromMessage(body)) {
      final canonical = canonicalAccountNumber(bank, raw);
      // Masked numbers can't name the wallet on their own.
      if (canonical == null || raw.contains(RegExp(r'[Xx*]'))) continue;
      counts[canonical] = (counts[canonical] ?? 0) + 1;
    }
  }
  String? best;
  var bestCount = 0;
  counts.forEach((number, count) {
    if (count > bestCount) {
      best = number;
      bestCount = count;
    }
  });
  return best;
}

String _placeholderNumber(Bank bank) {
  final name =
      bank.shortName.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return name.isEmpty ? 'BANK${bank.id}' : name;
}

int _digitCount(String value) => RegExp(r'\d').allMatches(value).length;
