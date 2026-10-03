import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/budget.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/models/transaction_split.dart';
import 'package:totals/repositories/person_repository.dart';
import 'package:totals/repositories/transaction_split_repository.dart';
import 'package:totals/services/budget_service.dart';
import 'package:totals/services/data_sync/data_sync_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late String databasePath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DataSyncSettingsService.cachedEnabled = false;
    await DatabaseHelper.instance.close();
    databasePath = '${await databaseFactoryFfi.getDatabasesPath()}/totals.db';
    await databaseFactoryFfi.deleteDatabase(databasePath);
    db = await DatabaseHelper.instance.database;
  });

  tearDown(() async {
    if (db.isOpen) await DatabaseHelper.instance.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);
  });

  test('budgets count split parts by category and skip loans', () async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month);
    final end =
        DateTime(now.year, now.month + 1).subtract(const Duration(seconds: 1));
    final categoryRows = await db.query(
      'categories',
      columns: const ['id'],
      where: 'flow = ?',
      whereArgs: const ['expense'],
      orderBy: 'id ASC',
      limit: 2,
    );
    final groceries = categoryRows[0]['id']! as int;
    final dining = categoryRows[1]['id']! as int;

    Future<void> insertDebit(String reference, double amount) async {
      await db.insert('transactions', {
        'amount': amount,
        'reference': reference,
        'time': DateTime(now.year, now.month, now.day, 12).toIso8601String(),
        'type': 'DEBIT',
        'categoryId': groceries,
        'categoryIds': '[$groceries]',
        'year': now.year,
        'month': now.month,
        'day': now.day,
      });
    }

    await insertDebit('SPLIT', 1000);
    await insertDebit('PLAIN', 200);

    final friend = await PersonRepository().findOrCreateByName('Abebe');
    final splitTime = DateTime(now.year, now.month, now.day);
    TransactionSplit split(
      double amount, {
      int? categoryId,
      int? personId,
      TransactionSplitKind kind = TransactionSplitKind.expense,
    }) {
      return TransactionSplit(
        parentReference: 'SPLIT',
        amount: amount,
        categoryId: categoryId,
        personId: personId,
        kind: kind,
        createdAt: splitTime,
        updatedAt: splitTime,
      );
    }

    // 1000 = 300 dining + 250 loan + 150 bill share + 300 left on groceries.
    await TransactionSplitRepository().saveSplits(
      Transaction(amount: 1000, reference: 'SPLIT', type: 'DEBIT'),
      [
        split(300, categoryId: dining),
        split(250, personId: friend.id, kind: TransactionSplitKind.loan),
        split(150, personId: friend.id, kind: TransactionSplitKind.billShare),
      ],
    );

    final service = BudgetService();
    expect(
      await service.calculateSpending(
        startDate: start,
        endDate: end,
        categoryId: groceries,
      ),
      closeTo(500, 0.001),
    );
    expect(
      await service.calculateSpending(
        startDate: start,
        endDate: end,
        categoryIds: [dining],
      ),
      closeTo(300, 0.001),
    );
    // No categories means every expense, still without the owed parts.
    expect(
      await service.calculateSpending(startDate: start, endDate: end),
      closeTo(800, 0.001),
    );

    final status = await service.getBudgetStatus(
      Budget(
        name: 'Dining',
        type: 'category',
        amount: 600,
        categoryId: dining,
        categoryIds: [dining],
        startDate: start,
        endDate: end,
        alertThreshold: 80,
        timeFrame: 'monthly',
        createdAt: now,
      ),
    );
    expect(status.spent, closeTo(300, 0.001));
    expect(status.percentageUsed, closeTo(50, 0.001));
  });
}
