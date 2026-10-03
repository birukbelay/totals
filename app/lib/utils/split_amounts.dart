import 'package:totals/models/transaction.dart';
import 'package:totals/models/transaction_split.dart';

/// Tolerance for comparing currency amounts stored as doubles.
const double splitAmountEpsilon = 0.005;

/// The amount of [transaction] that splits may allocate: its principal.
/// Fees and VAT always stay with the parent.
double splitAllocatableAmount(Transaction transaction) {
  final amount = transaction.amount.abs();
  return amount.isFinite ? amount : 0.0;
}

double splitAllocatedAmount(Iterable<TransactionSplit> splits) {
  return splits.fold<double>(0.0, (sum, split) => sum + split.amount);
}

/// Unallocated principal left on the parent after [splits].
double splitRemainingAmount(
  Transaction transaction,
  Iterable<TransactionSplit> splits,
) {
  final remaining =
      splitAllocatableAmount(transaction) - splitAllocatedAmount(splits);
  return remaining <= splitAmountEpsilon ? 0.0 : remaining;
}

/// Even share of [total] for each of [people] when the user also keeps one
/// share. Rounded down to cents so the user's own share absorbs the rest.
double evenBillShare(double total, int people, {bool includeMe = true}) {
  final shares = people + (includeMe ? 1 : 0);
  if (shares <= 0 || total <= 0) return 0;
  return (total / shares * 100).floorToDouble() / 100;
}

/// One slice of a transaction's expense: a split, or the parent remainder
/// (when [split] is null) that keeps the parent's own categories.
class TransactionAmountPart {
  final TransactionSplit? split;
  final double amount;

  const TransactionAmountPart({required this.split, required this.amount});

  bool get isRemainder => split == null;

  /// Money lent or fronted for someone else rather than the user's spending.
  bool get isOwedByPerson => split?.isOwedByPerson ?? false;

  /// The category this part counts toward, or null to use the parent's.
  int? get categoryId => isOwedByPerson ? null : split?.categoryId;
}

/// Divides [expenseAmount] (the parent's expense after fees, reimbursements
/// and self-transfer rules) into split parts plus the parent remainder.
///
/// Splits are taken at face value. If the expense is smaller than the split
/// total, for example after a reimbursement, splits shrink proportionally so
/// the parts always add up to [expenseAmount].
List<TransactionAmountPart> transactionExpenseParts({
  required double expenseAmount,
  required List<TransactionSplit> splits,
}) {
  if (!expenseAmount.isFinite || expenseAmount <= 0) {
    return const <TransactionAmountPart>[];
  }
  if (splits.isEmpty) {
    return <TransactionAmountPart>[
      TransactionAmountPart(split: null, amount: expenseAmount),
    ];
  }

  final allocated = splitAllocatedAmount(splits);
  final scale = allocated > expenseAmount ? expenseAmount / allocated : 1.0;
  final parts = <TransactionAmountPart>[
    for (final split in splits)
      if (split.amount > 0)
        TransactionAmountPart(split: split, amount: split.amount * scale),
  ];
  final remainder = expenseAmount - allocated * scale;
  if (remainder > splitAmountEpsilon) {
    parts.add(TransactionAmountPart(split: null, amount: remainder));
  }
  return parts;
}

/// The part of [expenseAmount] that counts toward categories matched by
/// [matchesCategory]. With [matchAll], every part that is the user's own
/// spending counts. Loans and bill shares never count: that money is owed
/// back by someone else.
double splitAwareCategoryAmount({
  required double expenseAmount,
  required List<TransactionSplit> splits,
  required Iterable<int> parentCategoryIds,
  required bool Function(int categoryId) matchesCategory,
  bool matchAll = false,
}) {
  final parentMatches = matchAll || parentCategoryIds.any(matchesCategory);
  var total = 0.0;
  for (final part in transactionExpenseParts(
    expenseAmount: expenseAmount,
    splits: splits,
  )) {
    if (part.isOwedByPerson) continue;
    final categoryId = part.categoryId;
    final matches = categoryId == null
        ? parentMatches
        : matchAll || matchesCategory(categoryId);
    if (matches) total += part.amount;
  }
  return total;
}

/// Groups splits by parent reference, dropping splits without one.
Map<String, List<TransactionSplit>> groupSplitsByParent(
  Iterable<TransactionSplit> splits,
) {
  final grouped = <String, List<TransactionSplit>>{};
  for (final split in splits) {
    final reference = split.parentReference.trim();
    if (reference.isEmpty) continue;
    grouped.putIfAbsent(reference, () => <TransactionSplit>[]).add(split);
  }
  return grouped;
}
