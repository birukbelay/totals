import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:totals/_redesign/screens/person_detail_page.dart';
import 'package:totals/_redesign/theme/app_colors.dart';
import 'package:totals/_redesign/theme/app_icons.dart';
import 'package:totals/_redesign/widgets/person_editor_sheet.dart';
import 'package:totals/l10n/app_localizations.dart';
import 'package:totals/models/person.dart';
import 'package:totals/providers/transaction_provider.dart';
import 'package:totals/services/person_analytics_service.dart';
import 'package:totals/utils/text_utils.dart';

/// English label for a [PersonType]; pass through `context.l10nText`.
String personTypeLabel(PersonType type) {
  switch (type) {
    case PersonType.friend:
      return 'Friend';
    case PersonType.family:
      return 'Family';
    case PersonType.shop:
      return 'Shop';
    case PersonType.restaurant:
      return 'Restaurant';
    case PersonType.service:
      return 'Service';
    case PersonType.employer:
      return 'Employer';
    case PersonType.other:
      return 'Other';
  }
}

Color personTypeColor(PersonType type) {
  switch (type) {
    case PersonType.friend:
      return AppColors.primaryLight;
    case PersonType.family:
      return AppColors.incomeSuccess;
    case PersonType.shop:
      return AppColors.blue;
    case PersonType.restaurant:
      return AppColors.amber;
    case PersonType.service:
      return AppColors.slate500;
    case PersonType.employer:
      return AppColors.primaryDark;
    case PersonType.other:
      return AppColors.slate400;
  }
}

