import 'package:totals/constants/cash_constants.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/utils/sms_message_classifier.dart';
import 'package:totals/utils/transaction_amounts.dart';

/// Tolerance for comparing currency amounts stored as doubles.
const double atmCashAmountEpsilon = 0.005;

/// How far back a new cash spend looks for a withdrawal to draw from.
const Duration atmCashFundingLookback = Duration(days: 60);

final RegExp _atmWord = RegExp(r'\batm\b', caseSensitive: false);
final RegExp _cashWithdrawal = RegExp(
  r'withdraw|cash\s+(?:out|of)',
  caseSensitive: false,
);

/// Whether a parsed bank message is an ATM cash withdrawal.
///
/// [description] is the matched SMS pattern's description, and [body] the
/// raw message. [fallbackText] covers stored transactions whose source SMS
/// is gone, such as the parsed receiver or creditor.
bool looksLikeAtmWithdrawal({
  required String? type,
  String? description,
  String? body,
  Iterable<String?> fallbackText = const <String?>[],
}) {
  if ((type ?? '').trim().toUpperCase() != 'DEBIT') return false;

  final text = body?.trim() ?? '';
  // Telebirr's secret-code notice comes before any money moves.
  if (text.isNotEmpty &&
      SmsMessageClassifier.isTelebirrAtmAuthorization(text)) {
    return false;
  }
  final pattern = description?.toLowerCase() ?? '';
  if (pattern.contains('secret code')) return false;
  if (_atmWord.hasMatch(pattern)) return true;

  if (text.isNotEmpty) {
    return _atmWord.hasMatch(text) && _cashWithdrawal.hasMatch(text);
  }
  return fallbackText.any((value) => value != null && _atmWord.hasMatch(value));
}

/// The Cash Wallet credit mirroring the bank ATM [withdrawal]. The cash
/// pocket's balance after it is [cashBalanceAfter].
Transaction buildAtmCashLeg(
  Transaction withdrawal, {
  required double cashBalanceAfter,
}) {
  return Transaction(
    amount: withdrawal.amount,
    reference: CashConstants.buildAtmReference(withdrawal.reference),
    creditor: 'ATM withdrawal',
    time: withdrawal.time ?? DateTime.now().toIso8601String(),
    bankId: CashConstants.bankId,
    type: 'CREDIT',
    currentBalance: cashBalanceAfter.toStringAsFixed(2),
    transactionLink: withdrawal.reference,
    accountNumber: CashConstants.defaultAccountNumber,
    ownerAccountNumber: CashConstants.defaultAccountNumber,
    profileId: withdrawal.profileId,
  );
}

/// Whether [transaction] is the Cash Wallet credit created for an ATM
/// withdrawal.
bool isAtmCashLeg(Transaction transaction) {
  return transaction.bankId == CashConstants.bankId &&
      transaction.reference.startsWith(CashConstants.atmReferencePrefix);
}

/// The bank withdrawal reference behind an ATM cash leg reference, or null
/// when [reference] is not one.
String? atmWithdrawalReferenceForCashLeg(String reference) {
  if (!reference.startsWith(CashConstants.atmReferencePrefix)) return null;
  final withdrawal =
      reference.substring(CashConstants.atmReferencePrefix.length).trim();
  return withdrawal.isEmpty ? null : withdrawal;
}

/// Bank withdrawal references whose Cash Wallet leg exists in
/// [transactions]. Those withdrawals only move money into the cash pocket,
/// so they are not spending.
Set<String> atmLinkedWithdrawalReferences(
  Iterable<Transaction> transactions,
) {
  final references = <String>{};
  for (final transaction in transactions) {
    if (!isAtmCashLeg(transaction)) continue;
    final reference = atmWithdrawalReferenceForCashLeg(transaction.reference);
    if (reference != null) references.add(reference);
  }
  return references;
}

/// Cash spends drawing from the ATM cash leg [cashLegReference].
List<Transaction> cashSpendsFundedBy(
  String cashLegReference,
  Iterable<Transaction> transactions,
) {
  return transactions
      .where(
        (transaction) =>
            transaction.type == 'DEBIT' &&
            transaction.fundingReference == cashLegReference,
      )
      .toList(growable: false);
}

/// Cash left from [cashLeg] after the spends in [transactions] linked to it.
/// Never negative.
double atmCashRemaining(
  Transaction cashLeg,
  Iterable<Transaction> transactions, {
  String? excludingReference,
}) {
  final spent = cashSpendsFundedBy(cashLeg.reference, transactions)
      .where((spend) => spend.reference != excludingReference)
      .fold<double>(0.0, (sum, spend) => sum + transactionDebitOutflow(spend));
  final remaining = cashLeg.amount.abs() - spent;
  return remaining <= atmCashAmountEpsilon ? 0.0 : remaining;
}

/// ATM cash legs in [transactions] that [spend] could draw from: withdrawn
/// at or before the spend, newest first.
List<Transaction> atmFundingCandidates(
  Transaction spend,
  Iterable<Transaction> transactions,
) {
  final spendTime = DateTime.tryParse(spend.time ?? '');
  final candidates = <MapEntry<Transaction, DateTime>>[];
  for (final transaction in transactions) {
    if (!isAtmCashLeg(transaction) || transaction.type != 'CREDIT') continue;
    final time = DateTime.tryParse(transaction.time ?? '');
    if (time == null) continue;
    if (spendTime != null && time.isAfter(spendTime)) continue;
    candidates.add(MapEntry(transaction, time));
  }
  candidates.sort((a, b) => b.value.compareTo(a.value));
  return candidates.map((entry) => entry.key).toList(growable: false);
}

/// Picks the withdrawal that funds [spend], first in first out: the oldest
/// ATM cash leg within [lookback] of the spend that still has cash left.
Transaction? pickAtmFundingSource(
  Transaction spend,
  Iterable<Transaction> transactions, {
  Duration lookback = atmCashFundingLookback,
}) {
  if (spend.bankId != CashConstants.bankId || spend.type != 'DEBIT') {
    return null;
  }
  final all = transactions.toList(growable: false);
  final spendTime = DateTime.tryParse(spend.time ?? '') ?? DateTime.now();
  final earliest = spendTime.subtract(lookback);
  final candidates = atmFundingCandidates(spend, all).reversed;
  for (final candidate in candidates) {
    final time = DateTime.tryParse(candidate.time ?? '');
    if (time == null || time.isBefore(earliest)) continue;
    final remaining = atmCashRemaining(
      candidate,
      all,
      excludingReference: spend.reference,
    );
    if (remaining > atmCashAmountEpsilon) return candidate;
  }
  return null;
}
