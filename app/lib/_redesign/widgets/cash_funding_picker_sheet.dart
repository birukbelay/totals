import 'package:flutter/material.dart';
import 'package:totals/_redesign/theme/app_colors.dart';
import 'package:totals/_redesign/theme/app_icons.dart';
import 'package:totals/l10n/app_localizations.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/providers/transaction_provider.dart';
import 'package:totals/utils/app_date_format.dart';
import 'package:totals/utils/text_utils.dart';

/// Result of [showCashFundingPickerSheet]. A null [cashLeg] means the user
/// removed the link.
class CashFundingChoice {
  final Transaction? cashLeg;

  const CashFundingChoice(this.cashLeg);
}

/// Lets the user pick which ATM withdrawal paid for the cash [spend].
Future<CashFundingChoice?> showCashFundingPickerSheet({
  required BuildContext context,
  required Transaction spend,
  required TransactionProvider provider,
}) {
  return showModalBottomSheet<CashFundingChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CashFundingPickerSheet(spend: spend, provider: provider),
  );
}

class _CashFundingPickerSheet extends StatelessWidget {
  final Transaction spend;
  final TransactionProvider provider;

  const _CashFundingPickerSheet({
    required this.spend,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    final options = provider.atmFundingOptionsFor(spend);
    final selected = spend.fundingReference;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: AppColors.cardColor(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10nText('Paid with cash from'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      AppIcons.remove_circle_outline,
                      color: AppColors.textSecondary(context),
                    ),
                    title: Text(context.l10nText('No link')),
                    trailing: selected == null
                        ? const Icon(
                            AppIcons.check_rounded,
                            color: AppColors.primaryLight,
                          )
                        : null,
                    onTap: () => Navigator.pop(
                      context,
                      const CashFundingChoice(null),
                    ),
                  ),
                  if (options.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        context.l10nText(
                          'No ATM withdrawals before this spend.',
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ),
                  for (final option in options)
                    _FundingOptionTile(
                      cashLeg: option,
                      remaining: provider.remainingCashFor(option),
                      selected: option.reference == selected,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FundingOptionTile extends StatelessWidget {
  final Transaction cashLeg;
  final double remaining;
  final bool selected;

  const _FundingOptionTile({
    required this.cashLeg,
    required this.remaining,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final time = DateTime.tryParse(cashLeg.time ?? '');
    final date = time == null
        ? context.l10nText('Unknown date')
        : AppDateFormat.monthDayMaybeYear(time, context: context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(
        AppIcons.account_balance_wallet_outlined,
        color: AppColors.primaryLight,
      ),
      title: Text(
        '${context.l10nText('ATM withdrawal')} · '
        'ETB ${formatNumberWithComma(cashLeg.amount)}',
      ),
      subtitle: Text(
        '$date · ${context.l10nText('Left')} '
        'ETB ${formatNumberWithComma(remaining)}',
      ),
      trailing: selected
          ? const Icon(AppIcons.check_rounded, color: AppColors.primaryLight)
          : null,
      onTap: () => Navigator.pop(context, CashFundingChoice(cashLeg)),
    );
  }
}
