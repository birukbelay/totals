import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/transaction_source_sms.dart';
import 'package:totals/repositories/account_repository.dart';
import 'package:totals/repositories/transaction_repository.dart';
import 'package:totals/repositories/transaction_source_sms_repository.dart';
import 'package:totals/services/auto_account_service.dart';
import 'package:totals/services/data_sync/data_sync_settings_service.dart';

const _cbeBankId = 1;
const _telebirrBankId = 6;

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
    await db.insert('banks', <String, Object?>{
      'id': _telebirrBankId,
      'name': 'Telebirr',
      'shortName': 'Telebirr',
      'codes': '["127"]',
      'image': 'assets/images/telebirr.png',
      'maskPattern': 0,
      'uniformMasking': 0,
      'simBased': 1,
      'colors': '["#0b5ed7", "#0a58ca"]',
    });
  });

  tearDown(() async {
    if (db.isOpen) await DatabaseHelper.instance.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);
  });

  Future<void> insertUnlabeled(
    String reference,
    DateTime time, {
    int bankId = _cbeBankId,
    String? accountNumber,
    String? currentBalance,
    String? body,
  }) async {
    await db.insert('transactions', {
      'amount': 100.0,
      'reference': reference,
      'time': time.toIso8601String(),
      'type': 'DEBIT',
      'bankId': bankId,
      'accountNumber': accountNumber,
      'currentBalance': currentBalance,
      'isUnlabeled': 1,
      'year': time.year,
      'month': time.month,
      'day': time.day,
    });
    if (body != null) {
      await TransactionSourceSmsRepository().upsert(
        TransactionSourceSms(transactionReference: reference, body: body),
      );
    }
  }

  Future<void> insertCbeMessages() async {
    final day = DateTime(2026, 9, 1, 9);
    await insertUnlabeled(
      'FT_MINE_1',
      day,
      accountNumber: '1*****6789',
      currentBalance: '5,000.00',
      body: 'Dear Abebe your Account 1*****6789 has been debited with '
          'ETB 100.00. Your Current Balance is ETB 5,000.00.',
    );
    await insertUnlabeled(
      'FT_MINE_2',
      day.add(const Duration(hours: 2)),
      accountNumber: '1*****6789',
      currentBalance: '4,900.00',
      body: 'Dear Abebe your Account 1*****6789 has been debited with '
          'ETB 100.00. Your Current Balance is ETB 4,900.00.',
    );
    await insertUnlabeled(
      'FT_SECOND',
      day.add(const Duration(hours: 3)),
      accountNumber: '1*****4321',
      currentBalance: '700.00',
      body: 'Dear Abebe your Account 1*****4321 has been debited with '
          'ETB 100.00. Your Current Balance is ETB 700.00.',
    );
  }

  test('adds the accounts found in saved messages and labels them', () async {
    await insertCbeMessages();

    final result = await AutoAccountService().run();

    expect(result.accountsAdded, 2);
    expect(result.transactionsLabeled, 3);
    final accounts = (await AccountRepository().getAccounts())
        .where((account) => account.bank == _cbeBankId)
        .toList();
    expect(
      {for (final account in accounts) account.accountNumber: account.balance},
      {'1*****6789': 4900, '1*****4321': 700},
    );
    expect(
      accounts.map((account) => account.accountHolderName).toSet(),
      {'Abebe'},
    );
    expect(await TransactionRepository().getUnlabeledTransactions(), isEmpty);
    final owners = {
      for (final transaction in await TransactionRepository()
          .getTransactions(includeUnlabeled: false))
        transaction.reference: transaction.ownerAccountNumber,
    };
    expect(owners, {
      'FT_MINE_1': '1*****6789',
      'FT_MINE_2': '1*****6789',
      'FT_SECOND': '1*****4321',
    });

    // Running again adds nothing.
    final again = await AutoAccountService().run();
    expect(again.accountsAdded, 0);
    expect(
      (await AccountRepository().getAccounts())
          .where((account) => account.bank == _cbeBankId),
      hasLength(2),
    );
  });

  test('a deleted account is not added again', () async {
    await insertCbeMessages();
    await AutoAccountService().run();

    await AccountRepository().deleteAccount('1*****4321', _cbeBankId);
    await insertUnlabeled(
      'FT_SECOND_LATER',
      DateTime(2026, 9, 2, 9),
      accountNumber: '1*****4321',
      body: 'Dear Abebe your Account 1*****4321 has been debited with '
          'ETB 100.00.',
    );

    final result = await AutoAccountService().run();

    expect(result.accountsAdded, 0);
    expect(
      (await AccountRepository().getAccounts())
          .where((account) => account.bank == _cbeBankId)
          .map((account) => account.accountNumber),
      ['1*****6789'],
    );
  });

  test('a wallet gets the number its messages call "your account"', () async {
    await insertUnlabeled(
      'TB_1',
      DateTime(2026, 9, 1, 9),
      bankId: _telebirrBankId,
      accountNumber: '251911111111',
      currentBalance: '250.00',
      body: 'Dear Abebe, You have transferred ETB 100.00 to Kebede '
          '(251911111111) from your telebirr account 251912345678. Your '
          'current balance is ETB 250.00.',
    );

    final result = await AutoAccountService().run();

    expect(result.accountsAdded, 1);
    final wallet = (await AccountRepository().getAccounts())
        .singleWhere((account) => account.bank == _telebirrBankId);
    expect(wallet.accountNumber, '0912345678');
    expect(wallet.accountHolderName, 'Abebe');
    expect(wallet.balance, 250);
    expect(await TransactionRepository().getUnlabeledTransactions(), isEmpty);
  });

  test('a wallet whose messages name no number gets a placeholder', () async {
    await insertUnlabeled(
      'TB_1',
      DateTime(2026, 9, 1, 9),
      bankId: _telebirrBankId,
      body: 'Dear Customer, you have paid ETB 100.00 for airtime.',
    );

    await AutoAccountService().run();

    final wallet = (await AccountRepository().getAccounts())
        .singleWhere((account) => account.bank == _telebirrBankId);
    expect(wallet.accountNumber, 'TELEBIRR');
    expect(wallet.accountHolderName, 'Telebirr');
    expect(await TransactionRepository().getUnlabeledTransactions(), isEmpty);
  });
}
