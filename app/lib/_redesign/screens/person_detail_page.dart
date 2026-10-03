import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:totals/_redesign/screens/loans_page.dart';
import 'package:totals/_redesign/screens/people_page.dart';
import 'package:totals/_redesign/theme/app_colors.dart';
import 'package:totals/_redesign/theme/app_icons.dart';
import 'package:totals/_redesign/widgets/person_editor_sheet.dart';
import 'package:totals/_redesign/widgets/transaction_details_sheet.dart';
import 'package:totals/_redesign/widgets/transaction_tile.dart';
import 'package:totals/l10n/app_localizations.dart';
import 'package:totals/models/loan_debt_entry.dart';
import 'package:totals/models/person.dart';
import 'package:totals/models/transaction.dart';
import 'package:totals/providers/transaction_provider.dart';
import 'package:totals/repositories/person_repository.dart';
import 'package:totals/services/person_analytics_service.dart';
import 'package:totals/services/person_matcher_service.dart';
import 'package:totals/utils/app_date_format.dart';
import 'package:totals/utils/text_utils.dart';

class PersonDetailPage extends StatefulWidget {
  final int personId;

  const PersonDetailPage({super.key, required this.personId});

  @override
  State<PersonDetailPage> createState() => _PersonDetailPageState();
}

class _PersonDetailPageState extends State<PersonDetailPage> {
  final PersonRepository _repository = PersonRepository();
  List<PersonIdentifier> _identifiers = const [];

  @override
  void initState() {
    super.initState();
    _loadIdentifiers();
  }

