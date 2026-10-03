import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:totals/_redesign/theme/app_colors.dart';
import 'package:totals/_redesign/theme/app_icons.dart';
import 'package:totals/_redesign/widgets/person_picker_sheet.dart';
import 'package:totals/l10n/app_localizations.dart';
import 'package:totals/models/category.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/models/transaction_split.dart';
import 'package:totals/providers/transaction_provider.dart';
import 'package:totals/utils/category_icons.dart';
import 'package:totals/utils/category_sort.dart';
import 'package:totals/utils/category_style.dart';
import 'package:totals/utils/split_amounts.dart';
import 'package:totals/utils/text_utils.dart';

/// Opens the split editor for [transaction]. Returns true when splits were
/// saved or removed.
Future<bool?> showSplitTransactionSheet({
  required BuildContext context,
  required Transaction transaction,
  required TransactionProvider provider,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SplitTransactionSheet(
      transaction: transaction,
      provider: provider,
    ),
  );
}

class SplitTransactionSheet extends StatefulWidget {
  final Transaction transaction;
  final TransactionProvider provider;

  const SplitTransactionSheet({
    super.key,
    required this.transaction,
    required this.provider,
  });

  @override
  State<SplitTransactionSheet> createState() => _SplitTransactionSheetState();
}

class _SplitDraft {
  final int? id;
  final DateTime? createdAt;
  TransactionSplitKind kind;
  int? categoryId;
  int? personId;
  TransactionSplitStatus status;
  final TextEditingController amount;

  _SplitDraft({
    this.id,
    this.createdAt,
    this.kind = TransactionSplitKind.expense,
    this.categoryId,
    this.personId,
    this.status = TransactionSplitStatus.pending,
    String amountText = '',
  }) : amount = TextEditingController(text: amountText);

  factory _SplitDraft.fromSplit(TransactionSplit split) {
    return _SplitDraft(
      id: split.id,
      createdAt: split.createdAt,
      kind: split.kind,
      categoryId: split.categoryId,
      personId: split.personId,
      status: split.status ?? TransactionSplitStatus.pending,
      amountText: _formatAmountInput(split.amount),
    );
  }

  double get parsedAmount =>
      double.tryParse(amount.text.replaceAll(',', '').trim()) ?? 0.0;
}

String _formatAmountInput(double amount) {
  final fixed = amount.toStringAsFixed(2);
  return fixed.endsWith('.00') ? fixed.substring(0, fixed.length - 3) : fixed;
}

class _SplitTransactionSheetState extends State<SplitTransactionSheet> {
  late final List<_SplitDraft> _drafts;
  late final bool _hadSplits;
  bool _saving = false;

  Transaction get _tx => widget.transaction;

  TransactionProvider get _provider => widget.provider;

  double get _total => splitAllocatableAmount(_tx);

  double get _allocated =>
      _drafts.fold<double>(0.0, (sum, draft) => sum + draft.parsedAmount);

  double get _remaining => _total - _allocated;

  bool get _overAllocated => _remaining < -splitAmountEpsilon;

