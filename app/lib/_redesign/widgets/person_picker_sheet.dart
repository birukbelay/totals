import 'package:flutter/material.dart';
import 'package:totals/_redesign/screens/people_page.dart';
import 'package:totals/_redesign/theme/app_colors.dart';
import 'package:totals/_redesign/theme/app_icons.dart';
import 'package:totals/_redesign/widgets/person_editor_sheet.dart';
import 'package:totals/l10n/app_localizations.dart';
import 'package:totals/models/person.dart';

/// Result of [showPersonPickerSheet]. A null [person] with [cleared] set
/// means the user removed the current assignment.
class PersonPickerResult {
  final Person? person;
  final bool cleared;

  const PersonPickerResult.selected(Person this.person) : cleared = false;

  const PersonPickerResult.cleared()
      : person = null,
        cleared = true;
}

/// Lets the user pick a person, create one (prefilled with [suggestedName])
/// or clear the current selection.
Future<PersonPickerResult?> showPersonPickerSheet({
  required BuildContext context,
  required List<Person> people,
  int? selectedPersonId,
  String? suggestedName,
}) {
  return showModalBottomSheet<PersonPickerResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PersonPickerSheet(
      people: people,
      selectedPersonId: selectedPersonId,
      suggestedName: suggestedName,
    ),
  );
}

class _PersonPickerSheet extends StatefulWidget {
  final List<Person> people;
  final int? selectedPersonId;
  final String? suggestedName;

  const _PersonPickerSheet({
    required this.people,
    this.selectedPersonId,
    this.suggestedName,
  });

  @override
  State<_PersonPickerSheet> createState() => _PersonPickerSheetState();
}

class _PersonPickerSheetState extends State<_PersonPickerSheet> {
  String _query = '';

  Future<void> _create() async {
    final initialName =
        _query.trim().isNotEmpty ? _query.trim() : widget.suggestedName;
    final person = await showPersonEditorSheet(
      context: context,
      initialName: initialName,
    );
    if (person == null || !mounted) return;
    Navigator.pop(context, PersonPickerResult.selected(person));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();
    final people = widget.people
        .where(
          (person) =>
              query.isEmpty || person.name.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final maxHeight = MediaQuery.of(context).size.height * 0.75;

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10nText('Assign person'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary(context),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: context.l10nText('Search people'),
                  prefixIcon: const Icon(AppIcons.search, size: 18),
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surfaceColor(context),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: AppColors.borderColor(context),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  AppIcons.add_circle_outline,
                  color: AppColors.primaryLight,
                ),
                title: Text(
                  _query.trim().isNotEmpty
                      ? '${context.l10nText('Add')} "${_query.trim()}"'
                      : context.l10nText('Add person'),
                  style: const TextStyle(
                    color: AppColors.primaryLight,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: _create,
              ),
              if (widget.selectedPersonId != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    AppIcons.remove_circle_outline,
                    color: AppColors.red,
                  ),
                  title: Text(
                    context.l10nText('Remove person'),
                    style: const TextStyle(color: AppColors.red),
                  ),
                  onTap: () => Navigator.pop(
                    context,
                    const PersonPickerResult.cleared(),
                  ),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: people.length,
                  itemBuilder: (context, index) {
                    final person = people[index];
                    final selected = person.id == widget.selectedPersonId;
                    final color = personTypeColor(person.type);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: color.withValues(alpha: 0.14),
                        child: Icon(AppIcons.person, size: 16, color: color),
                      ),
                      title: Text(person.name),
                      subtitle: Text(
                        context.l10nText(personTypeLabel(person.type)),
                      ),
                      trailing: selected
                          ? const Icon(
                              AppIcons.check_rounded,
                              color: AppColors.primaryLight,
                            )
                          : null,
                      onTap: () => Navigator.pop(
                        context,
                        PersonPickerResult.selected(person),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
