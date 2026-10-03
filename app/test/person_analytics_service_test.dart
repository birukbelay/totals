import 'package:flutter_test/flutter_test.dart';
import 'package:totals/models/loan_debt_entry.dart';
import 'package:totals/models/person.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/services/person_analytics_service.dart';

final DateTime _now = DateTime(2026, 9, 1);

Person _person(int id, String name, PersonType type) =>
    Person(id: id, name: name, type: type, createdAt: _now, updatedAt: _now);

Transaction _transaction(
  String reference,
  double amount,
  String type,
  String time,
) {
  return Transaction(
    amount: amount,
    reference: reference,
    time: time,
    bankId: 1,
    type: type,
  );
}

TransactionPersonLink _link(String reference, int personId) {
  return TransactionPersonLink(
    transactionReference: reference,
    personId: personId,
    source: TransactionPersonSource.manual,
    createdAt: _now,
  );
}

LoanDebtEntry _loan(
  String reference,
  int personId,
  LoanDebtDirection direction, {
  double? principal,
  LoanDebtStatus status = LoanDebtStatus.active,
}) {
  return LoanDebtEntry(
    transactionReference: reference,
    personName: 'p$personId',
    personId: personId,
    direction: direction,
    status: status,
    principalAmount: principal,
    createdAt: _now,
    updatedAt: _now,
  );
}

LoanDebtRepayment _repayment(String repayment, String loan, double amount) {
  return LoanDebtRepayment(
    repaymentTransactionReference: repayment,
    loanDebtTransactionReference: loan,
    appliedAmount: amount,
    createdAt: _now,
    updatedAt: _now,
  );
}

double _expense(Transaction transaction) =>
    transaction.type == 'DEBIT' ? transaction.amount : 0;

double _income(Transaction transaction) =>
    transaction.type == 'CREDIT' ? transaction.amount : 0;

void main() {
  const service = PersonAnalyticsService();
  final people = [
    _person(1, 'Sara', PersonType.friend),
    _person(2, 'Abebe', PersonType.friend),
    _person(3, 'Shoa', PersonType.shop),
    _person(4, 'Kaldis', PersonType.restaurant),
  ];
  final transactions = [
    _transaction('shop-1', 400, 'DEBIT', '2026-08-03T10:00:00.000'),
    _transaction('shop-2', 600, 'DEBIT', '2026-09-03T10:00:00.000'),
    _transaction('cafe-1', 150, 'DEBIT', '2026-09-04T10:00:00.000'),
    _transaction('sara-gift', 200, 'CREDIT', '2026-09-05T10:00:00.000'),
    _transaction('sara-loan', 1000, 'DEBIT', '2026-09-06T10:00:00.000'),
    _transaction('sara-back', 300, 'CREDIT', '2026-09-10T10:00:00.000'),
    _transaction('abebe-loan', 2000, 'DEBIT', '2026-08-15T10:00:00.000'),
    _transaction('abebe-old', 500, 'DEBIT', '2026-07-15T10:00:00.000'),
    _transaction('borrow', 700, 'CREDIT', '2026-09-08T10:00:00.000'),
    _transaction('unlinked', 9999, 'DEBIT', '2026-09-08T10:00:00.000'),
  ];
  final links = {
    for (final link in [
      _link('shop-1', 3),
      _link('shop-2', 3),
      _link('cafe-1', 4),
      _link('sara-gift', 1),
      _link('sara-loan', 1),
      _link('sara-back', 1),
      _link('abebe-loan', 2),
      _link('abebe-old', 2),
      _link('borrow', 2),
      // A link to a deleted person is ignored.
      _link('unlinked', 99),
    ])
      link.transactionReference: link,
  };
  final loans = [
    _loan('sara-loan', 1, LoanDebtDirection.lent),
    _loan('abebe-loan', 2, LoanDebtDirection.lent, principal: 2000),
    _loan(
      'abebe-old',
      2,
      LoanDebtDirection.lent,
      status: LoanDebtStatus.settled,
    ),
    _loan('borrow', 2, LoanDebtDirection.borrowed, principal: 700),
  ];
  final repayments = [_repayment('sara-back', 'sara-loan', 300)];

  PeopleAnalytics build({DateTime? from, DateTime? to}) {
    return service.build(
      people: people,
      transactions: transactions,
      links: links,
      loanEntries: loans,
      repayments: repayments,
      expenseAmount: _expense,
      incomeAmount: _income,
      from: from,
      to: to,
    );
  }

  test('separates spending and income from loans and repayments', () {
    final analytics = build();

    final sara = analytics.statsFor(1);
    expect(sara.spent, 0);
    expect(sara.received, 200);
    expect(sara.transactionCount, 3);
    expect(sara.lent, 1000);
    expect(sara.lentOutstanding, 700);
    expect(sara.lastActivity, DateTime.parse('2026-09-10T10:00:00.000'));

    final abebe = analytics.statsFor(2);
    expect(abebe.spent, 0);
    expect(abebe.lent, 2500);
    expect(abebe.lentOutstanding, 2000, reason: 'settled loans are not owed');
    expect(abebe.borrowed, 700);
    expect(abebe.borrowedOutstanding, 700);
    expect(abebe.loanCount, 3);

    expect(analytics.statsFor(3).spent, 1000);
    expect(analytics.statsFor(4).spent, 150);
    expect(analytics.byPerson.containsKey(99), isFalse);
  });

  test('ranks where the user spends and who borrows most', () {
    final analytics = build();

    expect(analytics.topSpending().map((stats) => stats.personId), [3, 4]);
    expect(analytics.topBorrowers().map((stats) => stats.personId), [2, 1]);
    expect(analytics.topOutstanding().map((stats) => stats.personId), [2, 1]);
    // Sara and Abebe tie on three transactions each.
    expect(analytics.topByCount(limit: 2).map((stats) => stats.personId),
        unorderedEquals(<int>[1, 2]));
  });

  test('groups spending by person type', () {
    final byType = build().spendingByType();

    expect(byType.map((stats) => stats.type),
        [PersonType.shop, PersonType.restaurant]);
    expect(byType.first.spent, 1000);
    expect(byType.first.transactionCount, 2);
  });

  test('limits activity to the requested date range', () {
    final analytics = build(
      from: DateTime(2026, 9, 1),
      to: DateTime(2026, 10, 1),
    );

    expect(analytics.statsFor(3).spent, 600);
    expect(analytics.statsFor(3).transactionCount, 1);
    final abebe = analytics.statsFor(2);
    expect(abebe.lent, 0);
    expect(abebe.borrowed, 700);
    expect(analytics.statsFor(1).lentOutstanding, 700);
  });

  test('unknown people get empty stats', () {
    final stats = build().statsFor(42);
    expect(stats.volume, 0);
    expect(stats.lastActivity, isNull);
  });
}
