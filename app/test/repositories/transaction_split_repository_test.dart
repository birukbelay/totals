import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/models/transaction_split.dart';
import 'package:totals/repositories/person_repository.dart';
import 'package:totals/repositories/transaction_split_repository.dart';
import 'package:totals/services/data_sync/data_sync_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late TransactionSplitRepository repository;
  late PersonRepository people;

  final parent = Transaction(
    amount: 1000,
    reference: 'TX1',
    serviceCharge: 10,
    type: 'DEBIT',
  );

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
    repository = TransactionSplitRepository();
    people = PersonRepository();
    await db.insert('transactions', {
      'amount': 1000.0,
      'reference': 'TX1',
      'serviceCharge': 10.0,
      'time': '2026-09-01T10:00:00.000',
      'type': 'DEBIT',
    });
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  TransactionSplit split(
    double amount, {
    int? id,
    int? categoryId,
    int? personId,
    TransactionSplitKind kind = TransactionSplitKind.expense,
    TransactionSplitStatus? status,
    DateTime? createdAt,
  }) {
    final now = createdAt ?? DateTime(2026, 9, 1);
    return TransactionSplit(
      id: id,
      parentReference: 'ignored',
      amount: amount,
      categoryId: categoryId,
      personId: personId,
      kind: kind,
      status: status,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<int> splitCount() async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM transaction_splits',
    );
    return rows.first['c'] as int;
  }

  test('rejects invalid splits without writing anything', () async {
    final friend = await people.findOrCreateByName('Abebe');

    await expectLater(
      repository.saveSplits(parent, [split(600), split(401)]),
      throwsArgumentError,
    );
    await expectLater(
      repository.saveSplits(parent, [split(0)]),
      throwsArgumentError,
    );
    await expectLater(
      repository.saveSplits(parent, [split(-5)]),
      throwsArgumentError,
    );
    await expectLater(
      repository.saveSplits(
        parent,
        [split(100, kind: TransactionSplitKind.loan)],
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.saveSplits(
        Transaction(amount: 10, reference: '  ', type: 'DEBIT'),
        [split(5)],
      ),
      throwsArgumentError,
    );
    expect(await splitCount(), 0);

    // Fees are not allocatable, but the full principal is.
    final saved = await repository.saveSplits(parent, [
      split(600),
      split(400, personId: friend.id, kind: TransactionSplitKind.loan),
    ]);
    expect(saved, hasLength(2));
  });

  test('saves a bill split with one share per person', () async {
    final abebe = await people.findOrCreateByName('Abebe');
    final sara = await people.findOrCreateByName('Sara');

    final saved = await repository.saveSplits(parent, [
      split(250, categoryId: 3),
      split(
        250,
        personId: abebe.id,
        categoryId: 3,
        kind: TransactionSplitKind.billShare,
      ),
      split(
        500,
        personId: sara.id,
        kind: TransactionSplitKind.billShare,
        status: TransactionSplitStatus.paid,
      ),
    ]);

    expect(saved.map((s) => s.parentReference).toSet(), {'TX1'});
    expect(saved.every((s) => s.id != null), isTrue);
    expect(saved[0].status, isNull);
    expect(saved[0].categoryId, 3);
    // Owed shares never carry a category and default to pending.
    expect(saved[1].categoryId, isNull);
    expect(saved[1].status, TransactionSplitStatus.pending);
    expect(saved[2].status, TransactionSplitStatus.paid);

    final loaded = await repository.getSplitsForTransaction(' TX1 ');
    expect(loaded.map((s) => s.amount), [250, 250, 500]);
    expect(await repository.getSplitsForPerson(sara.id!), hasLength(1));

    final all = await repository.getAllSplits();
    expect(all.keys, ['TX1']);
    expect(all['TX1'], hasLength(3));
  });

  test('re-saving keeps ids and createdAt of edited splits', () async {
    final first = await repository.saveSplits(parent, [
      split(300, categoryId: 1, createdAt: DateTime(2026, 1, 1)),
      split(200, categoryId: 2),
    ]);
    final originalCreatedAt = first.first.createdAt;

    final second = await repository.saveSplits(parent, [
      split(
        350,
        id: first.first.id,
        categoryId: 1,
        createdAt: DateTime(2030, 1, 1),
      ),
      split(100, categoryId: 4),
    ]);

    expect(second.first.id, first.first.id);
    expect(second.first.createdAt, originalCreatedAt);
    expect(second.first.amount, 350);
    final loaded = await repository.getSplitsForTransaction('TX1');
    expect(loaded.map((s) => s.categoryId), unorderedEquals([1, 4]));

    await repository.saveSplits(parent, const []);
    expect(await splitCount(), 0);
  });

  test('status changes only apply to loans and bill shares', () async {
    final friend = await people.findOrCreateByName('Abebe');
    final saved = await repository.saveSplits(parent, [
      split(300, categoryId: 1),
      split(200, personId: friend.id, kind: TransactionSplitKind.loan),
    ]);

    await repository.setSplitStatus(saved[0].id!, TransactionSplitStatus.paid);
    await repository.setSplitStatus(saved[1].id!, TransactionSplitStatus.paid);

    final loaded = await repository.getSplitsForTransaction('TX1');
    expect(loaded[0].status, isNull);
    expect(loaded[1].status, TransactionSplitStatus.paid);
    expect(loaded[1].isPending, isFalse);
  });

  test('deleting the parent transaction deletes its splits', () async {
    await repository.saveSplits(parent, [split(300), split(200)]);
    expect(await splitCount(), 2);

    await db.delete('transactions', where: 'reference = ?', whereArgs: ['TX1']);

    expect(await splitCount(), 0);
  });

  test('people deletes and merges keep splits consistent', () async {
    final abebe = await people.findOrCreateByName('Abebe');
    final abe = await people.findOrCreateByName('Abe');
    final sara = await people.findOrCreateByName('Sara');
    await repository.saveSplits(parent, [
      split(100, personId: abebe.id, kind: TransactionSplitKind.loan),
      split(200, personId: abe.id, kind: TransactionSplitKind.billShare),
      split(300, personId: sara.id, kind: TransactionSplitKind.billShare),
    ]);

    await people.mergePeople(sourceId: abe.id!, targetId: abebe.id!);
    expect(await repository.getSplitsForPerson(abebe.id!), hasLength(2));

    await people.deletePerson(sara.id!);
    final orphaned = await repository.getSplitsForTransaction('TX1');
    expect(orphaned.where((s) => s.personId == null), hasLength(1));
    expect(await splitCount(), 3);
  });

  test('clearOwedSplits keeps category splits', () async {
    final friend = await people.findOrCreateByName('Abebe');
    await repository.saveSplits(parent, [
      split(300, categoryId: 1),
      split(200, personId: friend.id, kind: TransactionSplitKind.loan),
      split(100, personId: friend.id, kind: TransactionSplitKind.billShare),
    ]);

    await repository.clearOwedSplits();

    final remaining = await repository.getSplitsForTransaction('TX1');
    expect(remaining, hasLength(1));
    expect(remaining.single.kind, TransactionSplitKind.expense);

    await repository.clearAll();
    expect(await splitCount(), 0);
  });
}
