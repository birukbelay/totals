import 'package:totals/models/loan_debt_entry.dart';
import 'package:totals/models/person.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/models/transaction_split.dart';

/// Aggregated money flow between the user and one person.
class PersonStats {
  final int personId;
  int transactionCount = 0;

  /// Expense paid to this person (after reimbursements, excluding loans).
  double spent = 0;

  /// Income received from this person (excluding loan repayments).
  double received = 0;

  /// Total ever lent to this person and how much of it is still owed back.
  double lent = 0;
  double lentOutstanding = 0;

  /// Total ever borrowed from this person and how much the user still owes.
  double borrowed = 0;
  double borrowedOutstanding = 0;
  int loanCount = 0;
  DateTime? lastActivity;

  PersonStats(this.personId);

  double get volume => spent + received + lent + borrowed;
}

class PersonTypeStats {
  final PersonType type;
  double spent = 0;
  int transactionCount = 0;

  PersonTypeStats(this.type);
}

class PeopleAnalytics {
  final Map<int, PersonStats> byPerson;
  final Map<PersonType, PersonTypeStats> byType;

  const PeopleAnalytics({
    required this.byPerson,
    required this.byType,
  });

  PersonStats statsFor(int personId) =>
      byPerson[personId] ?? PersonStats(personId);

  List<PersonStats> _ranked(
    double Function(PersonStats stats) value, {
    int limit = 5,
  }) {
    final ranked = byPerson.values.where((stats) => value(stats) > 0).toList()
      ..sort((a, b) => value(b).compareTo(value(a)));
    return ranked.take(limit).toList(growable: false);
  }

  /// Where the user spends most.
  List<PersonStats> topSpending({int limit = 5}) =>
      _ranked((stats) => stats.spent, limit: limit);

  /// Who borrows the most from the user (lifetime lent amount).
  List<PersonStats> topBorrowers({int limit = 5}) =>
      _ranked((stats) => stats.lent, limit: limit);

  /// Who currently owes the user the most.
  List<PersonStats> topOutstanding({int limit = 5}) =>
      _ranked((stats) => stats.lentOutstanding, limit: limit);

  /// Who the user transacts with most often.
  List<PersonStats> topByCount({int limit = 5}) =>
      _ranked((stats) => stats.transactionCount.toDouble(), limit: limit);

  List<PersonTypeStats> spendingByType() {
    final ranked = byType.values.where((stats) => stats.spent > 0).toList()
      ..sort((a, b) => b.spent.compareTo(a.spent));
    return ranked;
  }
}

class PersonAnalyticsService {
  const PersonAnalyticsService();