  @override
  void initState() {
    super.initState();
    final existing = _provider.splitsForTransaction(_tx);
    _hadSplits = existing.isNotEmpty;
    _drafts = existing.map(_SplitDraft.fromSplit).toList();
    if (_drafts.isEmpty) {
      _drafts.add(_SplitDraft(categoryId: _tx.categoryId));
    }
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.amount.dispose();
    }
    super.dispose();
  }

  String? _validationMessage() {
    for (final draft in _drafts) {
      if (draft.parsedAmount <= 0) {
        return 'Enter an amount for every part';
      }
      if (draft.kind.isOwedByPerson && draft.personId == null) {
        return 'Pick a person for every loan or bill share';
      }
    }
    if (_overAllocated) return 'Parts add up to more than the transaction';
    return null;
  }

  void _addDraft(TransactionSplitKind kind) {
    setState(() {
      _drafts.add(
        _SplitDraft(
          kind: kind,
          amountText: _remaining > splitAmountEpsilon
              ? _formatAmountInput(_remaining)
              : '',
        ),
      );
    });
  }

  void _removeDraft(_SplitDraft draft) {
    setState(() => _drafts.remove(draft));
    draft.amount.dispose();
  }

  void _splitEvenly() {
    final shares = _drafts
        .where((draft) => draft.kind == TransactionSplitKind.billShare)
        .toList(growable: false);
    if (shares.isEmpty) return;
    final own = _drafts
        .where((draft) => draft.kind != TransactionSplitKind.billShare)
        .fold<double>(0.0, (sum, draft) => sum + draft.parsedAmount);
    final share = evenBillShare(_total - own, shares.length);
    setState(() {
      for (final draft in shares) {
        draft.amount.text = _formatAmountInput(share);
      }
    });
  }

  Future<void> _pickPerson(_SplitDraft draft) async {
    final result = await showPersonPickerSheet(
      context: context,
      people: _provider.people,
      selectedPersonId: draft.personId,
    );
    if (result == null || !mounted) return;
    setState(() {
      draft.personId = result.cleared ? null : result.person?.id;
    });
  }

  Future<void> _pickCategory(_SplitDraft draft) async {
    final categories = sortCategoriesAlphabetically(
      _provider.categories.where((category) => category.flow == 'expense'),
    );
    final result = await showModalBottomSheet<_CategoryChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SplitCategoryPicker(
        categories: categories,
        selectedId: draft.categoryId,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => draft.categoryId = result.categoryId);
  }

  Future<void> _save({bool clear = false}) async {
    if (_saving) return;
    final now = DateTime.now();
    final splits = clear
        ? const <TransactionSplit>[]
        : _drafts
            .map(
              (draft) => TransactionSplit(
                id: draft.id,
                parentReference: _tx.reference,
                amount: draft.parsedAmount,
                categoryId: draft.kind.isOwedByPerson ? null : draft.categoryId,
                personId: draft.kind.isOwedByPerson ? draft.personId : null,
                kind: draft.kind,
                status: draft.kind.isOwedByPerson ? draft.status : null,
                createdAt: draft.createdAt ?? now,
                updatedAt: now,
              ),
            )
            .toList(growable: false);
    setState(() => _saving = true);
    try {
      await _provider.saveTransactionSplits(_tx, splits);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ArgumentError catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${error.message}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.88;
    final validation = _validationMessage();
    final hasBillShares =
        _drafts.any((draft) => draft.kind == TransactionSplitKind.billShare);

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10nText('Split transaction'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary(context),
                      ),
                    ),
                  ),
                  Text(
                    'ETB ${formatNumberWithComma(_total)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _RemainingBar(
                total: _total,
                allocated: _allocated,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _drafts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final draft = _drafts[index];
                    return _SplitDraftCard(
                      draft: draft,
                      category: _provider.getCategoryById(draft.categoryId),
                      personName: _personName(draft.personId),
                      onKindChanged: (kind) =>
                          setState(() => draft.kind = kind),
                      onPickCategory: () => _pickCategory(draft),
                      onPickPerson: () => _pickPerson(draft),
                      onAmountChanged: () => setState(() {}),
                      onStatusChanged: (status) =>
                          setState(() => draft.status = status),
                      onRemove: () => _removeDraft(draft),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ActionChip(
                    icon: AppIcons.category,
                    label: context.l10nText('Add category part'),
                    onTap: () => _addDraft(TransactionSplitKind.expense),
                  ),
                  _ActionChip(
                    icon: AppIcons.person_outline,
                    label: context.l10nText('Add loan'),
                    onTap: () => _addDraft(TransactionSplitKind.loan),
                  ),
                  _ActionChip(
                    icon: AppIcons.group_outlined,
                    label: context.l10nText('Add bill share'),
                    onTap: () => _addDraft(TransactionSplitKind.billShare),
                  ),
                  if (hasBillShares)
                    _ActionChip(
                      icon: AppIcons.call_split,
                      label: context.l10nText('Split evenly'),
                      onTap: _splitEvenly,
                    ),
                ],
              ),
              if (validation != null && _drafts.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  context.l10nText(validation),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.red,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_hadSplits)
                    Expanded(
                      child: TextButton(
                        onPressed: _saving ? null : () => _save(clear: true),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.red,
                        ),
                        child: Text(context.l10nText('Remove split')),
                      ),
                    ),
                  if (_hadSplits) const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed:
                          _saving || (validation != null && _drafts.isNotEmpty)
                              ? null
                              : () => _save(),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primaryLight,
                        foregroundColor: AppColors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(context.l10nText('Save split')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _personName(int? personId) {
    if (personId == null) return null;
    for (final person in _provider.people) {
      if (person.id == personId) return person.name;
    }
    return null;
  }
}

class _RemainingBar extends StatelessWidget {
  final double total;
  final double allocated;

