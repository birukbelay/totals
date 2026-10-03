import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/loan_debt_entry.dart';
import 'package:totals/models/person.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/models/transaction_split.dart';
import 'package:totals/repositories/category_repository.dart';
import 'package:totals/repositories/loan_debt_repository.dart';
import 'package:totals/repositories/person_repository.dart';
import 'package:totals/repositories/transaction_repository.dart';
import 'package:totals/repositories/transaction_split_repository.dart';
import 'package:totals/services/data_export_import_service.dart';
import 'package:totals/services/data_sync/data_sync_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String databasePath;
  late TransactionRepository transactions;
  late PersonRepository people;
  late TransactionSplitRepository splits;
  late LoanDebtRepository loans;

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
    await DatabaseHelper.instance.database;
    transactions = TransactionRepository();
    people = PersonRepository();
    splits = TransactionSplitRepository();
    loans = LoanDebtRepository();
  });

  tearDown(() async {
    await DatabaseHelper.instance.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);
  });

  Future<Transaction> saveTransaction(String reference, double amount) async {
    final transaction = Transaction(
      amount: amount,
      reference: reference,
      bankId: 1,
      type: 'DEBIT',
      time: '2026-09-20T12:00:00.000',
    );
    await transactions.saveTransaction(
      transaction,
      skipAutoCategorization: true,
    );
    return transaction;
  }

  Future<void> seed() async {
    final category = await CategoryRepository().createCategory(
      name: 'Backup groceries',
      essential: true,
    );
    final dinner = await saveTransaction('FT_DINNER', 900);
    await saveTransaction('FT_LOAN', 500);

    final sara = await people.savePerson(
      Person(
        name: 'Sara Haile',
        type: PersonType.family,
        note: 'Sister',
        createdAt: DateTime(2026, 9),
        updatedAt: DateTime(2026, 9),
      ),
    );
    await people.addIdentifier(
      personId: sara.id!,
      kind: PersonIdentifierKind.bankAccount,
      bankId: 1,
      value: '1000123456789',
    );
    await people.addIdentifier(
      personId: sara.id!,
      kind: PersonIdentifierKind.phone,
      value: '0911223344',
    );
    await people.linkTransaction(
      transactionReference: 'FT_DINNER',
      personId: sara.id!,
    );
    await loans.upsertTransactionPerson(
      transactionReference: 'FT_LOAN',
      personName: 'Sara Haile',
      direction: LoanDebtDirection.lent,
    );

    final now = DateTime(2026, 9, 20);
    await splits.saveSplits(dinner, [
      TransactionSplit(
        parentReference: 'FT_DINNER',
        amount: 300,
        categoryId: category.id,
        createdAt: now,
        updatedAt: now,
      ),
      TransactionSplit(
        parentReference: 'FT_DINNER',
        amount: 300,
        personId: sara.id,
        kind: TransactionSplitKind.billShare,
        status: TransactionSplitStatus.paid,
        note: 'Her share',
        createdAt: now,
        updatedAt: now,
      ),
    ]);
  }

  Future<void> wipe() async {
    await splits.clearAll();
    await loans.clearAll();
    await people.clearAll();
    await transactions.clearAll();
  }

  test('schema 12 round trips people, identifiers, links and splits', () async {
    await seed();

    final service = DataExportImportService();
    final exported = await service.exportAllData();
    final payload = jsonDecode(exported) as Map<String, dynamic>;
    expect(payload['schemaVersion'], 12);
    expect(payload['people'], hasLength(1));
    expect(payload['personIdentifiers'], hasLength(2));
    expect(payload['transactionPeople'], hasLength(2));
    expect(payload['transactionSplits'], hasLength(2));

    await wipe();
    // Shift local IDs so the import has to remap them.
    final other = await people.findOrCreateByName('Someone Else');

    await service.importAllData(exported);

    final restoredPeople = await people.getPeople();
    expect(
      restoredPeople.map((person) => person.name),
      ['Sara Haile', 'Someone Else'],
    );
    final sara = restoredPeople.singleWhere((p) => p.name == 'Sara Haile');
    expect(sara.id, isNot(other.id));
    expect(sara.type, PersonType.family);
    expect(sara.note, 'Sister');

    final identifiers = await people.getIdentifiers(personId: sara.id);
    expect(
      identifiers.map((identifier) => identifier.kind),
      [PersonIdentifierKind.bankAccount, PersonIdentifierKind.phone],
    );
    expect(identifiers.first.bankId, 1);

    final links = await people.getTransactionLinks();
    expect(links['FT_DINNER']?.personId, sara.id);
    expect(links['FT_LOAN']?.personId, sara.id);

    final loan = await loans.getEntryForTransaction('FT_LOAN');
    expect(loan?.personId, sara.id);

    final restoredSplits = await splits.getSplitsForTransaction('FT_DINNER');
    expect(restoredSplits, hasLength(2));
    final share = restoredSplits.singleWhere((split) => split.isOwedByPerson);
    expect(share.personId, sara.id);
    expect(share.status, TransactionSplitStatus.paid);
    expect(share.note, 'Her share');
    final categories = await CategoryRepository().getCategories();
    final groceries = categories
        .singleWhere((category) => category.name == 'Backup groceries');
    expect(
      restoredSplits.singleWhere((split) => !split.isOwedByPerson).categoryId,
      groceries.id,
    );

    // A second import neither duplicates people nor splits.
    await service.importAllData(exported);
    expect(await people.getPeople(), hasLength(2));
    expect(await people.getIdentifiers(), hasLength(2));
    expect(await splits.getSplitsForTransaction('FT_DINNER'), hasLength(2));
  });

  test('importing without people keeps only category splits', () async {
    await seed();
    final service = DataExportImportService();
    final exported = await service.exportAllData();
    await wipe();

    await service.importAllData(
      exported,
      options: const DataImportOptions(includePeople: false),
    );

    // Loans still need a person, so one is recreated from the loan's name.
    expect(
      (await people.getPeople()).map((person) => person.type),
      [PersonType.friend],
    );
    expect(await people.getIdentifiers(), isEmpty);
    final restoredSplits = await splits.getSplitsForTransaction('FT_DINNER');
    expect(restoredSplits, hasLength(1));
    expect(restoredSplits.single.isOwedByPerson, isFalse);
  });

  test('exporting without people drops owed splits and person IDs', () async {
    await seed();
    final exported = await DataExportImportService().exportAllData(
      options: const DataExportOptions(includePeople: false),
    );
    final payload = jsonDecode(exported) as Map<String, dynamic>;
    expect(payload['people'], isEmpty);
    expect(payload['personIdentifiers'], isEmpty);
    expect(payload['transactionPeople'], isEmpty);
    final exportedSplits = payload['transactionSplits'] as List<dynamic>;
    expect(exportedSplits, hasLength(1));
    expect((exportedSplits.single as Map)['kind'], 'expense');
  });

  test('schema 11 backups without people still import', () async {
    await DataExportImportService().importAllData(
      jsonEncode({
        'schemaVersion': 11,
        'transactions': [
          {
            'amount': 250,
            'reference': 'FT_OLD',
            'bankId': 1,
            'type': 'DEBIT',
          },
        ],
        'loanDebtEntries': [
          {
            'transactionReference': 'FT_OLD',
            'personName': 'Abebe',
            'direction': 'lent',
            'status': 'active',
          },
        ],
      }),
    );

    final loan = await loans.getEntryForTransaction('FT_OLD');
    final abebe = await people.findByName('Abebe');
    expect(abebe, isNotNull);
    expect(loan?.personId, abebe!.id);
    expect(await splits.getSplitsForTransaction('FT_OLD'), isEmpty);
  });

  test('schema-less payloads with people sections resolve to schema 12', () {
    final normalized = DataExportImportService.normalizeImportPayload(
      jsonEncode({
        'transactions': const [],
        'transaction_splits': const [],
      }),
    );
    expect(normalized['schemaVersion'], 12);
  });
}
