import 'package:flutter_test/flutter_test.dart';
import 'package:totals/models/person.dart';
import 'package:totals/repositories/person_repository.dart';
import 'package:totals/services/person_matcher_service.dart';

final DateTime _now = DateTime(2026, 9, 1);

Person _person(int id, String name) =>
    Person(id: id, name: name, createdAt: _now, updatedAt: _now);

PersonIdentifier _identifier(
  int personId,
  String value, {
  PersonIdentifierKind kind = PersonIdentifierKind.bankAccount,
  int? bankId,
}) {
  return PersonIdentifier(
    personId: personId,
    kind: kind,
    bankId: bankId,
    value: value,
    valueCanonical: canonicalPersonIdentifier(kind, value)!,
    createdAt: _now,
  );
}

PersonMatchInput _debit({
  String? receiver,
  String? body,
  int bankId = 1,
  String? accountNumber,
}) {
  return PersonMatchInput(
    reference: 'ref',
    bankId: bankId,
    type: 'DEBIT',
    receiver: receiver,
    accountNumber: accountNumber,
    messageBody: body,
  );
}

void main() {
  group('canonicalCounterpartyName', () {
    test('drops bracketed details, digits and punctuation', () {
      expect(
        canonicalCounterpartyName('ABEBE K. (2519****1234)'),
        'abebe k',
      );
      expect(canonicalCounterpartyName('  Sara-Tesfaye 12 '), 'sara tesfaye');
      expect(canonicalCounterpartyName('7'), isNull);
      expect(canonicalCounterpartyName(null), isNull);
    });
  });

  group('PersonMatchInput.counterparty', () {
    test('uses the receiver for debits and the creditor for credits', () {
      const debit = PersonMatchInput(
        reference: 'a',
        type: 'DEBIT',
        creditor: 'Me',
        receiver: 'Cafe',
      );
      const credit = PersonMatchInput(
        reference: 'b',
        type: 'CREDIT',
        creditor: 'Sara',
        receiver: 'Me',
      );
      const fallback = PersonMatchInput(
        reference: 'c',
        type: 'DEBIT',
        creditor: 'Only creditor',
        receiver: '  ',
      );
      expect(debit.counterparty, 'Cafe');
      expect(credit.counterparty, 'Sara');
      expect(fallback.counterparty, 'Only creditor');
    });
  });

  group('name matching', () {
    final index = PersonMatchIndex(
      people: [
        _person(1, 'Abebe Kebede'),
        _person(2, 'Sara'),
        _person(3, 'Kaldis Coffee'),
      ],
      identifiers: const [],
    );

    test('matches the full name regardless of case and punctuation', () {
      expect(index.match(_debit(receiver: 'ABEBE KEBEDE')), 1);
      expect(index.match(_debit(receiver: 'Kaldis Coffee (Bole)')), 3);
      expect(index.match(_debit(receiver: 'sara')), 2);
    });

    test('matches a multi-word name prefix in either direction', () {
      expect(index.match(_debit(receiver: 'Abebe Kebede Tesfaye')), 1);
      final shortName = PersonMatchIndex(
        people: [_person(1, 'Abebe Kebede Tesfaye')],
        identifiers: const [],
      );
      expect(shortName.match(_debit(receiver: 'ABEBE KEBEDE')), 1);
    });

    test('a single first name never matches a longer counterparty', () {
      expect(index.match(_debit(receiver: 'Sara Tesfaye')), isNull);
      expect(index.match(_debit(receiver: 'Abebe')), isNull);
    });

    test('ambiguous names match nobody', () {
      final ambiguous = PersonMatchIndex(
        people: [_person(1, 'Abebe Kebede'), _person(2, 'Abebe Kebede Alemu')],
        identifiers: const [],
      );
      expect(ambiguous.match(_debit(receiver: 'Abebe Kebede Alemu')), isNull);
    });

    test('an empty index matches nothing', () {
      final empty = PersonMatchIndex(people: const [], identifiers: const []);
      expect(empty.isEmpty, isTrue);
      expect(empty.match(_debit(receiver: 'Sara')), isNull);
    });
  });

  group('identifier matching', () {
    test('a last-digits identifier matches a masked counterparty', () {
      final index = PersonMatchIndex(
        people: [_person(1, 'Abebe Kebede')],
        identifiers: [_identifier(1, '5678')],
      );
      expect(index.match(_debit(receiver: 'A.K. (1000****5678)')), 1);
      expect(index.match(_debit(receiver: 'A.K. (1000****9999)')), isNull);
    });

    test('a full account matches a masked number in the SMS body', () {
      final index = PersonMatchIndex(
        people: [_person(1, 'Sara')],
        identifiers: [_identifier(1, '1000 1234 5678')],
      );
      expect(
        index.match(
          _debit(body: 'Transferred ETB 500 to 1000****5678 on 01/09/2026'),
        ),
        1,
      );
    });

    test('short unmasked numbers in the SMS body are ignored', () {
      final index = PersonMatchIndex(
        people: [_person(1, 'Sara')],
        identifiers: [_identifier(1, '2026')],
      );
      expect(
        index.match(_debit(body: 'Paid ETB 2026 on 01/09/2026')),
        isNull,
      );
    });

    test('a bank-scoped identifier only matches its bank', () {
      final index = PersonMatchIndex(
        people: [_person(1, 'Sara')],
        identifiers: [_identifier(1, '5678', bankId: 2)],
      );
      expect(index.match(_debit(receiver: '1000****5678', bankId: 1)), isNull);
      expect(index.match(_debit(receiver: '1000****5678', bankId: 2)), 1);
    });

    test('identifiers win over names', () {
      final index = PersonMatchIndex(
        people: [_person(1, 'Sara'), _person(2, 'Abebe Kebede')],
        identifiers: [_identifier(1, '5678')],
      );
      expect(index.match(_debit(receiver: 'ABEBE KEBEDE (1000****5678)')), 1);
    });

    test('several people owning the evidence match nobody', () {
      final index = PersonMatchIndex(
        people: [_person(1, 'Sara'), _person(2, 'Abebe Kebede')],
        identifiers: [_identifier(1, '5678'), _identifier(2, '45678')],
      );
      expect(index.match(_debit(receiver: '1000****45678')), isNull);
    });

    test('the user\'s own account numbers are never evidence', () {
      final index = PersonMatchIndex(
        people: [_person(1, 'Sara')],
        identifiers: [_identifier(1, '5678')],
        ownAccountNumbers: const ['100099995678'],
      );
      expect(
        index.match(_debit(body: 'Your account 1000****5678 was debited')),
        isNull,
      );

      final viaTransaction = PersonMatchIndex(
        people: [_person(1, 'Sara')],
        identifiers: [_identifier(1, '5678')],
      );
      expect(
        viaTransaction.match(
          _debit(
            body: 'Your account 1000****5678 was debited',
            accountNumber: '5678',
          ),
        ),
        isNull,
      );
    });

    test('phones match across +251, 251 and 09 forms', () {
      final index = PersonMatchIndex(
        people: [_person(1, 'Sara')],
        identifiers: [
          _identifier(1, '+251 911 223 344', kind: PersonIdentifierKind.phone),
        ],
      );
      expect(index.match(_debit(receiver: 'Sara T (0911223344)')), 1);
      expect(index.match(_debit(body: 'Sent to 251911223344 via telebirr')), 1);
      expect(index.match(_debit(receiver: '0911000000')), isNull);
    });
  });

  group('canonicalPersonIdentifier', () {
    test('folds phone formats into 09…', () {
      const phone = PersonIdentifierKind.phone;
      expect(canonicalPersonIdentifier(phone, '+251911223344'), '0911223344');
      expect(canonicalPersonIdentifier(phone, '00251911223344'), '0911223344');
      expect(canonicalPersonIdentifier(phone, '911223344'), '0911223344');
      expect(canonicalPersonIdentifier(phone, '0911 22 33 44'), '0911223344');
      expect(canonicalPersonIdentifier(phone, ' - '), isNull);
    });

    test('keeps account digits and mask characters', () {
      const account = PersonIdentifierKind.bankAccount;
      expect(
          canonicalPersonIdentifier(account, '1000-1234 5678'), '100012345678');
      expect(
          canonicalPersonIdentifier(account, '1000xxxx5678'), '1000****5678');
      expect(canonicalPersonIdentifier(account, '****'), isNull);
    });
  });
}
