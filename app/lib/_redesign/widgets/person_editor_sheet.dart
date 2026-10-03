import 'package:flutter/material.dart';
import 'package:totals/_redesign/screens/people_page.dart';
import 'package:totals/_redesign/theme/app_colors.dart';
import 'package:totals/l10n/app_localizations.dart';
import 'package:totals/models/person.dart';
import 'package:totals/repositories/person_repository.dart';

/// Creates or edits a person. Returns the saved person, or null when the
/// sheet was dismissed.
Future<Person?> showPersonEditorSheet({
  required BuildContext context,
  Person? person,
  String? initialName,
  PersonType? initialType,
}) {
  return showModalBottomSheet<Person>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PersonEditorSheet(
      person: person,
      initialName: initialName,
      initialType: initialType,
    ),
  );
}

class _PersonEditorSheet extends StatefulWidget {
  final Person? person;
  final String? initialName;
  final PersonType? initialType;

  const _PersonEditorSheet({
    this.person,
    this.initialName,
    this.initialType,
  });

  @override
  State<_PersonEditorSheet> createState() => _PersonEditorSheetState();
}

class _PersonEditorSheetState extends State<_PersonEditorSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _noteController;
  late final TextEditingController _telegramController;
  late PersonType _type;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final person = widget.person;
    _nameController = TextEditingController(
      text: person?.name ?? widget.initialName ?? '',
    );
    _noteController = TextEditingController(text: person?.note ?? '');
    _telegramController = TextEditingController(
      text: person?.telegramHandle ?? '',
    );
    _type = person?.type ?? widget.initialType ?? PersonType.friend;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _noteController.dispose();
    _telegramController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = normalizePersonName(_nameController.text);
    if (name.isEmpty) {
      setState(() => _error = context.l10nTextRead('Name is required'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final repository = PersonRepository();
    try {
      final existing = await repository.findByName(name);
      if (existing != null && existing.id != widget.person?.id) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = context.l10nTextRead('A person with this name exists');
        });
        return;
      }
      final now = DateTime.now();
      final note = _noteController.text.trim();
      final telegram = _telegramController.text.trim().replaceFirst('@', '');
      final base =
          widget.person ?? Person(name: name, createdAt: now, updatedAt: now);
      final saved = await repository.savePerson(
        Person(
          id: base.id,
          name: name,
          type: _type,
          note: note.isEmpty ? null : note,
          telegramHandle: telegram.isEmpty ? null : telegram,
          createdAt: base.createdAt,
          updatedAt: now,
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, saved);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  InputDecoration _decoration(String label, {String? prefixText}) {
    return InputDecoration(
      labelText: context.l10nText(label),
      prefixText: prefixText,
      filled: true,
      fillColor: AppColors.surfaceColor(context),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.borderColor(context)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.borderColor(context)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.cardColor(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10nText(
                    widget.person == null ? 'Add person' : 'Edit person',
                  ),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary(context),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  autofocus: widget.person == null,
                  textCapitalization: TextCapitalization.words,
                  decoration: _decoration('Name'),
                ),
                const SizedBox(height: 14),
                Text(
                  context.l10nText('Type'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary(context),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final type in PersonType.values)
                      ChoiceChip(
                        label: Text(context.l10nText(personTypeLabel(type))),
                        selected: _type == type,
                        showCheckmark: false,
                        selectedColor:
                            personTypeColor(type).withValues(alpha: 0.16),
                        side: BorderSide(
                          color: _type == type
                              ? personTypeColor(type)
                              : AppColors.borderColor(context),
                        ),
                        onSelected: (_) => setState(() => _type = type),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _noteController,
                  maxLines: 2,
                  decoration: _decoration('Note'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _telegramController,
                  decoration: _decoration(
                    'Telegram username',
                    prefixText: '@',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.red,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primaryLight,
                      foregroundColor: AppColors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      context.l10nText(_saving ? 'Saving...' : 'Save'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
