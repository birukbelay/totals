import 'package:flutter_test/flutter_test.dart';
import 'package:totals/constants/cash_constants.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/services/atm_cash_backfill_service.dart';
import 'package:totals/utils/atm_cash_transfers.dart';

Transaction _withdrawal(String reference, double amount, DateTime time) {
  return Transaction(
    amount: amount,
    reference: reference,
    time: time.toIso8601String(),
    type: 'DEBIT',
    bankId: 1,
    serviceCharge: 5,
    profileId: 7,
  );
}

Transaction _cashSpend(
  String reference,
  double amount,
  DateTime time, {
  String? fundingReference,
}) {
  return Transaction(
    amount: amount,
    reference: reference,
    time: time.toIso8601String(),
    type: 'DEBIT',
    bankId: CashConstants.bankId,
    fundingReference: fundingReference,
  );
}

void main() {
  group('looksLikeAtmWithdrawal', () {
    test('trusts a pattern described as ATM', () {
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          description: 'CBE ATM withdrawal',
        ),
        isTrue,
      );
    });

    test('only counts debits', () {
      expect(
        looksLikeAtmWithdrawal(
          type: 'CREDIT',
          description: 'CBE ATM withdrawal',
        ),
        isFalse,
      );
    });

    test('skips the Telebirr secret code notice', () {
      const body = 'Dear Customer, Your ATM withdraw secret code is 671826 '
          'with amount ETB 1,000.00.';
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          description: 'Telebirr ATM withdrawal',
          body: body,
        ),
        isFalse,
      );
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          description: 'Telebirr ATM withdraw secret code',
        ),
        isFalse,
      );
    });

    test('accepts the completed Telebirr withdrawal', () {
      const body = 'The request to withdraw ETB 1,000.00 from your telebirr '
          'account via secret code 671826 using Bank of Abyssinia ATM is '
          'successfully completed.';
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          description: 'Telebirr withdrawal',
          body: body,
        ),
        isTrue,
      );
    });

    test('needs ATM and a withdrawal in a generic body', () {
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          description: 'Awash debit',
          body: 'Your account has been debited with ETB 500 for a transfer.',
        ),
        isFalse,
      );
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          description: 'Awash debit',
          body: 'ETB 500 cash withdrawal at ATM BOLE-02 was made from your '
              'account.',
        ),
        isTrue,
      );
      // "atm" inside another word is not an ATM.
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          body: 'Withdrawal for treatment fees.',
        ),
        isFalse,
      );
    });

    test('falls back to stored text without a body', () {
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          fallbackText: const [null, 'ATM Bole'],
        ),
        isTrue,
      );
      expect(
        looksLikeAtmWithdrawal(
          type: 'DEBIT',
          fallbackText: const ['Abebe'],
        ),
        isFalse,
      );
    });
  });

  test('builds a cash leg linked to the withdrawal', () {
    final withdrawal = _withdrawal('FT1', 1000, DateTime(2026, 3, 1, 10));
    final leg = buildAtmCashLeg(withdrawal, cashBalanceAfter: 1250);

    expect(leg.reference, 'cash_atm_FT1');
    expect(leg.type, 'CREDIT');
    expect(leg.bankId, CashConstants.bankId);
    expect(leg.amount, 1000);
    expect(leg.currentBalance, '1250.00');
    expect(leg.transactionLink, 'FT1');
    expect(leg.time, withdrawal.time);
    expect(leg.profileId, 7);
    expect(isAtmCashLeg(leg), isTrue);
    expect(isAtmCashLeg(withdrawal), isFalse);
    expect(atmWithdrawalReferenceForCashLeg(leg.reference), 'FT1');
    expect(atmWithdrawalReferenceForCashLeg('FT1'), isNull);
    expect(atmWithdrawalReferenceForCashLeg('cash_atm_ '), isNull);
    expect(atmLinkedWithdrawalReferences([withdrawal, leg]), {'FT1'});
  });

  group('cash funding', () {
    final day = DateTime(2026, 3, 1, 10);
    final first = buildAtmCashLeg(
      _withdrawal('FT1', 500, day),
      cashBalanceAfter: 500,
    );
    final second = buildAtmCashLeg(
      _withdrawal('FT2', 300, day.add(const Duration(days: 2))),
      cashBalanceAfter: 800,
    );

    test('remaining cash subtracts linked spends and never goes negative', () {
      final transactions = [
        first,
        _cashSpend('C1', 200, day, fundingReference: first.reference),
        _cashSpend('C2', 100, day, fundingReference: second.reference),
      ];
      expect(atmCashRemaining(first, transactions), closeTo(300, 0.001));
      expect(
        atmCashRemaining(first, transactions, excludingReference: 'C1'),
        closeTo(500, 0.001),
      );
      expect(
        cashSpendsFundedBy(first.reference, transactions)
            .map((spend) => spend.reference),
        ['C1'],
      );

      final overspent = [
        _cashSpend('C3', 700, day, fundingReference: first.reference),
      ];
      expect(atmCashRemaining(first, overspent), 0);
    });

    test('candidates are withdrawals at or before the spend, newest first', () {
      final spend = _cashSpend('C1', 50, day.add(const Duration(days: 3)));
      final early = _cashSpend('C0', 50, day.add(const Duration(days: 1)));
      expect(
        atmFundingCandidates(spend, [first, second, spend])
            .map((leg) => leg.reference),
        [second.reference, first.reference],
      );
      expect(
        atmFundingCandidates(early, [first, second])
            .map((leg) => leg.reference),
        [first.reference],
      );
    });

    test('picks the oldest withdrawal with cash left', () {
      final spend = _cashSpend('C9', 100, day.add(const Duration(days: 3)));
      expect(
        pickAtmFundingSource(spend, [first, second])?.reference,
        first.reference,
      );

      final drained = [
        first,
        second,
        _cashSpend('C1', 500, day, fundingReference: first.reference),
      ];
      expect(
        pickAtmFundingSource(spend, drained)?.reference,
        second.reference,
      );
    });

    test('ignores old withdrawals and non-cash spends', () {
      final lateSpend =
          _cashSpend('C9', 100, day.add(const Duration(days: 90)));
      expect(pickAtmFundingSource(lateSpend, [first]), isNull);
      expect(
        pickAtmFundingSource(
          lateSpend,
          [first],
          lookback: const Duration(days: 100),
        )?.reference,
        first.reference,
      );

      final bankSpend =
          _withdrawal('FT9', 100, day.add(const Duration(days: 1)));
      expect(pickAtmFundingSource(bankSpend, [first]), isNull);
    });

    test('a spend already linked does not use up its own funding', () {
      final spend = _cashSpend(
        'C1',
        500,
        day.add(const Duration(hours: 1)),
        fundingReference: first.reference,
      );
      expect(
        pickAtmFundingSource(spend, [first, spend])?.reference,
        first.reference,
      );
    });
  });

  test('backfilled legs carry the running cash balance', () {
    final day = DateTime(2026, 3, 1, 10);
    final legs = buildBackfilledCashLegs(
      withdrawals: [
        _withdrawal('FT2', 300, day.add(const Duration(days: 2))),
        _withdrawal('FT1', 500, day),
      ],
      cashTransactions: [
        _cashSpend('C1', 200, day.add(const Duration(days: 1))),
      ],
      openingBalance: 100,
    );

    expect(legs.map((leg) => leg.reference), ['cash_atm_FT1', 'cash_atm_FT2']);
    // 100 + 500, then - 200 + 300.
    expect(legs.map((leg) => leg.currentBalance), ['600.00', '700.00']);
  });
}
