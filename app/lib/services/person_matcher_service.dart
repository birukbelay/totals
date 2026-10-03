import 'package:flutter/foundation.dart';
import 'package:totals/database/database_helper.dart';
import 'package:totals/models/person.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/repositories/person_repository.dart';

/// Evidence about who a transaction was with, gathered from parsed fields
/// and the original SMS body.
class PersonMatchInput {
  final String reference;
  final int? bankId;
  final String? type;
  final String? creditor;
  final String? receiver;
  final String? accountNumber;
  final String? ownerAccountNumber;
  final String? messageBody;

  const PersonMatchInput({
    required this.reference,
    this.bankId,
    this.type,
    this.creditor,
    this.receiver,
    this.accountNumber,
    this.ownerAccountNumber,
    this.messageBody,
  });

  factory PersonMatchInput.fromTransaction(
    Transaction transaction, {
    String? messageBody,
  }) {
    return PersonMatchInput(
      reference: transaction.reference,
      bankId: transaction.bankId,
      type: transaction.type,
      creditor: transaction.creditor,
      receiver: transaction.receiver,
      accountNumber: transaction.accountNumber,
      ownerAccountNumber: transaction.ownerAccountNumber,
      messageBody: messageBody,
    );
  }

  /// The counterparty text: who received a debit, or who sent a credit.
  String? get counterparty {
    final isCredit = type?.toUpperCase().contains('CREDIT') == true;
    final primary = isCredit ? creditor : receiver;
    if (primary != null && primary.trim().isNotEmpty) return primary;
    final fallback = isCredit ? receiver : creditor;
    return fallback?.trim().isNotEmpty == true ? fallback : null;
  }
}

/// In-memory index of people and identifiers used to match transactions.
///
/// Matching is deliberately conservative: an account or phone identifier is
/// preferred over a name, and a transaction is only assigned when exactly one
/// person matches the strongest available evidence.
class PersonMatchIndex {
  final Map<int, Person> _peopleById;
  final List<PersonIdentifier> _identifiers;
  final List<String> _ownAccountPatterns;

  PersonMatchIndex({
    required Iterable<Person> people,
    required Iterable<PersonIdentifier> identifiers,
    Iterable<String> ownAccountNumbers = const <String>[],
  })  : _peopleById = {
          for (final person in people)
            if (person.id != null) person.id!: person,
        },
        _identifiers = identifiers.toList(growable: false),
        _ownAccountPatterns = ownAccountNumbers
            .map(_identifierPattern)
            .whereType<String>()
            .toList(growable: false);

  bool get isEmpty => _peopleById.isEmpty;

  int? match(PersonMatchInput input) {
    if (_peopleById.isEmpty) return null;

    final identifierMatches = _matchIdentifiers(input);
    if (identifierMatches.length == 1) return identifierMatches.single;
    if (identifierMatches.length > 1) return null;

    final nameMatches = _matchNames(input.counterparty);
    return nameMatches.length == 1 ? nameMatches.single : null;
  }

  Set<int> _matchIdentifiers(PersonMatchInput input) {
    if (_identifiers.isEmpty) return const <int>{};

    final own = <String>[
      ..._ownAccountPatterns,
      for (final value in [input.accountNumber, input.ownerAccountNumber])
        if (_identifierPattern(value) case final pattern?) pattern,
    ];
    // Counterparty text is specific enough to trust short suffixes. The full
    // SMS body also mentions balances and the user's own account, so only
    // masked or full-length numbers are taken from it.
    final tokens = <String>{
      ..._accountTokens(input.counterparty, allowShortSuffix: true),
      ..._accountTokens(input.messageBody, allowShortSuffix: false),
    }..removeWhere(
        (token) => own.any((ownPattern) => _patternsMatch(token, ownPattern)),
      );
    if (tokens.isEmpty) return const <int>{};

    final matches = <int>{};
    for (final identifier in _identifiers) {
      if (!_peopleById.containsKey(identifier.personId)) continue;
      if (identifier.kind == PersonIdentifierKind.bankAccount &&
          identifier.bankId != null &&
          input.bankId != null &&
          identifier.bankId != input.bankId) {
        continue;
      }
      final pattern = _identifierPattern(
        identifier.valueCanonical,
        phone: identifier.kind == PersonIdentifierKind.phone,
      );
      if (pattern == null) continue;
      final tokenVariants = identifier.kind == PersonIdentifierKind.phone
          ? tokens.map(_normalizePhonePattern)
          : tokens;
      if (tokenVariants.any((token) => _patternsMatch(token, pattern))) {
        matches.add(identifier.personId);
      }
    }
    return matches;
  }

