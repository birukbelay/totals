import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/account.dart';
import 'package:totals/models/transaction_source_sms.dart';
import 'package:totals/repositories/account_repository.dart';
import 'package:totals/repositories/transaction_repository.dart';
import 'package:totals/repositories/transaction_source_sms_repository.dart';
import 'package:totals/services/budget_service.dart';
import 'package:totals/services/data_sync/data_sync_settings_service.dart';
import 'package:totals/services/unlabeled_account_service.dart';

const _cbeBankId = 1;
const _accountNumber = '1000123456789';

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

    // Keeps BankConfigService on its local path; no network is needed.
    await db.insert('banks', <String, Object?>{
      'id': _cbeBankId,
      'name': 'Commercial Bank Of Ethiopia',
      'shortName': 'CBE',
      'codes': '["CBE"]',
      'image': 'assets/images/cbe.png',
      'maskPattern': 3,
      'uniformMasking': 1,
      'simBased': 0,
      'colors': '["#1b0b2e", "#3a0f5c"]',
    });
  });

  tearDown(() async {
    if (db.isOpen) await DatabaseHelper.instance.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);
  });

  Future<void> insertUnlabeled(
    String reference,
    double amount,
    DateTime time, {
    required String accountNumber,
    String type = 'DEBIT',
    String? currentBalance,
  }) async {
    await db.insert('transactions', {
      'amount': amount,
      'reference': reference,
      'time': time.toIso8601String(),
      'type': type,
      'bankId': _cbeBankId,
      'accountNumber': accountNumber,
      'currentBalance': currentBalance,
      'isUnlabeled': 1,
      'year': time.year,
      'month': time.month,
      'day': time.day,
    });
  }

  test('unlabeled rows stay out of totals until their account is labeled',
      () async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month);
    final end =
        DateTime(now.year, now.month + 1).subtract(const Duration(seconds: 1));
    final day = DateTime(now.year, now.month, 1, 9);

    await insertUnlabeled(
      'FT_MINE_1',
      300,
      day,
      accountNumber: '1*****6789',
      currentBalance: '5,000.00',
    );
    await insertUnlabeled(
      'FT_MINE_2',
      200,
      day.add(const Duration(hours: 2)),
      accountNumber: '1*****6789',
      currentBalance: '4,800.00',
    );
    await insertUnlabeled(
      'FT_OTHER',
      50,
      day.add(const Duration(hours: 3)),
      accountNumber: '1*****4321',
    );
    await TransactionSourceSmsRepository().upsert(
      const TransactionSourceSms(
        transactionReference: 'FT_MINE_1',
        body: 'Dear Abebe, your Account 1*****6789 has been debited with '
            'ETB 300.00. Your Current Balance is ETB 5,000.00.',
      ),
    );

    final transactions = TransactionRepository();
    expect(
      await transactions.getTransactions(includeUnlabeled: false),
      isEmpty,
    );
    expect(
      await BudgetService().calculateSpending(startDate: start, endDate: end),
      0,
    );

    final service = UnlabeledAccountService();
    final groups = await service.loadGroups();
    expect(groups.map((group) => group.count), [2, 1]);
    expect(groups.first.holderNameSuggestion, 'Abebe');
    expect(groups.first.latestBalance, 4800);

    await AccountRepository().saveAccount(
      Account(
        accountNumber: _accountNumber,
        bank: _cbeBankId,
        balance: 0,
        accountHolderName: 'Abebe',
      ),
    );
    final result = await service.labelSavedTransactions(
      bankId: _cbeBankId,
      accountNumber: _accountNumber,
    );
    expect(result.labeled, 2);
    expect(result.balance, 4800);

    final labeled = await transactions.getTransactions(includeUnlabeled: false);
    expect(
      labeled.map((transaction) => transaction.reference).toSet(),
      {'FT_MINE_1', 'FT_MINE_2'},
    );
    for (final transaction in labeled) {
      expect(transaction.isUnlabeled, isFalse);
      expect(transaction.ownerAccountNumber, _accountNumber);
    }
    expect(
      (await transactions.getUnlabeledTransactions())
          .map((transaction) => transaction.reference),
      ['FT_OTHER'],
    );
    expect(
      await BudgetService().calculateSpending(startDate: start, endDate: end),
      closeTo(500, 0.001),
    );

    final account = (await AccountRepository().getAccounts()).singleWhere(
      (account) => account.accountNumber == _accountNumber,
    );
    expect(account.balance, 4800);

    // Labeling again finds nothing new.
    final again = await service.labelSavedTransactions(
      bankId: _cbeBankId,
      accountNumber: _accountNumber,
    );
    expect(again.labeled, 0);
  });

  test('labeling keeps the balance of an account that already has one',
      () async {
    await insertUnlabeled(
      'FT_1',
      100,
      DateTime(2026, 9, 1, 9),
      accountNumber: _accountNumber,
      currentBalance: '900.00',
    );
    await AccountRepository().saveAccount(
      Account(
        accountNumber: _accountNumber,
        bank: _cbeBankId,
        balance: 1234,
        accountHolderName: 'Abebe',
      ),
    );

    final result = await UnlabeledAccountService().labelSavedTransactions(
      bankId: _cbeBankId,
      accountNumber: _accountNumber,
    );
    expect(result.labeled, 1);
    expect(result.balance, isNull);
    final account = (await AccountRepository().getAccounts())
        .singleWhere((account) => account.bank == _cbeBankId);
    expect(account.balance, 1234);
  });
}
