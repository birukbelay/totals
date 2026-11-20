import 'package:flutter_test/flutter_test.dart';
import 'package:totals/models/account.dart';
import 'package:totals/models/bank.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/utils/auto_accounts.dart';
import 'package:totals/utils/unlabeled_accounts.dart';

final _cbe = Bank(
  id: 1,
  name: 'Commercial Bank Of Ethiopia',
  shortName: 'CBE',
  codes: const <String>['CBE'],
  image: 'assets/images/cbe.png',
  maskPattern: 3,
  uniformMasking: true,
);

final _telebirr = Bank(
  id: 6,
  name: 'Telebirr',
  shortName: 'Telebirr',
  codes: const <String>['127'],
  image: 'assets/images/telebirr.png',
  maskPattern: 0,
  uniformMasking: false,
  simBased: true,
);

final _banksById = <int, Bank>{_cbe.id: _cbe, _telebirr.id: _telebirr};

void main() {
  test('adds one account per numbered group with its greeting name', () {
    final candidates = planAutoAccounts(
      groups: [
        _group(1, '1*****6789', ['a', 'b'], holder: 'Abebe'),
        _group(1, '1*****4321', ['c']),
      ],
      banksById: _banksById,
      accounts: const <Account>[],
    );

    expect(candidates.map((candidate) => candidate.accountNumber),
        ['1*****6789', '1*****4321']);
    expect(candidates.map((candidate) => candidate.accountHolderName),
        ['Abebe', 'CBE']);
  });

  test('keeps the number variant that reveals the most digits', () {
    final group = UnlabeledAccountGroup(
      bankId: 1,
      accountNumber: '1*****6789',
      transactions: [
        _transaction('a', bankId: 1, accountNumber: '1*****6789'),
        _transaction('b', bankId: 1, accountNumber: '1000123456789'),
      ],
    );

    final candidates = planAutoAccounts(
      groups: [group],
      banksById: _banksById,
      accounts: const <Account>[],
    );

    expect(candidates.single.accountNumber, '1000123456789');
  });

  test('skips numbers that an account already has', () {
    final candidates = planAutoAccounts(
      groups: [
        _group(1, '1*****6789', ['a'])
      ],
      banksById: _banksById,
      accounts: [
        Account(
          accountNumber: '1000123456789',
          bank: 1,
          balance: 0,
          accountHolderName: 'Abebe',
        ),
      ],
    );

    expect(candidates, isEmpty);
  });

  test('a group without a number is added only for a bank with no account', () {
    final candidates = planAutoAccounts(
      groups: [
        _group(1, null, ['a']),
        _group(1, '1*****6789', ['b']),
        _group(6, null, ['c'], holder: 'Abebe'),
      ],
      banksById: _banksById,
      accounts: const <Account>[],
    );

    expect(
      candidates.map((candidate) => '${candidate.bankId}:'
          '${candidate.accountNumber}'),
      ['1:1*****6789', '6:TELEBIRR'],
    );
    expect(candidates.last.accountHolderName, 'Abebe');
  });

  test('a wallet takes the number its messages call "your account"', () {
    final candidates = planAutoAccounts(
      groups: [
        _group(6, null, ['a', 'b', 'c'])
      ],
      banksById: _banksById,
      accounts: const <Account>[],
      bodyByReference: const {
        'a': 'You have received ETB 10 from Kebede (2519****1111) to your '
            'telebirr account 251912345678.',
        'b': 'You have received ETB 20 to your telebirr account '
            '251912345678.',
        'c': 'You have paid ETB 5 from your telebirr account 2519****5678.',
      },
    );

    expect(candidates.single.accountNumber, '0912345678');
  });

  test('skips keys of accounts added before', () {
    const first = AutoAccountCandidate(
      bankId: 6,
      accountNumber: 'TELEBIRR',
      accountHolderName: 'Telebirr',
    );
    final candidates = planAutoAccounts(
      groups: [
        _group(6, null, ['a']),
        _group(1, '1*****6789', ['b']),
      ],
      banksById: _banksById,
      accounts: const <Account>[],
      skipKeys: {first.key(_telebirr)},
    );

    expect(candidates.map((candidate) => candidate.bankId), [1]);
  });

  test('ignores cash and unknown banks', () {
    final candidates = planAutoAccounts(
      groups: [
        _group(100, null, ['a']),
        _group(42, '12345', ['b']),
      ],
      banksById: _banksById,
      accounts: const <Account>[],
    );

    expect(candidates, isEmpty);
  });
}

UnlabeledAccountGroup _group(
  int bankId,
  String? accountNumber,
  List<String> references, {
  String? holder,
}) {
  return UnlabeledAccountGroup(
    bankId: bankId,
    accountNumber: accountNumber,
    holderNameSuggestion: holder,
    transactions: [
      for (final reference in references)
        _transaction(
          reference,
          bankId: bankId,
          accountNumber: accountNumber,
        ),
    ],
  );
}

Transaction _transaction(
  String reference, {
  required int bankId,
  String? accountNumber,
}) {
  return Transaction(
    amount: 10,
    reference: reference,
    bankId: bankId,
    type: 'DEBIT',
    accountNumber: accountNumber,
  );
}