  Set<int> _matchNames(String? counterparty) {
    final candidate = canonicalCounterpartyName(counterparty);
    if (candidate == null) return const <int>{};
    final candidateTokens = candidate.split(' ');

    final matches = <int>{};
    for (final person in _peopleById.values) {
      final name = canonicalCounterpartyName(person.name);
      if (name == null) continue;
      if (name == candidate) {
        matches.add(person.id!);
        continue;
      }
      final nameTokens = name.split(' ');
      // "Abebe Kebede" matches "ABEBE KEBEDE TESFAYE" and the reverse, but a
      // single first name never matches a longer counterparty on its own.
      if (nameTokens.length >= 2 && candidateTokens.length >= 2) {
        final shorter = nameTokens.length <= candidateTokens.length
            ? nameTokens
            : candidateTokens;
        final longer =
            identical(shorter, nameTokens) ? candidateTokens : nameTokens;
        if (listEquals(shorter, longer.sublist(0, shorter.length))) {
          matches.add(person.id!);
        }
      }
    }
    return matches;
  }
}

/// Lower-cased name with bracketed account/phone details, digits and
/// punctuation removed, e.g. `ABEBE K. (2519****1234)` -> `abebe k`.
String? canonicalCounterpartyName(String? raw) {
  final value = raw
      ?.toLowerCase()
      .replaceAll(RegExp(r'\([^)]*\)'), ' ')
      .replaceAll(RegExp(r'[^a-zሀ-፿\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (value == null || value.length < 2) return null;
  return value;
}

final RegExp _accountTokenPattern = RegExp(r'\+?[0-9*xX•#]{4,}');

Set<String> _accountTokens(String? text, {required bool allowShortSuffix}) {
  if (text == null || text.trim().isEmpty) return const <String>{};
  final tokens = <String>{};
  for (final match in _accountTokenPattern.allMatches(text)) {
    final pattern = _identifierPattern(match.group(0));
    if (pattern == null) continue;
    final digits = pattern.replaceAll('?', '').length;
    final masked = pattern.contains('?');
    if (digits < 3) continue;
    if (!masked && !allowShortSuffix && pattern.length < 9) continue;
    if (!masked && pattern.length < 4) continue;
    tokens.add(pattern);
  }
  return tokens;
}

/// Normalizes an identifier to digits with `?` for masked positions.
String? _identifierPattern(String? raw, {bool phone = false}) {
  final value = raw?.trim().toUpperCase();
  if (value == null || value.isEmpty) return null;
  final buffer = StringBuffer();
  for (final character in value.split('')) {
    if (character == '*' ||
        character == 'X' ||
        character == '•' ||
        character == '#') {
      buffer.write('?');
    } else if (RegExp(r'[A-Z0-9]').hasMatch(character)) {
      buffer.write(character);
    }
  }
  final pattern = buffer.toString();
  if (pattern.replaceAll('?', '').isEmpty) return null;
  return phone ? _normalizePhonePattern(pattern) : pattern;
}

String _normalizePhonePattern(String pattern) {
  if (pattern.startsWith('00251')) return '0${pattern.substring(5)}';
  if (pattern.startsWith('251') && pattern.length == 12) {
    return '0${pattern.substring(3)}';
  }
  if (pattern.length == 9 &&
      (pattern.startsWith('9') || pattern.startsWith('7'))) {
    return '0$pattern';
  }
  return pattern;
}

/// Compares two account patterns by the digits both of them reveal.
///
/// Full numbers must be equal. A masked number such as `1000****6789`
/// matches when its visible prefix and suffix agree with the other side and
/// reveal at least four digits. A bare suffix of four or more digits (as
/// typed by a user who only knows the last digits) matches the end of a
/// longer full or masked number.
bool _patternsMatch(String left, String right) {
  if (left == right) return true;
  final leftMasked = left.contains('?');
  final rightMasked = right.contains('?');

  if (!leftMasked && !rightMasked) {
    final shorter = left.length <= right.length ? left : right;
    final longer = identical(shorter, left) ? right : left;
    return shorter.length >= 4 &&
        shorter.length < longer.length &&
        longer.endsWith(shorter);
  }

  if (leftMasked && rightMasked) {
    if (left.length != right.length) return false;
    var evidence = 0;
    for (var index = 0; index < left.length; index++) {
      if (left[index] == '?' || right[index] == '?') continue;
      if (left[index] != right[index]) return false;
      evidence++;
    }
    return evidence >= 4;
  }

  final masked = leftMasked ? left : right;
  final plain = leftMasked ? right : left;
  if (plain.length <= masked.length) {
    // A full number of the same length, or a bare suffix such as `5678`,
    // is aligned to the end of the masked number.
    if (plain.length < 4) return false;
    final offset = masked.length - plain.length;
    var evidence = 0;
    for (var index = 0; index < plain.length; index++) {
      final maskedCharacter = masked[offset + index];
      if (maskedCharacter == '?') continue;
      if (maskedCharacter != plain[index]) return false;
      evidence++;
    }
    return evidence >= 4;
  }
  // The mask may hide fewer digits than the full number has.
  final prefix = masked.substring(0, masked.indexOf('?'));
  final suffix = masked.substring(masked.lastIndexOf('?') + 1);
  if (prefix.length + suffix.length < 4) return false;
  if (prefix.length + suffix.length > plain.length) return false;
  return plain.startsWith(prefix) && plain.endsWith(suffix);
}

class PersonMatcherService {
  PersonMatcherService._();

  static final PersonMatcherService instance = PersonMatcherService._();

  final PersonRepository _repository = PersonRepository();

  Future<PersonMatchIndex> loadIndex() async {
    final db = await DatabaseHelper.instance.database;
    final people = await _repository.getPeople();
    if (people.isEmpty) {
      return PersonMatchIndex(people: const [], identifiers: const []);
    }
    final identifiers = await _repository.getIdentifiers();
    final accountRows = await db.query(
      'accounts',
      columns: const ['accountNumber'],
    );
    return PersonMatchIndex(
      people: people,
      identifiers: identifiers,
      ownAccountNumbers: accountRows
          .map((row) => row['accountNumber'] as String?)
          .whereType<String>(),
    );
  }

  /// Matches one freshly saved transaction. Returns the linked person id, or
  /// null when nothing (or more than one person) matched.
  Future<int?> matchAndLink(
    Transaction transaction, {
    String? messageBody,
  }) async {
    try {
      final index = await loadIndex();
      if (index.isEmpty) return null;
      final personId = index.match(
        PersonMatchInput.fromTransaction(
          transaction,
          messageBody: messageBody,
        ),
      );
      if (personId == null) return null;
      final linked = await _repository.linkTransaction(
        transactionReference: transaction.reference,
        personId: personId,
        source: TransactionPersonSource.automatic,
      );
      return linked ? personId : null;
    } catch (error) {
      debugPrint('debug: Person matching failed: $error');
      return null;
    }
  }

  /// Re-runs matching over stored transactions without reparsing SMS.
  ///
  /// Only transactions without a person link are considered, so manual and
  /// earlier automatic links are preserved. Returns the number of links
  /// created.
  Future<int> backfill() async {
    final index = await loadIndex();
    if (index.isEmpty) return 0;

    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT t.reference, t.bankId, t.type, t.creditor, t.receiver,
             t.accountNumber, t.ownerAccountNumber, s.body
      FROM transactions t
      LEFT JOIN transaction_people tp
        ON tp.transactionReference = t.reference
      LEFT JOIN transaction_source_sms s
        ON s.transactionReference = t.reference
      WHERE tp.transactionReference IS NULL
    ''');

    final nowIso = DateTime.now().toIso8601String();
    var linked = 0;
    final batch = db.batch();
    for (final row in rows) {
      final reference = row['reference'] as String?;
      if (reference == null || reference.trim().isEmpty) continue;
      final personId = index.match(
        PersonMatchInput(
          reference: reference,
          bankId: (row['bankId'] as num?)?.toInt(),
          type: row['type'] as String?,
          creditor: row['creditor'] as String?,
          receiver: row['receiver'] as String?,
          accountNumber: row['accountNumber'] as String?,
          ownerAccountNumber: row['ownerAccountNumber'] as String?,
          messageBody: row['body'] as String?,
        ),
      );
      if (personId == null) continue;
      batch.insert('transaction_people', {
        'transactionReference': reference,
        'personId': personId,
        'source': TransactionPersonSource.automatic.storageValue,
        'createdAt': nowIso,
      });
      linked++;
    }
    if (linked > 0) await batch.commit(noResult: true);
    return linked;
  }
}
