import 'package:flutter_test/flutter_test.dart';
import 'package:totals/models/account.dart';
import 'package:totals/models/bank.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/utils/unlabeled_accounts.dart';

final _cbe = Bank(
  id: 1,
  name: 'Commercial Bank of Ethiopia',
  shortName: 'CBE',
  codes: const ['CBE'],
  image: 'assets/images/cbe.png',
  maskPattern: 4,
  uniformMasking: true,
  simBased: false,
);

final _telebirr = Bank(
  id: 6,
  name: 'Telebirr',
  shortName: 'Telebirr',
  codes: const ['127'],
  image: 'assets/images/telebirr.png',
  maskPattern: 0,
  uniformMasking: false,
  simBased: true,
);

Transaction _tx(
  String reference, {
  int bankId = 1,
  String? accountNumber,
  String? time,
  String? currentBalance,
}) {
  return Transaction(
    amount: 100,
    reference: reference,
    bankId: bankId,
    type: 'DEBIT',
    accountNumber: accountNumber,
    time: time,
    currentBalance: currentBalance,
    isUnlabeled: true,
  );
}

Account _account(
  String number, {
  int bank = 1,
  String holder = 'Abebe Kebede',
  bool isDefault = false,
}) {
  return Account(
    accountNumber: number,
    bank: bank,
    balance: 0,
    accountHolderName: holder,
    isDefault: isDefault,
  );
}

void main() {
  final banksById = {_cbe.id: _cbe, _telebirr.id: _telebirr};

  group('buildUnlabeledAccountGroups', () {
    test('merges masked variants of one account and sorts by count', () {
      final groups = buildUnlabeledAccountGroups(
        [
          _tx('a1', accountNumber: '1000123456789'),
          _tx('a2', accountNumber: '1*****6789'),
          _tx('a3', accountNumber: '1000*****6789'),
          _tx('b1', accountNumber: '1000987654321'),
          _tx('t1', bankId: 6, accountNumber: '0911223344'),
          _tx('t2', bankId: 6, accountNumber: '0922334455'),
          _tx('x1', bankId: 99, accountNumber: '123'),
        ],
        banksById: banksById,
      );

      expect(groups.map((group) => group.count), [3, 2, 1]);
      expect(groups[0].bankId, 1);
      expect(groups[0].accountNumber, '1000123456789');
      expect(
        groups[0].transactions.map((t) => t.reference),
        ['a1', 'a2', 'a3'],
      );
      // SIM wallets report counterparty numbers, so they form one group.
      expect(groups[1].bankId, 6);
      expect(groups[1].accountNumber, isNull);
      expect(groups[2].accountNumber, '1000987654321');
    });

    test('keeps rows without a parsed number in their own group', () {
      final groups = buildUnlabeledAccountGroups(
        [
          _tx('a1', accountNumber: '1000123456789'),
          _tx('n1'),
          _tx('n2', accountNumber: '  '),
        ],
        banksById: banksById,
      );

      expect(groups, hasLength(2));
      expect(groups.first.accountNumber, isNull);
      expect(groups.first.count, 2);
    });

    test('suggests the most frequent greeted holder name', () {
      final groups = buildUnlabeledAccountGroups(
        [
          _tx('a1', accountNumber: '1000123456789'),
          _tx('a2', accountNumber: '1000123456789'),
          _tx('a3', accountNumber: '1000123456789'),
        ],
        banksById: banksById,
        bodyByReference: const {
          'a1': 'Dear Abebe Kebede, your account has been debited.',
          'a2': 'Dear Abebe Kebede, your account has been credited.',
          'a3': 'Dear Customer, your account has been debited.',
        },
      );

      expect(groups.single.holderNameSuggestion, 'Abebe Kebede');
    });

    test('reports the time range and the newest balance', () {
      final group = buildUnlabeledAccountGroups(
        [
          _tx(
            'a1',
            accountNumber: '1000123456789',
            time: '2026-09-02T10:00:00.000',
            currentBalance: '1,500.00',
          ),
          _tx(
            'a2',
            accountNumber: '1000123456789',
            time: '2026-09-05T10:00:00.000',
            currentBalance: 'ETB 2,250.50',
          ),
          _tx(
            'a3',
            accountNumber: '1000123456789',
            time: '2026-09-07T10:00:00.000',
          ),
        ],
        banksById: banksById,
      ).single;

      expect(group.firstTime, DateTime(2026, 9, 2, 10));
      expect(group.lastTime, DateTime(2026, 9, 7, 10));
      expect(group.latestBalance, closeTo(2250.50, 0.001));
    });
  });

  group('assignUnlabeledTransactions', () {
    test('assigns rows by account number and leaves others unlabeled', () {
      final assignments = assignUnlabeledTransactions(
        bank: _cbe,
        accounts: [_account('1000123456789')],
        transactions: [
          _tx('a1', accountNumber: '1*****6789'),
          _tx('a2', accountNumber: '1000123456789'),
          _tx('b1', accountNumber: '1000987654321'),
          _tx('t1', bankId: 6, accountNumber: '0911223344'),
        ],
      );

      expect(assignments, {
        '1000123456789': ['a1', 'a2'],
      });
    });

    test('a greeting naming someone else vetoes the number match', () {
      final assignments = assignUnlabeledTransactions(
        bank: _cbe,
        accounts: [_account('1000123456789')],
        transactions: [
          _tx('a1', accountNumber: '1000123456789'),
          _tx('a2', accountNumber: '1000123456789'),
        ],
        bodyByReference: const {
          'a1': 'Dear Abebe Kebede, your Account 1*****6789 has been '
              'debited.',
          'a2': 'Dear Sara Haile, your Account 1*****6789 has been '
              'debited.',
        },
      );

      expect(assignments, {
        '1000123456789': ['a1'],
      });
    });

    test('SIM wallets fall back to the single default account', () {
      final rows = [
        _tx('t1', bankId: 6, accountNumber: '0911223344'),
        _tx('t2', bankId: 6),
      ];

      expect(
        assignUnlabeledTransactions(
          bank: _telebirr,
          accounts: [_account('0911223344', bank: 6)],
          transactions: rows,
        ),
        isEmpty,
      );
      expect(
        assignUnlabeledTransactions(
          bank: _telebirr,
          accounts: [_account('0911000000', bank: 6, isDefault: true)],
          transactions: rows,
        ),
        {
          '0911000000': ['t1', 't2'],
        },
      );
    });

    test('the default account does not claim another parsed number', () {
      expect(
        assignUnlabeledTransactions(
          bank: _cbe,
          accounts: [_account('1000123456789', isDefault: true)],
          transactions: [
            _tx('a1', accountNumber: '1000987654321'),
            _tx('a2'),
          ],
        ),
        {
          '1000123456789': ['a2'],
        },
      );
    });

    test('returns nothing when the bank has no account', () {
      expect(
        assignUnlabeledTransactions(
          bank: _cbe,
          accounts: [_account('0911000000', bank: 6)],
          transactions: [_tx('a1', accountNumber: '1000123456789')],
        ),
        isEmpty,
      );
    });
  });

  test('latestReportedBalance ignores rows without a balance', () {
    expect(latestReportedBalance(const []), isNull);
    expect(
      latestReportedBalance([
        _tx('a1', time: '2026-09-01T00:00:00.000', currentBalance: '10'),
        _tx('a2', time: '2026-09-03T00:00:00.000', currentBalance: 'n/a'),
        _tx('a3', time: '2026-09-02T00:00:00.000', currentBalance: '20'),
      ]),
      20,
    );
  });
}