  Future<void> _loadIdentifiers() async {
    final identifiers = await _repository.getIdentifiers(
      personId: widget.personId,
    );
    if (!mounted) return;
    setState(() => _identifiers = identifiers);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _edit(TransactionProvider provider, Person person) async {
    final saved = await showPersonEditorSheet(context: context, person: person);
    if (saved == null) return;
    await provider.refreshPeople();
  }

  Future<void> _delete(TransactionProvider provider, Person person) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10nText('Delete person?')),
        content: Text(
          context.l10nText(
            'Transactions and loans stay; they are just no longer linked '
            'to this person.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10nText('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: Text(context.l10nText('Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.deletePerson(person.id!);
    await provider.refreshPeople();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _merge(TransactionProvider provider, Person person) async {
    final candidates = provider.people
        .where((candidate) => candidate.id != person.id)
        .toList(growable: false);
    if (candidates.isEmpty) return;
    final target = await showDialog<Person>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(
          '${context.l10nText('Merge')} ${person.name} '
          '${context.l10nText('into')}',
        ),
        children: [
          for (final candidate in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, candidate),
              child: Text(candidate.name),
            ),
        ],
      ),
    );
    if (target == null) return;
    await _repository.mergePeople(sourceId: person.id!, targetId: target.id!);
    await provider.loadData();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PersonDetailPage(personId: target.id!),
      ),
    );
  }

  Future<void> _addIdentifier(TransactionProvider provider) async {
    final draft = await showDialog<_IdentifierDraft>(
      context: context,
      builder: (_) => _IdentifierDialog(banks: provider.bankShortNamesById),
    );
    if (draft == null) return;
    try {
      final identifier = await _repository.addIdentifier(
        personId: widget.personId,
        kind: draft.kind,
        value: draft.value,
        bankId: draft.bankId,
      );
      if (identifier == null) return;
    } on PersonIdentifierConflict catch (conflict) {
      if (!mounted) return;
      final owner = provider.personById(conflict.existing.personId)?.name;
      _showMessage(
        '${context.l10nTextRead('Already assigned to')} ${owner ?? '?'}',
      );
      return;
    }
    await _loadIdentifiers();
    final linked = await PersonMatcherService.instance.backfill();
    await provider.refreshPeople();
    if (!mounted || linked == 0) return;
    _showMessage(
      '${context.l10nTextRead('Matched')} $linked '
      '${context.l10nTextRead(linked == 1 ? 'transaction' : 'transactions')}',
    );
  }

  Future<void> _removeIdentifier(PersonIdentifier identifier) async {
    await _repository.deleteIdentifier(identifier.id!);
    await _loadIdentifiers();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer<TransactionProvider>(
      builder: (context, provider, _) {
        final person = provider.personById(widget.personId);
        if (person == null) {
          return Scaffold(
            backgroundColor: AppColors.background(context),
            appBar: AppBar(backgroundColor: AppColors.background(context)),
            body: Center(
              child: Text(context.l10nText('Person not found')),
            ),
          );
        }
        final stats = provider.peopleAnalytics.statsFor(widget.personId);
        final transactions = provider.transactionsForPerson(widget.personId)
          ..sort((a, b) => (b.time ?? '').compareTo(a.time ?? ''));
        final loans = provider.loanDebtEntriesForPerson(widget.personId);

        return Scaffold(
          backgroundColor: AppColors.background(context),
          appBar: AppBar(
            backgroundColor: AppColors.background(context),
            elevation: 0,
            title: Text(
              person.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
            actions: [
              IconButton(
                tooltip: context.l10nText('Edit'),
                icon: const Icon(AppIcons.tune),
                onPressed: () => _edit(provider, person),
              ),
              PopupMenuButton<String>(
                icon: const Icon(AppIcons.more_vert),
                onSelected: (value) {
                  if (value == 'merge') _merge(provider, person);
                  if (value == 'delete') _delete(provider, person);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'merge',
                    child: Text(context.l10nText('Merge into…')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(context.l10nText('Delete')),
                  ),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              _PersonHeader(person: person),
              const SizedBox(height: 16),
              _StatsGrid(stats: stats),
              const SizedBox(height: 20),
              _SectionTitle(
                title: context.l10nText('Accounts & phones'),
                actionLabel: context.l10nText('Add'),
                onAction: () => _addIdentifier(provider),
              ),
              if (_identifiers.isEmpty)
                _EmptyHint(
                  text: context.l10nText(
                    'Add their account numbers (or last digits) and phone '
                    'numbers so new SMS are assigned automatically.',
                  ),
                )
              else
                for (final identifier in _identifiers)
                  _IdentifierTile(
                    identifier: identifier,
                    bankLabel: identifier.bankId == null
                        ? null
                        : provider.getBankShortName(identifier.bankId),
                    onDelete: () => _removeIdentifier(identifier),
                  ),
              if (loans.isNotEmpty) ...[
                const SizedBox(height: 20),
                _SectionTitle(
                  title: context.l10nText('Loans & debts'),
                  actionLabel: context.l10nText('Open'),
                  onAction: () => openLoansPersonPage(
                    context: context,
                    personName: person.name,
                  ),
                ),
                for (final entry in loans)
                  _LoanTile(entry: entry, provider: provider),
              ],
              const SizedBox(height: 20),
              _SectionTitle(title: context.l10nText('Transactions')),
              if (transactions.isEmpty)
                _EmptyHint(
                  text: context.l10nText(
                    'No transactions assigned yet. Open a transaction and '
                    'set its person.',
                  ),
                )
              else
                for (final transaction in transactions)
                  _PersonTransactionTile(
                    transaction: transaction,
                    provider: provider,
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _PersonHeader extends StatelessWidget {
  final Person person;

  const _PersonHeader({required this.person});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = personTypeColor(person.type);
    return Row(
      children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(AppIcons.person, color: color),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10nText(personTypeLabel(person.type)),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (person.telegramHandle != null)
                Text(
                  '@${person.telegramHandle}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary(context),
                  ),
                ),
              if (person.note != null)
                Text(
                  person.note!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary(context),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final PersonStats stats;

  const _StatsGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final currency = context.l10nText('ETB');
    String money(double value) => '$currency ${formatNumberWithComma(value)}';
    final cards = <Widget>[
      _StatCard(
        label: context.l10nText('Spent'),
        value: money(stats.spent),
        color: AppColors.red,
      ),
      _StatCard(
        label: context.l10nText('Received'),
        value: money(stats.received),
        color: AppColors.incomeSuccess,
      ),
      _StatCard(
        label: context.l10nText('Owes you'),
        value: money(stats.lentOutstanding),
        detail: stats.lent > 0
            ? '${context.l10nText('of')} ${formatNumberWithComma(stats.lent)} '
                '${context.l10nText('lent')}'
            : null,
        color: AppColors.amber,
      ),
      _StatCard(
        label: context.l10nText('You owe'),
        value: money(stats.borrowedOutstanding),
        detail: stats.borrowed > 0
            ? '${context.l10nText('of')} '
                '${formatNumberWithComma(stats.borrowed)} '
                '${context.l10nText('borrowed')}'
            : null,
        color: AppColors.primaryLight,
      ),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.9,
      children: cards,
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? detail;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardColor(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
          if (detail != null)
            Text(
              detail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.textTertiary(context),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _SectionTitle({required this.title, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
          ),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary(context),
            ),
      ),
    );
  }
}

class _IdentifierTile extends StatelessWidget {
  final PersonIdentifier identifier;
  final String? bankLabel;
  final VoidCallback onDelete;

  const _IdentifierTile({
    required this.identifier,
    required this.onDelete,
    this.bankLabel,
  });

  @override
  Widget build(BuildContext context) {
    final isPhone = identifier.kind == PersonIdentifierKind.phone;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        isPhone ? AppIcons.phone_iphone_rounded : AppIcons.account_balance,
        color: AppColors.textSecondary(context),
      ),
      title: Text(identifier.value),
      subtitle: Text(
        isPhone
            ? context.l10nText('Phone')
            : bankLabel == null
                ? context.l10nText('Any bank')
                : context.l10nText(bankLabel!),
      ),
      trailing: IconButton(
        icon: const Icon(AppIcons.delete_outline_rounded, size: 18),
        onPressed: onDelete,
      ),
    );
  }
}

class _LoanTile extends StatelessWidget {
  final LoanDebtEntry entry;
  final TransactionProvider provider;

  const _LoanTile({required this.entry, required this.provider});

  @override
  Widget build(BuildContext context) {
    final isLent = entry.direction == LoanDebtDirection.lent;
    final transaction = provider.allTransactions.where(
      (transaction) =>
          transaction.reference.trim() == entry.transactionReference.trim(),
    );
    final amount = entry.principalAmount ??
        (transaction.isEmpty ? null : transaction.first.amount);
    final statusLabel = switch (entry.status) {
      LoanDebtStatus.active => 'Active',
      LoanDebtStatus.settled => 'Settled',
      LoanDebtStatus.forgiven => 'Forgiven',
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        AppIcons.debts,
        color: isLent ? AppColors.amber : AppColors.primaryLight,
      ),
      title: Text(context.l10nText(isLent ? 'Lent' : 'Borrowed')),
      subtitle: Text(
        '${context.l10nText(statusLabel)} · '
        '${AppDateFormat.monthDayMaybeYear(entry.createdAt, context: context)}',
      ),
      trailing: amount == null
          ? null
          : Text(
              '${context.l10nText('ETB')} ${formatNumberWithComma(amount)}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
    );
  }
}

class _PersonTransactionTile extends StatelessWidget {
  final Transaction transaction;
  final TransactionProvider provider;

  const _PersonTransactionTile({
    required this.transaction,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final isCredit = transaction.type == 'CREDIT';
    final categories = provider.categoriesForTransaction(transaction);
    final time = DateTime.tryParse(transaction.time ?? '')?.toLocal();
    final counterparty = (isCredit
                ? transaction.creditor ?? transaction.receiver
                : transaction.receiver ?? transaction.creditor)
            ?.trim() ??
        '';
    return TransactionTile(
      bank: context.l10nText(provider.getBankShortName(transaction.bankId)),
      category: provider.categoryLabelForTransaction(
        transaction,
        uncategorizedLabel: context.l10nText('Uncategorized'),
      ),
      categoryModel: categories.isEmpty ? null : categories.first,
      isCategorized: categories.isNotEmpty,
      isDebit: !isCredit,
      isSelfTransfer: provider.isSelfTransfer(transaction),
      isReimbursed: provider.isReimbursedExpense(transaction),
      amount: '${isCredit ? '+' : '-'} ${context.l10nText('ETB')} '
          '${formatNumberWithComma(transaction.amount)}',
      amountColor: isCredit ? AppColors.incomeSuccess : AppColors.red,
      name: counterparty.isEmpty
          ? context.l10nText('Unknown')
          : counterparty.toUpperCase(),
      timestamp: time == null
          ? null
          : AppDateFormat.monthDayMaybeYear(time, context: context),
      onTap: () => showTransactionDetailsSheet(
        context: context,
        transaction: transaction,
        provider: provider,
      ),
    );
  }
}

class _IdentifierDraft {
  final PersonIdentifierKind kind;
  final String value;
  final int? bankId;

  const _IdentifierDraft({
    required this.kind,
    required this.value,
    this.bankId,
  });
}

class _IdentifierDialog extends StatefulWidget {
  final Map<int, String> banks;

  const _IdentifierDialog({required this.banks});

  @override
  State<_IdentifierDialog> createState() => _IdentifierDialogState();
}

class _IdentifierDialogState extends State<_IdentifierDialog> {
  final TextEditingController _controller = TextEditingController();
  PersonIdentifierKind _kind = PersonIdentifierKind.bankAccount;
  int? _bankId;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (canonicalPersonIdentifier(_kind, value) == null) return;
    Navigator.pop(
      context,
      _IdentifierDraft(
        kind: _kind,
        value: value,
        bankId: _kind == PersonIdentifierKind.phone ? null : _bankId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bankEntries = widget.banks.entries.toList(growable: false)
      ..sort((a, b) => a.value.compareTo(b.value));
    final isPhone = _kind == PersonIdentifierKind.phone;
    return AlertDialog(
      title: Text(context.l10nText('Add account or phone')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<PersonIdentifierKind>(
            segments: [
              ButtonSegment(
                value: PersonIdentifierKind.bankAccount,
                label: Text(context.l10nText('Account')),
              ),
              ButtonSegment(
                value: PersonIdentifierKind.phone,
                label: Text(context.l10nText('Phone')),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (selection) =>
                setState(() => _kind = selection.single),
          ),
          const SizedBox(height: 12),
          if (!isPhone)
            DropdownButtonFormField<int?>(
              initialValue: _bankId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.l10nText('Bank'),
              ),
              items: [
                DropdownMenuItem<int?>(
                  value: null,
                  child: Text(context.l10nText('Any bank')),
                ),
                for (final entry in bankEntries)
                  DropdownMenuItem<int?>(
                    value: entry.key,
                    child: Text(context.l10nText(entry.value)),
                  ),
              ],
              onChanged: (value) => setState(() => _bankId = value),
            ),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: context.l10nText(
                isPhone ? 'Phone number' : 'Account number or last digits',
              ),
              hintText: isPhone ? '09…' : '1000…1234',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10nText('Cancel')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(context.l10nText('Add')),
        ),
      ],
    );
  }
}
