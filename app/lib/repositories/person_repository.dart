import 'package:sqflite/sqflite.dart';
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/person.dart';

class PersonRepository {
  Future<List<Person>> getPeople({PersonType? type}) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'people',
      where: type == null ? null : 'type = ?',
      whereArgs: type == null ? null : [type.storageValue],
      orderBy: 'name COLLATE NOCASE ASC, id ASC',
    );
    return rows.map(Person.fromDb).toList(growable: false);
  }

  Future<Person?> getPerson(int id) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'people',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Person.fromDb(rows.first);
  }

  Future<Person?> findByName(String name) async {
    final normalized = normalizePersonName(name);
    if (normalized.isEmpty) return null;
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'people',
      where: 'LOWER(TRIM(name)) = LOWER(?)',
      whereArgs: [normalized],
      orderBy: 'id ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : Person.fromDb(rows.first);
  }

  /// Returns the person with [name], creating a [type] person when none
  /// exists yet. Names are compared case-insensitively.
  Future<Person> findOrCreateByName(
    String name, {
    PersonType type = PersonType.friend,
    DatabaseExecutor? executor,
  }) async {
    final normalized = normalizePersonName(name);
    if (normalized.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Person name is required');
    }
    final db = executor ?? await DatabaseHelper.instance.database;
    final rows = await db.query(
      'people',
      where: 'LOWER(TRIM(name)) = LOWER(?)',
      whereArgs: [normalized],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (rows.isNotEmpty) return Person.fromDb(rows.first);

    final now = DateTime.now();
    final person = Person(
      name: normalized,
      type: type,
      createdAt: now,
      updatedAt: now,
    );
    final id = await db.insert('people', person.toDb());
    return person.copyWith(id: id);
  }

  Future<Person> savePerson(Person person) async {
    final normalized = normalizePersonName(person.name);
    if (normalized.isEmpty) {
      throw ArgumentError.value(person.name, 'name', 'Person name is required');
    }
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now();
    final saved = person.copyWith(name: normalized, updatedAt: now);
    if (person.id == null) {
      final id = await db.insert('people', saved.toDb());
      return saved.copyWith(id: id);
    }
    await db.transaction((txn) async {
      final previous = await txn.query(
        'people',
        columns: const ['name'],
        where: 'id = ?',
        whereArgs: [person.id],
        limit: 1,
      );
      await txn.update(
        'people',
        saved.toDb()..remove('id'),
        where: 'id = ?',
        whereArgs: [person.id],
      );
      // Keep the loan/debt display fallback in step with a rename.
      if (previous.isNotEmpty && previous.first['name'] != normalized) {
        await txn.update(
          'loan_debt_entries',
          {'personName': normalized},
          where: 'personId = ?',
          whereArgs: [person.id],
        );
      }
    });
    return saved;
  }

  /// Deletes a person. Identifiers and transaction links are removed by the
  /// `trg_people_delete` trigger; loan/debt rows keep their personName.
  Future<void> deletePerson(int id) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('people', where: 'id = ?', whereArgs: [id]);
  }

  /// Moves every identifier, transaction link and loan of [sourceId] onto
  /// [targetId], then deletes the source person.
  Future<void> mergePeople({
    required int sourceId,
    required int targetId,
  }) async {
    if (sourceId == targetId) return;
    final db = await DatabaseHelper.instance.database;
    await db.transaction((txn) async {
      final target = await txn.query(
        'people',
        where: 'id = ?',
        whereArgs: [targetId],
        limit: 1,
      );
      if (target.isEmpty) {
        throw StateError('Merge target person $targetId does not exist');
      }
      final targetName = target.first['name'];
      await txn.rawUpdate(
        'UPDATE OR IGNORE person_identifiers SET personId = ? '
        'WHERE personId = ?',
        [targetId, sourceId],
      );
      await txn.rawUpdate(
        'UPDATE OR IGNORE transaction_people SET personId = ? '
        'WHERE personId = ?',
        [targetId, sourceId],
      );
      await txn.update(
        'loan_debt_entries',
        {'personId': targetId, 'personName': targetName},
        where: 'personId = ?',
        whereArgs: [sourceId],
      );
      await txn.update(
        'transaction_splits',
        {'personId': targetId},
        where: 'personId = ?',
        whereArgs: [sourceId],
      );
      await txn.delete('people', where: 'id = ?', whereArgs: [sourceId]);
    });
  }

  Future<List<PersonIdentifier>> getIdentifiers({int? personId}) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'person_identifiers',
      where: personId == null ? null : 'personId = ?',
      whereArgs: personId == null ? null : [personId],
      orderBy: 'id ASC',
    );
    return rows.map(PersonIdentifier.fromDb).toList(growable: false);
  }

  /// Adds an account number or phone to a person. Returns null when the
  /// value is empty. Throws [PersonIdentifierConflict] when another person
  /// already owns the same identifier.
  Future<PersonIdentifier?> addIdentifier({
    required int personId,
    required PersonIdentifierKind kind,
    required String value,
    int? bankId,
  }) async {
    final trimmed = value.trim();
    final canonical = canonicalPersonIdentifier(kind, trimmed);
    if (canonical == null) return null;
    final effectiveBankId = kind == PersonIdentifierKind.phone ? null : bankId;

    final db = await DatabaseHelper.instance.database;
    final existing = await db.query(
      'person_identifiers',
      where: 'kind = ? AND IFNULL(bankId, -1) = ? AND valueCanonical = ?',
      whereArgs: [kind.storageValue, effectiveBankId ?? -1, canonical],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final identifier = PersonIdentifier.fromDb(existing.first);
      if (identifier.personId == personId) return identifier;
      throw PersonIdentifierConflict(identifier);
    }

    final identifier = PersonIdentifier(
      personId: personId,
      kind: kind,
      bankId: effectiveBankId,
      value: trimmed,
      valueCanonical: canonical,
      createdAt: DateTime.now(),
    );
    final id = await db.insert('person_identifiers', identifier.toDb());
    return PersonIdentifier(
      id: id,
      personId: identifier.personId,
      kind: identifier.kind,
      bankId: identifier.bankId,
      value: identifier.value,
      valueCanonical: identifier.valueCanonical,
      createdAt: identifier.createdAt,
    );
  }

  Future<void> deleteIdentifier(int identifierId) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'person_identifiers',
      where: 'id = ?',
      whereArgs: [identifierId],
    );
  }

  Future<Map<String, TransactionPersonLink>> getTransactionLinks() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('transaction_people');
    return {
      for (final row in rows)
        (row['transactionReference'] as String): TransactionPersonLink.fromDb(
          row,
        ),
    };
  }

  Future<TransactionPersonLink?> getTransactionLink(String reference) async {
    final normalized = reference.trim();
    if (normalized.isEmpty) return null;
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'transaction_people',
      where: 'transactionReference = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    return rows.isEmpty ? null : TransactionPersonLink.fromDb(rows.first);
  }

  /// Links a transaction to a person.
  ///
  /// An automatic link never replaces an existing manual one, so a person the
  /// user picked by hand survives later matcher runs. Returns whether a row
  /// was written.
  Future<bool> linkTransaction({
    required String transactionReference,
    required int personId,
    TransactionPersonSource source = TransactionPersonSource.manual,
    DatabaseExecutor? executor,
  }) async {
    final reference = transactionReference.trim();
    if (reference.isEmpty) return false;
    final db = executor ?? await DatabaseHelper.instance.database;
    if (source == TransactionPersonSource.automatic) {
      final existing = await db.query(
        'transaction_people',
        columns: const ['source'],
        where: 'transactionReference = ?',
        whereArgs: [reference],
        limit: 1,
      );
      if (existing.isNotEmpty &&
          existing.first['source'] ==
              TransactionPersonSource.manual.storageValue) {
        return false;
      }
    }
    await db.insert(
      'transaction_people',
      TransactionPersonLink(
        transactionReference: reference,
        personId: personId,
        source: source,
        createdAt: DateTime.now(),
      ).toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<void> unlinkTransaction(String transactionReference) async {
    final reference = transactionReference.trim();
    if (reference.isEmpty) return;
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'transaction_people',
      where: 'transactionReference = ?',
      whereArgs: [reference],
    );
  }

  Future<List<String>> getTransactionReferencesForPerson(int personId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'transaction_people',
      columns: const ['transactionReference'],
      where: 'personId = ?',
      whereArgs: [personId],
    );
    return rows
        .map((row) => row['transactionReference'] as String)
        .toList(growable: false);
  }

  Future<void> clearAll() async {
    final db = await DatabaseHelper.instance.database;
    await db.transaction((txn) async {
      await txn.update('loan_debt_entries', {'personId': null});
      await txn.update('transaction_splits', {'personId': null});
      await txn.delete('transaction_people');
      await txn.delete('person_identifiers');
      await txn.delete('people');
    });
  }
}

class PersonIdentifierConflict implements Exception {
  final PersonIdentifier existing;

  const PersonIdentifierConflict(this.existing);

  @override
  String toString() => 'Identifier ${existing.value} already belongs to person '
      '${existing.personId}';
}

String normalizePersonName(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// Canonical identifier used for uniqueness and matching. Phone numbers fold
/// the Ethiopian `+251`/`251`/`9…` forms into `09…`; account numbers keep
/// letters, digits and mask characters so partial numbers remain usable.
String? canonicalPersonIdentifier(PersonIdentifierKind kind, String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  if (kind == PersonIdentifierKind.phone) {
    var digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('00251') && digits.length == 14) {
      digits = digits.substring(2);
    }
    if (digits.startsWith('251') && digits.length == 12) {
      return '0${digits.substring(3)}';
    }
    if (digits.length == 9 &&
        (digits.startsWith('9') || digits.startsWith('7'))) {
      return '0$digits';
    }
    return digits.isEmpty ? null : digits;
  }
  final compact = value
      .toUpperCase()
      .replaceAll(RegExp(r'[X•#]'), '*')
      .replaceAll(RegExp(r'[^A-Z0-9*]'), '');
  return compact.replaceAll('*', '').isEmpty ? null : compact;
}