class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key});

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  PersonType? _typeFilter;
  String _query = '';

  Future<void> _addPerson(TransactionProvider provider) async {
    final person = await showPersonEditorSheet(context: context);
    if (person == null || !mounted) return;
    await provider.refreshPeople();
    if (!mounted || person.id == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PersonDetailPage(personId: person.id!),
      ),
    );
  }

  void _openPerson(int personId) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PersonDetailPage(personId: personId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer<TransactionProvider>(
      builder: (context, provider, _) {
        final analytics = provider.peopleAnalytics;
        final query = _query.trim().toLowerCase();
        final people = provider.people
            .where(
                (person) => _typeFilter == null || person.type == _typeFilter)
            .where(
              (person) =>
                  query.isEmpty || person.name.toLowerCase().contains(query),
            )
            .toList(growable: false);

        return Scaffold(
          backgroundColor: AppColors.background(context),
          appBar: AppBar(
            backgroundColor: AppColors.background(context),
            elevation: 0,
            title: Text(
              context.l10nText('People'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary(context),
              ),
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _addPerson(provider),
            backgroundColor: AppColors.primaryLight,
            foregroundColor: AppColors.white,
            icon: const Icon(AppIcons.add_rounded),
            label: Text(context.l10nText('Add person')),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
            children: [
              if (provider.people.isNotEmpty) ...[
                _PeopleInsights(
                  analytics: analytics,
                  provider: provider,
                  onPersonTap: _openPerson,
                ),
                const SizedBox(height: 20),
              ],
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: context.l10nText('Search people'),
                  prefixIcon: const Icon(AppIcons.search, size: 18),
                  filled: true,
                  fillColor: AppColors.cardColor(context),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: AppColors.borderColor(context),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: AppColors.borderColor(context),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _TypeChip(
                      label: context.l10nText('All'),
                      selected: _typeFilter == null,
                      onTap: () => setState(() => _typeFilter = null),
                    ),
                    for (final type in PersonType.values)
                      _TypeChip(
                        label: context.l10nText(personTypeLabel(type)),
                        selected: _typeFilter == type,
                        color: personTypeColor(type),
                        onTap: () => setState(() => _typeFilter = type),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (people.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Column(
                    children: [
                      Icon(
                        AppIcons.group_outlined,
                        size: 40,
                        color: AppColors.textTertiary(context),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        context.l10nText(
                          provider.people.isEmpty
                              ? 'Add friends, shops and others to see who you '
                                  'transact with.'
                              : 'No people match this filter.',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final person in people)
                  PersonListTile(
                    person: person,
                    stats: analytics.statsFor(person.id!),
                    onTap: () => _openPerson(person.id!),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppColors.primaryLight;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: accent.withValues(alpha: 0.16),
        backgroundColor: AppColors.cardColor(context),
        side: BorderSide(
          color: selected ? accent : AppColors.borderColor(context),
        ),
        labelStyle: TextStyle(
          color: selected ? accent : AppColors.textSecondary(context),
          fontWeight: FontWeight.w600,
        ),
        showCheckmark: false,
      ),
    );
  }
}

class PersonListTile extends StatelessWidget {
  final Person person;
  final PersonStats stats;
  final VoidCallback onTap;

  const PersonListTile({
    super.key,
    required this.person,
    required this.stats,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = personTypeColor(person.type);
    final subtitle = <String>[
      context.l10nText(personTypeLabel(person.type)),
      if (stats.transactionCount > 0)
        '${stats.transactionCount} ${context.l10nText(stats.transactionCount == 1 ? 'transaction' : 'transactions')}',
    ].join(' · ');
    final owesYou = stats.lentOutstanding;
    final youOwe = stats.borrowedOutstanding;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.cardColor(context),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderColor(context)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: color.withValues(alpha: 0.14),
                  child: Text(
                    _initials(person.name),
                    style: TextStyle(color: color, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        person.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary(context),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                if (owesYou > 0 || youOwe > 0)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${context.l10nText('ETB')} '
                        '${formatNumberWithComma(owesYou > 0 ? owesYou : youOwe)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: owesYou > 0
                              ? AppColors.incomeSuccess
                              : AppColors.red,
                        ),
                      ),
                      Text(
                        context.l10nText(owesYou > 0 ? 'owes you' : 'you owe'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  )
                else
                  Icon(
                    AppIcons.chevron_right_rounded,
                    color: AppColors.textTertiary(context),
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .take(2)
      .toList(growable: false);
  if (parts.isEmpty) return '?';
  return parts.map((part) => part.characters.first.toUpperCase()).join();
}

class _PeopleInsights extends StatelessWidget {
  final PeopleAnalytics analytics;
  final TransactionProvider provider;
  final ValueChanged<int> onPersonTap;

  const _PeopleInsights({
    required this.analytics,
    required this.provider,
    required this.onPersonTap,
  });

  @override
  Widget build(BuildContext context) {
    final currency = context.l10nText('ETB');
    final sections = <_InsightCard>[
      _InsightCard(
        title: context.l10nText('Where you spend most'),
        icon: AppIcons.trending_down_rounded,
        color: AppColors.red,
        rows: [
          for (final stats in analytics.topSpending(limit: 3))
            _InsightRow(
              label: provider.personById(stats.personId)?.name ?? '',
              value: '$currency ${formatNumberWithComma(stats.spent)}',
              onTap: () => onPersonTap(stats.personId),
            ),
        ],
      ),
      _InsightCard(
        title: context.l10nText('Who borrows most'),
        icon: AppIcons.debts,
        color: AppColors.amber,
        rows: [
          for (final stats in analytics.topBorrowers(limit: 3))
            _InsightRow(
              label: provider.personById(stats.personId)?.name ?? '',
              value: '$currency ${formatNumberWithComma(stats.lent)}',
              detail: stats.lentOutstanding > 0
                  ? '${formatNumberWithComma(stats.lentOutstanding)} '
                      '${context.l10nText('outstanding')}'
                  : null,
              onTap: () => onPersonTap(stats.personId),
            ),
        ],
      ),
      _InsightCard(
        title: context.l10nText('Who you transact with most'),
        icon: AppIcons.swap,
        color: AppColors.primaryLight,
        rows: [
          for (final stats in analytics.topByCount(limit: 3))
            _InsightRow(
              label: provider.personById(stats.personId)?.name ?? '',
              value: '${stats.transactionCount}',
              onTap: () => onPersonTap(stats.personId),
            ),
        ],
      ),
      _InsightCard(
        title: context.l10nText('Spending by type'),
        icon: AppIcons.category,
        color: AppColors.blue,
        rows: [
          for (final stats in analytics.spendingByType())
            _InsightRow(
              label: context.l10nText(personTypeLabel(stats.type)),
              value: '$currency ${formatNumberWithComma(stats.spent)}',
            ),
        ],
      ),
    ].where((card) => card.rows.isNotEmpty).toList(growable: false);

    if (sections.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final section in sections) ...[
          section,
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _InsightCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final List<_InsightRow> rows;

  const _InsightCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: AppColors.cardColor(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  final String label;
  final String value;
  final String? detail;
  final VoidCallback? onTap;

  const _InsightRow({
    required this.label,
    required this.value,
    this.detail,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.textPrimary(context),
                ),
              ),
            ),
            if (detail != null) ...[
              Text(
                detail!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary(context),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