  /// Builds people analytics from already-loaded provider state.
  ///
  /// [expenseAmount] and [incomeAmount] should be the provider's reimbursement
  /// and self-transfer aware amounts so analytics agree with the home totals.
  /// Transactions that belong to a loan/debt entry count as lending or
  /// borrowing rather than spending or income.
  ///
  /// Loan and bill-share splits in [splitsByReference] count as money lent
  /// to the split's person, outstanding until marked paid. When such a split
  /// belongs to the person the parent payment went to, it is lent rather
  /// than spent.
  PeopleAnalytics build({
    required Iterable<Person> people,
    required Iterable<Transaction> transactions,
    required Map<String, TransactionPersonLink> links,
    required Iterable<LoanDebtEntry> loanEntries,
    required Iterable<LoanDebtRepayment> repayments,
    Map<String, List<TransactionSplit>> splitsByReference = const {},
    required double Function(Transaction transaction) expenseAmount,
    required double Function(Transaction transaction) incomeAmount,
    DateTime? from,
    DateTime? to,
  }) {
    final personById = {
      for (final person in people)
        if (person.id != null) person.id!: person,
    };
    final byPerson = <int, PersonStats>{};
    final byType = <PersonType, PersonTypeStats>{};
    PersonStats statsFor(int personId) =>
        byPerson.putIfAbsent(personId, () => PersonStats(personId));

    final loanReferences = <String>{
      for (final entry in loanEntries) entry.transactionReference.trim(),
    };
    final repaymentReferences = <String>{
      for (final repayment in repayments)
        repayment.repaymentTransactionReference.trim(),
    };
    final transactionByReference = <String, Transaction>{};

    for (final transaction in transactions) {
      final reference = transaction.reference.trim();
      transactionByReference[reference] = transaction;
      final link = links[reference];
      if (link == null || !personById.containsKey(link.personId)) continue;
      final time = DateTime.tryParse(transaction.time ?? '');
      if (!_inRange(time, from, to)) continue;

      final stats = statsFor(link.personId);
      stats.transactionCount++;
      _touch(stats, time);
      if (loanReferences.contains(reference) ||
          repaymentReferences.contains(reference)) {
        continue;
      }
      final owedBySamePerson = (splitsByReference[reference] ?? const [])
          .where(
            (split) => split.isOwedByPerson && split.personId == link.personId,
          )
          .fold<double>(0.0, (sum, split) => sum + split.amount);
      final spent = (expenseAmount(transaction) - owedBySamePerson)
          .clamp(0.0, double.infinity)
          .toDouble();
      stats.spent += spent;
      stats.received += incomeAmount(transaction);

      final type = personById[link.personId]!.type;
      final typeStats = byType.putIfAbsent(type, () => PersonTypeStats(type));
      typeStats.transactionCount++;
      typeStats.spent += spent;
    }

    final appliedByLoan = <String, double>{};
    for (final repayment in repayments) {
      final reference = repayment.loanDebtTransactionReference.trim();
      appliedByLoan[reference] =
          (appliedByLoan[reference] ?? 0) + repayment.appliedAmount;
    }

    for (final entry in loanEntries) {
      final personId = entry.personId;
      if (personId == null || !personById.containsKey(personId)) continue;
      final reference = entry.transactionReference.trim();
      final transaction = transactionByReference[reference];
      final time =
          DateTime.tryParse(transaction?.time ?? '') ?? entry.createdAt;
      if (!_inRange(time, from, to)) continue;

      final original =
          entry.principalAmount?.abs() ?? transaction?.amount.abs() ?? 0.0;
      final applied = appliedByLoan[reference] ?? 0.0;
      final outstanding = entry.status == LoanDebtStatus.active
          ? (original - applied).clamp(0.0, double.infinity).toDouble()
          : 0.0;

      final stats = statsFor(personId);
      stats.loanCount++;
      if (entry.direction == LoanDebtDirection.lent) {
        stats.lent += original;
        stats.lentOutstanding += outstanding;
      } else {
        stats.borrowed += original;
        stats.borrowedOutstanding += outstanding;
      }
    }

    for (final entry in splitsByReference.entries) {
      final transaction = transactionByReference[entry.key.trim()];
      if (transaction == null) continue;
      final time = DateTime.tryParse(transaction.time ?? '');
      if (!_inRange(time, from, to)) continue;
      final linkedPersonId = links[entry.key.trim()]?.personId;
      final counted = <int>{};

      for (final split in entry.value) {
        final personId = split.personId;
        if (!split.isOwedByPerson ||
            personId == null ||
            !personById.containsKey(personId)) {
          continue;
        }
        final stats = statsFor(personId);
        stats.loanCount++;
        stats.lent += split.amount;
        if (split.isPending) stats.lentOutstanding += split.amount;
        if (personId != linkedPersonId && counted.add(personId)) {
          stats.transactionCount++;
          _touch(stats, time);
        }
      }
    }

    return PeopleAnalytics(byPerson: byPerson, byType: byType);
  }

  void _touch(PersonStats stats, DateTime? time) {
    if (time != null &&
        (stats.lastActivity == null || time.isAfter(stats.lastActivity!))) {
      stats.lastActivity = time;
    }
  }

  bool _inRange(DateTime? time, DateTime? from, DateTime? to) {
    if (from == null && to == null) return true;
    if (time == null) return false;
    if (from != null && time.isBefore(from)) return false;
    if (to != null && !time.isBefore(to)) return false;
    return true;
  }
}