  const _RemainingBar({required this.total, required this.allocated});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = total - allocated;
    final over = remaining < -splitAmountEpsilon;
    final progress =
        total <= 0 ? 0.0 : (allocated / total).clamp(0.0, 1.0).toDouble();
    final color = over ? AppColors.red : AppColors.primaryLight;
    final label = over
        ? '${context.l10nText('Over by')} ETB '
            '${formatNumberWithComma(-remaining)}'
        : '${context.l10nText('Remaining')} ETB '
            '${formatNumberWithComma(remaining.clamp(0.0, total))}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            color: color,
            backgroundColor: AppColors.mutedFill(context),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: over ? AppColors.red : AppColors.textSecondary(context),
            fontWeight: FontWeight.w600,
          ),
        ),
        if (!over && remaining > splitAmountEpsilon)
          Text(
            context.l10nText('The remaining amount keeps the main category.'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textTertiary(context),
            ),
          ),
      ],
    );
  }
}

class _SplitDraftCard extends StatelessWidget {
  final _SplitDraft draft;
  final Category? category;
  final String? personName;
  final ValueChanged<TransactionSplitKind> onKindChanged;
  final VoidCallback onPickCategory;
  final VoidCallback onPickPerson;
  final VoidCallback onAmountChanged;
  final ValueChanged<TransactionSplitStatus> onStatusChanged;
  final VoidCallback onRemove;

  const _SplitDraftCard({
    required this.draft,
    required this.category,
    required this.personName,
    required this.onKindChanged,
    required this.onPickCategory,
    required this.onPickPerson,
    required this.onAmountChanged,
    required this.onStatusChanged,
    required this.onRemove,
  });

  static const _kindLabels = {
    TransactionSplitKind.expense: 'Category',
    TransactionSplitKind.loan: 'Loan',
    TransactionSplitKind.billShare: 'Bill share',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owed = draft.kind.isOwedByPerson;
    final target = owed
        ? (personName ?? context.l10nText('Pick person'))
        : (category?.name ?? context.l10nText('Main category'));

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final kind in TransactionSplitKind.values)
                      ChoiceChip(
                        label: Text(context.l10nText(_kindLabels[kind]!)),
                        selected: draft.kind == kind,
                        onSelected: (_) => onKindChanged(kind),
                        visualDensity: VisualDensity.compact,
                        showCheckmark: false,
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(AppIcons.close_rounded, size: 18),
                color: AppColors.textSecondary(context),
                tooltip: context.l10nText('Remove'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: owed ? onPickPerson : onPickCategory,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.borderColor(context)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          owed
                              ? AppIcons.person_outline
                              : iconForCategoryKey(category?.iconKey),
                          size: 16,
                          color: owed || category == null
                              ? AppColors.textSecondary(context)
                              : categoryPaletteColor(category!),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            target,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppColors.textPrimary(context),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: draft.amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onChanged: (_) => onAmountChanged(),
                  textAlign: TextAlign.end,
                  decoration: InputDecoration(
                    hintText: '0.00',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (owed) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  context.l10nText('Status'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary(context),
                  ),
                ),
                const SizedBox(width: 8),
                for (final status in TransactionSplitStatus.values) ...[
                  ChoiceChip(
                    label: Text(
                      context.l10nText(
                        status == TransactionSplitStatus.paid
                            ? 'Paid back'
                            : 'Pending',
                      ),
                    ),
                    selected: draft.status == status,
                    onSelected: (_) => onStatusChanged(status),
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 16, color: AppColors.primaryLight),
      label: Text(label),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _CategoryChoice {
  final int? categoryId;

  const _CategoryChoice(this.categoryId);
}

class _SplitCategoryPicker extends StatelessWidget {
  final List<Category> categories;
  final int? selectedId;

  const _SplitCategoryPicker({
    required this.categories,
    required this.selectedId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

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
              context.l10nText('Pick category'),
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
                      AppIcons.category,
                      color: AppColors.textSecondary(context),
                    ),
                    title: Text(context.l10nText('Main category')),
                    trailing: selectedId == null
                        ? const Icon(
                            AppIcons.check_rounded,
                            color: AppColors.primaryLight,
                          )
                        : null,
                    onTap: () => Navigator.pop(
                      context,
                      const _CategoryChoice(null),
                    ),
                  ),
                  for (final category in categories)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        iconForCategoryKey(category.iconKey),
                        color: categoryPaletteColor(category),
                      ),
                      title: Text(category.name),
                      trailing: category.id == selectedId
                          ? const Icon(
                              AppIcons.check_rounded,
                              color: AppColors.primaryLight,
                            )
                          : null,
                      onTap: () => Navigator.pop(
                        context,
                        _CategoryChoice(category.id),
                      ),
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
