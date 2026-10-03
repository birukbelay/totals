import 'package:flutter_test/flutter_test.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/models/transaction_split.dart';
import 'package:totals/utils/split_amounts.dart';

final DateTime _now = DateTime(2026, 9, 1);

TransactionSplit _split(
  double amount, {
  int? categoryId,
  int? personId,
  TransactionSplitKind kind = TransactionSplitKind.expense,
  String parent = 'parent',
}) {
  return TransactionSplit(
    parentReference: parent,
    amount: amount,
    categoryId: categoryId,
    personId: personId,
    kind: kind,
    createdAt: _now,
    updatedAt: _now,
  );
}

void main() {
  final transaction = Transaction(
    amount: 1000,
    reference: 'parent',
    serviceCharge: 5,
    vat: 0.75,
    type: 'DEBIT',
  );

  test('allocatable amount is the principal, not fees', () {
    expect(splitAllocatableAmount(transaction), 1000);
    expect(
      splitRemainingAmount(transaction, [_split(400), _split(250)]),
      350,
    );
    expect(splitRemainingAmount(transaction, [_split(1000)]), 0);
  });

  test('parts are the splits plus a remainder on the parent', () {
    final parts = transactionExpenseParts(
      expenseAmount: 1000,
      splits: [_split(300, categoryId: 1), _split(200, personId: 7)],
    );

    expect(parts.map((part) => part.amount), [300, 200, 500]);
    expect(parts.last.isRemainder, isTrue);
    expect(parts.first.categoryId, 1);
    expect(parts.last.categoryId, isNull);
  });

  test('without splits the whole expense is one remainder part', () {
    final parts = transactionExpenseParts(expenseAmount: 80, splits: const []);

    expect(parts, hasLength(1));
    expect(parts.single.isRemainder, isTrue);
    expect(parts.single.amount, 80);
    expect(
      transactionExpenseParts(expenseAmount: 0, splits: [_split(10)]),
      isEmpty,
    );
  });

  test('splits shrink proportionally when the expense is smaller', () {
    // A 1000 payment reimbursed down to 500 with 400 + 400 of splits.
    final parts = transactionExpenseParts(
      expenseAmount: 500,
      splits: [_split(400, categoryId: 1), _split(400, categoryId: 2)],
    );

    expect(parts.map((part) => part.amount), [250, 250]);
  });

  test('category amount follows the split categories', () {
    final splits = [
      _split(300, categoryId: 1),
      _split(200, categoryId: 2),
      _split(
        250,
        personId: 9,
        kind: TransactionSplitKind.loan,
      ),
    ];

    double amountFor(Set<int> ids, {bool matchAll = false}) {
      return splitAwareCategoryAmount(
        expenseAmount: 1000,
        splits: splits,
        parentCategoryIds: const [3],
        matchesCategory: ids.contains,
        matchAll: matchAll,
      );
    }

    expect(amountFor({1}), 300);
    expect(amountFor({2}), 200);
    // The 250 remainder keeps the parent's category.
    expect(amountFor({3}), 250);
    expect(amountFor({1, 3}), 550);
    // Loans never count, even for an all-expenses budget.
    expect(amountFor(const {}, matchAll: true), 750);
  });

  test('owed parts have no category', () {
    final part = TransactionAmountPart(
      split: _split(
        50,
        categoryId: 4,
        personId: 1,
        kind: TransactionSplitKind.billShare,
      ),
      amount: 50,
    );

    expect(part.isOwedByPerson, isTrue);
    expect(part.categoryId, isNull);
  });

  test('groups splits by parent reference', () {
    final grouped = groupSplitsByParent([
      _split(1, parent: ' a '),
      _split(2, parent: 'b'),
      _split(3, parent: 'a'),
      _split(4, parent: ''),
    ]);

    expect(grouped.keys, unorderedEquals(<String>['a', 'b']));
    expect(grouped['a']!.map((split) => split.amount), [1, 3]);
  });

  test('storage values round-trip', () {
    for (final kind in TransactionSplitKind.values) {
      expect(transactionSplitKindFromStorage(kind.storageValue), kind);
    }
    expect(transactionSplitKindFromStorage('BILL_SHARE'),
        TransactionSplitKind.billShare);
    expect(transactionSplitKindFromStorage(null), TransactionSplitKind.expense);
    expect(
        transactionSplitStatusFromStorage('paid'), TransactionSplitStatus.paid);
    expect(transactionSplitStatusFromStorage('nope'), isNull);

    final split = TransactionSplit.fromDb({
      'id': 3,
      'parentReference': 'p',
      'amount': 12.5,
      'kind': 'loan',
      'personId': 2,
      'createdAt': _now.toIso8601String(),
    });
    expect(split.status, TransactionSplitStatus.pending);
    expect(split.isPending, isTrue);
    expect(TransactionSplit.fromJson(split.toJson()).amount, 12.5);
    expect(
      TransactionSplit.fromDb({...split.toDb(), 'kind': 'expense'}).status,
      isNull,
    );
  });

  test('even bill shares round down to cents', () {
    expect(evenBillShare(1000, 3), 250);
    expect(evenBillShare(1000, 3, includeMe: false), 333.33);
    expect(evenBillShare(100, 2), 33.33);
    expect(evenBillShare(100, 0, includeMe: false), 0);
    expect(evenBillShare(-5, 2), 0);
  });
}
