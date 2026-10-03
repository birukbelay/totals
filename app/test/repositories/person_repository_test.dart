import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/loan_debt_entry.dart';
import 'package:totals/models/person.dart';
import 'package:totals/repositories/loan_debt_repository.dart';
import 'package:totals/repositories/person_repository.dart';
import 'package:totals/services/data_sync/data_sync_settings_service.dart';
import 'package:totals/services/person_matcher_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late PersonRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DataSyncSettingsService.cachedEnabled = false;
    await DatabaseHelper.instance.close();
    final path = '${await databaseFactoryFfi.getDatabasesPath()}/totals.db';
    await databaseFactoryFfi.deleteDatabase(path);
    db = await DatabaseHelper.instance.database;
    repository = PersonRepository();
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  Future<void> insertTransaction(
    String reference, {
    String type = 'DEBIT',
    String? creditor,
    String? receiver,
    int bankId = 1,
    String? accountNumber,
  }) async {
    await db.insert('transactions', {
      'amount': 100.0,
      'reference': reference,
      'creditor': creditor,
      'receiver': receiver,
      'time': '2026-09-01T10:00:00.000',
      'bankId': bankId,
      'type': type,
      'accountNumber': accountNumber,
    });
  }

  group('people', () {
    test('findOrCreateByName reuses names case-insensitively', () async {
      final first = await repository.findOrCreateByName('  Abebe   Kebede ');
      final second = await repository.findOrCreateByName('ABEBE KEBEDE');

      expect(first.id, isNotNull);
      expect(second.id, first.id);
      expect(first.name, 'Abebe Kebede');
      expect(await repository.getPeople(), hasLength(1));
      expect((await repository.findByName('abebe kebede'))?.id, first.id);
    });

    test('findOrCreateByName rejects an empty name', () async {
      expect(
        () => repository.findOrCreateByName('   '),
        throwsArgumentError,
      );
    });

    test('getPeople filters by type', () async {
      final now = DateTime.now();
      await repository.savePerson(
        Person(
          name: 'Shoa Supermarket',
          type: PersonType.shop,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.findOrCreateByName('Sara');

      final shops = await repository.getPeople(type: PersonType.shop);
      expect(shops.map((person) => person.name), ['Shoa Supermarket']);
      expect(await repository.getPeople(), hasLength(2));
    });

    test('renaming a person updates the loan display name', () async {
      await insertTransaction('loan-1');
      await LoanDebtRepository().upsertTransactionPerson(
        transactionReference: 'loan-1',
        personName: 'Sara',
        direction: LoanDebtDirection.lent,
      );
      final sara = (await repository.findByName('Sara'))!;

      await repository.savePerson(sara.copyWith(name: 'Sara Tesfaye'));

      final entry = await LoanDebtRepository().getEntryForTransaction('loan-1');
      expect(entry?.personName, 'Sara Tesfaye');
      expect(entry?.personId, sara.id);
      expect((await repository.getPerson(sara.id!))?.name, 'Sara Tesfaye');
    });
  });

  group('identifiers', () {
    test('rejects empty values and normalizes phones', () async {
      final person = await repository.findOrCreateByName('Sara');

      expect(
        await repository.addIdentifier(
          personId: person.id!,
          kind: PersonIdentifierKind.phone,
          value: '  ',
        ),
        isNull,
      );

      final phone = await repository.addIdentifier(
        personId: person.id!,
        kind: PersonIdentifierKind.phone,
        value: '+251 911 223 344',
        bankId: 3,
      );
      expect(phone?.valueCanonical, '0911223344');
      expect(phone?.bankId, isNull, reason: 'phones are never bank scoped');
    });

    test('adding the same identifier twice to one person is idempotent',
        () async {
      final person = await repository.findOrCreateByName('Sara');
      final first = await repository.addIdentifier(
        personId: person.id!,
        kind: PersonIdentifierKind.phone,
        value: '0911223344',
      );
      final second = await repository.addIdentifier(
        personId: person.id!,
        kind: PersonIdentifierKind.phone,
        value: '251911223344',
      );

      expect(second?.id, first?.id);
      expect(
          await repository.getIdentifiers(personId: person.id), hasLength(1));
    });

    test('an identifier owned by someone else raises a conflict', () async {
      final sara = await repository.findOrCreateByName('Sara');
      final abebe = await repository.findOrCreateByName('Abebe');
      await repository.addIdentifier(
        personId: sara.id!,
        kind: PersonIdentifierKind.bankAccount,
        value: '1000-1234-5678',
        bankId: 1,
      );

      await expectLater(
        repository.addIdentifier(
          personId: abebe.id!,
          kind: PersonIdentifierKind.bankAccount,
          value: '100012345678',
          bankId: 1,
        ),
        throwsA(
          isA<PersonIdentifierConflict>().having(
            (conflict) => conflict.existing.personId,
            'existing.personId',
            sara.id,
          ),
        ),
      );

      // The same number at a different bank is a different account.
      final otherBank = await repository.addIdentifier(
        personId: abebe.id!,
        kind: PersonIdentifierKind.bankAccount,
        value: '100012345678',
        bankId: 2,
      );
      expect(otherBank?.personId, abebe.id);
    });
  });

  group('transaction links', () {
    test('automatic links never replace manual ones', () async {
      final sara = await repository.findOrCreateByName('Sara');
      final abebe = await repository.findOrCreateByName('Abebe');
      await insertTransaction('tx-1');

      expect(
        await repository.linkTransaction(
          transactionReference: 'tx-1',
          personId: sara.id!,
        ),
        isTrue,
      );
      expect(
        await repository.linkTransaction(
          transactionReference: 'tx-1',
          personId: abebe.id!,
          source: TransactionPersonSource.automatic,
        ),
        isFalse,
      );
      expect((await repository.getTransactionLink('tx-1'))?.personId, sara.id);

      // A manual change still wins.
      await repository.linkTransaction(
        transactionReference: 'tx-1',
        personId: abebe.id!,
      );
      final link = await repository.getTransactionLink('tx-1');
      expect(link?.personId, abebe.id);
      expect(link?.source, TransactionPersonSource.manual);

      await repository.unlinkTransaction('tx-1');
      expect(await repository.getTransactionLink('tx-1'), isNull);
    });

    test('deleting a transaction removes its person link', () async {
      final sara = await repository.findOrCreateByName('Sara');
      await insertTransaction('tx-1');
      await repository.linkTransaction(
        transactionReference: 'tx-1',
        personId: sara.id!,
      );

      await db.delete('transactions', where: 'reference = ?', whereArgs: [
        'tx-1',
      ]);

      expect(await repository.getTransactionLinks(), isEmpty);
    });
  });

  test('mergePeople moves identifiers, links and loans', () async {
    final source = await repository.findOrCreateByName('Abebe K');
    final target = await repository.findOrCreateByName('Abebe Kebede');
    await repository.addIdentifier(
      personId: source.id!,
      kind: PersonIdentifierKind.phone,
      value: '0911000000',
    );
    await repository.addIdentifier(
      personId: target.id!,
      kind: PersonIdentifierKind.bankAccount,
      value: '5678',
    );
    await insertTransaction('tx-1');
    await insertTransaction('loan-1');
    await repository.linkTransaction(
      transactionReference: 'tx-1',
      personId: source.id!,
    );
    await LoanDebtRepository().upsertTransactionPerson(
      transactionReference: 'loan-1',
      personName: 'Abebe K',
      direction: LoanDebtDirection.lent,
    );

    await repository.mergePeople(sourceId: source.id!, targetId: target.id!);

    expect(await repository.getPerson(source.id!), isNull);
    final identifiers = await repository.getIdentifiers(personId: target.id);
    expect(identifiers.map((identifier) => identifier.valueCanonical),
        containsAll(<String>['0911000000', '5678']));
    expect(
      await repository.getTransactionReferencesForPerson(target.id!),
      containsAll(<String>['tx-1', 'loan-1']),
    );
    final loan = await LoanDebtRepository().getEntryForTransaction('loan-1');
    expect(loan?.personId, target.id);
    expect(loan?.personName, 'Abebe Kebede');
  });

  test('mergePeople rejects a missing target', () async {
    final source = await repository.findOrCreateByName('Sara');
    await expectLater(
      repository.mergePeople(sourceId: source.id!, targetId: 9999),
      throwsStateError,
    );
    expect(await repository.getPerson(source.id!), isNotNull);
  });

  test('deletePerson cascades identifiers and links but keeps loans', () async {
    final sara = await repository.findOrCreateByName('Sara');
    await repository.addIdentifier(
      personId: sara.id!,
      kind: PersonIdentifierKind.phone,
      value: '0911223344',
    );
    await insertTransaction('loan-1');
    await LoanDebtRepository().upsertTransactionPerson(
      transactionReference: 'loan-1',
      personName: 'Sara',
      direction: LoanDebtDirection.borrowed,
    );

    await repository.deletePerson(sara.id!);

    expect(await repository.getIdentifiers(), isEmpty);
    expect(await repository.getTransactionLinks(), isEmpty);
    final loan = await LoanDebtRepository().getEntryForTransaction('loan-1');
    expect(loan, isNotNull);
    expect(loan?.personId, isNull);
    expect(loan?.personName, 'Sara');
  });

  test('clearAll removes people data and unlinks loans', () async {
    await insertTransaction('loan-1');
    await LoanDebtRepository().upsertTransactionPerson(
      transactionReference: 'loan-1',
      personName: 'Sara',
      direction: LoanDebtDirection.lent,
    );
    final sara = (await repository.findByName('Sara'))!;
    await repository.addIdentifier(
      personId: sara.id!,
      kind: PersonIdentifierKind.phone,
      value: '0911223344',
    );

    await repository.clearAll();

    expect(await repository.getPeople(), isEmpty);
    expect(await repository.getIdentifiers(), isEmpty);
    expect(await repository.getTransactionLinks(), isEmpty);
    final loan = await LoanDebtRepository().getEntryForTransaction('loan-1');
    expect(loan?.personId, isNull);
    expect(loan?.personName, 'Sara');
  });

  group('PersonMatcherService.backfill', () {
    test('links unlinked transactions by name, account and SMS body', () async {
      final sara = await repository.findOrCreateByName('Sara Tesfaye');
      final abebe = await repository.findOrCreateByName('Abebe Kebede');
      final cafe = await repository.findOrCreateByName('Kaldis Coffee');
      await repository.addIdentifier(
        personId: abebe.id!,
        kind: PersonIdentifierKind.bankAccount,
        value: '5678',
        bankId: 1,
      );

      await insertTransaction('by-name', receiver: 'SARA TESFAYE ALEMU');
      await insertTransaction(
        'by-account',
        receiver: 'A. K. (1000****5678)',
      );
      await insertTransaction('by-body', receiver: null);
      await db.insert('transaction_source_sms', {
        'transactionReference': 'by-body',
        'body': 'You have transferred ETB 100 to 1000****5678 on 01/09/2026.',
      });
      await insertTransaction('manual', receiver: 'Sara Tesfaye');
      await repository.linkTransaction(
        transactionReference: 'manual',
        personId: cafe.id!,
      );
      await insertTransaction('nobody', receiver: 'Unknown Shop');

      final linked = await PersonMatcherService.instance.backfill();

      expect(linked, 3);
      final links = await repository.getTransactionLinks();
      expect(links['by-name']?.personId, sara.id);
      expect(links['by-name']?.source, TransactionPersonSource.automatic);
      expect(links['by-account']?.personId, abebe.id);
      expect(links['by-body']?.personId, abebe.id);
      expect(links['manual']?.personId, cafe.id);
      expect(links['manual']?.source, TransactionPersonSource.manual);
      expect(links.containsKey('nobody'), isFalse);

      // A second run has nothing left to do.
      expect(await PersonMatcherService.instance.backfill(), 0);
    });

    test('ignores the user\'s own registered account numbers', () async {
      final abebe = await repository.findOrCreateByName('Abebe Kebede');
      await repository.addIdentifier(
        personId: abebe.id!,
        kind: PersonIdentifierKind.bankAccount,
        value: '5678',
      );
      await db.insert('accounts', {
        'accountNumber': '100099995678',
        'bank': 1,
        'balance': 0.0,
        'accountHolderName': 'Me',
      });
      await insertTransaction('own', receiver: null);
      await db.insert('transaction_source_sms', {
        'transactionReference': 'own',
        'body': 'Your account 1000****5678 has been debited with ETB 100.',
      });

      expect(await PersonMatcherService.instance.backfill(), 0);
    });

    test('does nothing when no people exist', () async {
      await insertTransaction('tx-1', receiver: 'Sara');
      expect(await PersonMatcherService.instance.backfill(), 0);
      expect(await repository.getTransactionLinks(), isEmpty);
    });
  });
}
