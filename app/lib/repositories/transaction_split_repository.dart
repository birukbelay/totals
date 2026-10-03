import 'package:totals/database/database_helper.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/models/transaction_split.dart';
import 'package:totals/utils/split_amounts.dart';

class TransactionSplitRepository {
  Future<List<TransactionSplit>> getSplitsForTransaction(
    String parentReference,
  ) async {
    final reference = parentReference.trim();
    if (reference.isEmpty) return const <TransactionSplit>[];
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'transaction_splits',
      where: 'parentReference = ?',
      whereArgs: [reference],
      orderBy: 'id ASC',
    );
    return rows.map(TransactionSplit.fromDb).toList(growable: false);
  }

  /// Every split, grouped by parent transaction reference.
  Future<Map<String, List<TransactionSplit>>> getAllSplits() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'transaction_splits',
      orderBy: 'parentReference ASC, id ASC',
    );
    return groupSplitsByParent(rows.map(TransactionSplit.fromDb));
  }

  Future<List<TransactionSplit>> getSplitsForPerson(int personId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'transaction_splits',
      where: 'personId = ?',
      whereArgs: [personId],
      orderBy: 'createdAt DESC, id DESC',
    );
    return rows.map(TransactionSplit.fromDb).toList(growable: false);
  }

  /// Replaces all splits of [parent] with [splits] in one DB transaction.
  ///
  /// Throws [ArgumentError] when a split has no positive amount, a loan or
  /// bill share has no person, or the splits add up to more than the
  /// parent's principal. An empty [splits] list removes every split.
  Future<List<TransactionSplit>> saveSplits(
    Transaction parent,
    List<TransactionSplit> splits,
  ) async {
    final reference = parent.reference.trim();
    if (reference.isEmpty) {
      throw ArgumentError.value(
        parent.reference,
        'parent',
        'Transaction reference is required',
      );
    }
    for (final split in splits) {
      if (!split.amount.isFinite || split.amount <= 0) {
        throw ArgumentError.value(
          split.amount,
          'splits',
          'Split amounts must be positive',
        );
      }
      if (split.isOwedByPerson && split.personId == null) {
        throw ArgumentError.value(
          split.kind,
          'splits',
          'Loans and bill shares need a person',
        );
      }
    }
    final allocated = splitAllocatedAmount(splits);
    final available = splitAllocatableAmount(parent);
    if (allocated > available + splitAmountEpsilon) {
      throw ArgumentError.value(
        allocated,
        'splits',
        'Splits exceed the transaction amount of $available',
      );
    }

    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now();
    return db.transaction((txn) async {
      final existingRows = await txn.query(
        'transaction_splits',
        where: 'parentReference = ?',
        whereArgs: [reference],
      );
      final existingById = {
        for (final row in existingRows.map(TransactionSplit.fromDb))
          if (row.id != null) row.id!: row,
      };
      await txn.delete(
        'transaction_splits',
        where: 'parentReference = ?',
        whereArgs: [reference],
      );

      final saved = <TransactionSplit>[];
      for (final split in splits) {
        final previous = split.id == null ? null : existingById[split.id];
        final row = TransactionSplit(
          id: previous?.id,
          parentReference: reference,
          amount: split.amount,
          categoryId: split.isOwedByPerson ? null : split.categoryId,
          personId: split.personId,
          kind: split.kind,
          status: split.isOwedByPerson
              ? (split.status ?? TransactionSplitStatus.pending)
              : null,
          note: _normalizedNote(split.note),
          createdAt: previous?.createdAt ?? now,
          updatedAt: now,
        );
        final id = await txn.insert('transaction_splits', row.toDb());
        saved.add(row.copyWith(id: id));
      }
      return saved;
    });
  }

  Future<void> setSplitStatus(
      int splitId, TransactionSplitStatus status) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'transaction_splits',
      {
        'status': status.storageValue,
        'updatedAt': DateTime.now().toIso8601String(),
      },
      where: "id = ? AND kind <> 'expense'",
      whereArgs: [splitId],
    );
  }

  Future<void> deleteSplitsForTransaction(String parentReference) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'transaction_splits',
      where: 'parentReference = ?',
      whereArgs: [parentReference.trim()],
    );
  }

  /// Removes loan and bill-share splits, leaving category splits in place.
  Future<void> clearOwedSplits() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('transaction_splits', where: "kind <> 'expense'");
  }

  Future<void> clearAll() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('transaction_splits');
  }

  String? _normalizedNote(String? note) {
    final trimmed = note?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
