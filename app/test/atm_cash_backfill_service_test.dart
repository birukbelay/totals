import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:totals/constants/cash_constants.dart';
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/transaction_source_sms.dart';
import 'package:totals/repositories/transaction_repository.dart';
import 'package:totals/repositories/transaction_source_sms_repository.dart';
import 'package:totals/services/atm_cash_backfill_service.dart';
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

  Future<void> insertDebit(
    String reference,
    double amount,
    DateTime time, {
    double? serviceCharge,
    String? receiver,
  }) async {
    await db.insert('transactions', {
      'amount': amount,
      'reference': reference,
      'time': time.toIso8601String(),
      'type': 'DEBIT',
      'bankId': 1,
      'serviceCharge': serviceCharge,
      'receiver': receiver,
      'year': time.year,
      'month': time.month,
      'day': time.day,
    });
  }

  test('backfill creates cash legs for past ATM withdrawals once', () async {
    final day = DateTime(2026, 2, 10, 9);
    await insertDebit('FT_ATM', 1000, day, serviceCharge: 10);
    await insertDebit('FT_PAY', 400, day.add(const Duration(hours: 1)));
    await insertDebit(
      'FT_OLD',
      200,
      day.add(const Duration(days: 1)),
      receiver: 'ATM Bole',
    );
    await TransactionSourceSmsRepository().upsertAll(const [
      TransactionSourceSms(
        transactionReference: 'FT_ATM',
        body: 'ETB 1,000.00 cash withdrawal at ATM BOLE-02 was made from '
            'your account.',
      ),
      TransactionSourceSms(
        transactionReference: 'FT_PAY',
        body: 'Your account has been debited with ETB 400.00 for a transfer.',
      ),
    ]);

    expect(await AtmCashBackfillService.isEnabledForActiveProfile(), isFalse);
    final service = AtmCashBackfillService();
    expect(await service.backfill(), 2);
    expect(await AtmCashBackfillService.isEnabledForActiveProfile(), isTrue);

    final legs = await db.query(
      'transactions',
      where: 'bankId = ?',
      whereArgs: [CashConstants.bankId],
      orderBy: 'time ASC',
    );
    expect(
      legs.map((row) => row['reference']),
      ['cash_atm_FT_ATM', 'cash_atm_FT_OLD'],
    );
    expect(legs.map((row) => row['type']), ['CREDIT', 'CREDIT']);
    expect(legs.map((row) => row['currentBalance']), ['1000.00', '1200.00']);
    expect(legs.first['transactionLink'], 'FT_ATM');

    expect(
      await TransactionRepository().getAtmLinkedWithdrawalReferences(),
      {'FT_ATM', 'FT_OLD'},
    );

    // Running it again finds nothing new.
    expect(await service.backfill(), 0);
  });

  test('budgets count only the fee of an ATM withdrawal', () async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month);
    final end =
        DateTime(now.year, now.month + 1).subtract(const Duration(seconds: 1));
    final time = DateTime(now.year, now.month, now.day, 12);
    await insertDebit('FT_ATM', 1000, time, serviceCharge: 10);
    await insertDebit('FT_PAY', 400, time);
    await TransactionSourceSmsRepository().upsert(
      const TransactionSourceSms(
        transactionReference: 'FT_ATM',
        body: 'ETB 1,000.00 cash withdrawal at ATM BOLE-02 was made from '
            'your account.',
      ),
    );

    final budgets = BudgetService();
    expect(
      await budgets.calculateSpending(startDate: start, endDate: end),
      closeTo(1410, 0.001),
    );

    await AtmCashBackfillService().backfill();
    expect(
      await budgets.calculateSpending(startDate: start, endDate: end),
      closeTo(410, 0.001),
    );
  });
}
