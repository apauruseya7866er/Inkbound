import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/reading/text_filter.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';

/// "Regex text cleanup": the rules that strip ads and injected text out of every
/// chapter, and the sentences the reader has hidden by long-pressing them.
///
/// ### Why this is its own screen and not more rows
/// A rule set is a list, and a list does not belong in a settings page built out
/// of switches. It is also the one setting here that deletes prose, which means
/// every rule has to be inspectable *before* it runs and reversible *after* it
/// has — the built-ins are switchable but not deletable, and the reader's own
/// hidden sentences are deletable but not switchable, because there is no
/// sensible "half-hide" of a sentence somebody already asked to lose.
class TextFilterSettingsScreen extends StatefulWidget {
  const TextFilterSettingsScreen({super.key});

  @override
  State<TextFilterSettingsScreen> createState() =>
      _TextFilterSettingsScreenState();
}

class _TextFilterSettingsScreenState extends State<TextFilterSettingsScreen> {
  ReaderPrefs get _prefs => sl<ReaderPrefs>();

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    final hidden = prefs.textFilterRules;
    final disabled = prefs.disabledTextFilterIds;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Regex text cleanup'),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          SettingsSectionLabel('Cleanup', first: true),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.cleaning_services_outlined,
                title: 'Remove ads and injected text',
                subtitle:
                    'Strips donation pleas, Discord and Patreon links, '
                    'chapter footers and translator credits from every chapter, '
                    'on the page and in read-aloud. Sentences you hide yourself '
                    'always apply.',
                subtitleMaxLines: null,
                onTap: () => _toggleMaster(!prefs.textFiltersEnabled),
                trailing: Switch.adaptive(
                  value: prefs.textFiltersEnabled,
                  onChanged: _toggleMaster,
                  activeThumbColor: AppColors.accent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          SettingsSectionLabel('Hidden sentences'),
          SettingsCard(
            children: [
              if (hidden.isEmpty)
                SettingsTile(
                  icon: Icons.touch_app_outlined,
                  title: 'Nothing hidden yet',
                  subtitle:
                      'Press and hold a sentence in the reader to hide it — '
                      'everywhere, not just in this book.',
                )
              else
                for (final rule in hidden)
                  SettingsTile(
                    icon: Icons.visibility_off_outlined,
                    title: rule.label,
                    // The pattern is shown because the label is a truncation of
                    // it: without it there is no way to tell two rules for
                    // near-identical lines apart before deleting the wrong one.
                    subtitle: _patternPreview(rule.pattern),
                    subtitleMaxLines: 2,
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      color: AppColors.textSecondary,
                      tooltip: 'Show this sentence again',
                      onPressed: () => _removeRule(rule),
                    ),
                  ),
              SettingsTile(
                icon: Icons.add_rounded,
                title: 'Hide a sentence by pattern',
                subtitle:
                    'For the same line arriving in slightly different words — '
                    'a footer that names the site it is sending you to.',
                onTap: () => _addRule(),
              ),
            ],
          ),
          SettingsSectionLabel('Built-in rules'),
          SettingsCard(
            children: [
              for (final rule in builtinTextFilterRules)
                SettingsTile(
                  icon: Icons.rule_outlined,
                  title: rule.label,
                  subtitle: _patternPreview(rule.pattern),
                  subtitleMaxLines: 2,
                  onTap: () => _toggleBuiltin(rule, !disabled.contains(rule.id)),
                  trailing: Switch.adaptive(
                    value: !disabled.contains(rule.id),
                    onChanged: (v) => _toggleBuiltin(rule, v),
                    activeThumbColor: AppColors.accent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              SettingsTile(
                icon: Icons.restart_alt_rounded,
                title: 'Turn every built-in rule back on',
                onTap: () async {
                  await _prefs.setDisabledTextFilterIds(const {});
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// A readable one-liner for a pattern.
  ///
  /// The escaped form of a hidden sentence is unreadable — `^\s*The\ End\.` —
  /// and a rule list of unreadable rows is a rule list nobody can audit before
  /// switching one off.
  static String _patternPreview(String pattern) => pattern
      .replaceAll(r'^\s*', '')
      .replaceAll(r'\s*$', '')
      .replaceAll(r'\.', '.')
      .replaceAll(r'\\', '')
      .replaceAll(r'\b', '')
      .replaceAll(r'\s+', ' ')
      .replaceAllMapped(RegExp(r'\((\?i)?'), (_) => '');

  Future<void> _toggleMaster(bool value) async {
    await _prefs.setTextFiltersEnabled(value);
    if (mounted) setState(() {});
  }

  Future<void> _toggleBuiltin(TextFilterRule rule, bool enabled) async {
    final disabled = _prefs.disabledTextFilterIds.toSet();
    if (enabled) {
      disabled.remove(rule.id);
    } else {
      disabled.add(rule.id);
    }
    await _prefs.setDisabledTextFilterIds(disabled);
    if (mounted) setState(() {});
  }

  Future<void> _removeRule(TextFilterRule rule) async {
    await _prefs.removeTextFilterRule(rule.id);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Shown again from now on.')),
    );
  }

  /// Adds a hand-written pattern.
  ///
  /// Validated before it is saved, not after: a rule with a broken regex is
  /// skipped silently by the engine, so saving one would look like it worked
  /// and quietly do nothing — the most confusing possible outcome for a setting
  /// whose whole job is to change what is on the page.
  Future<void> _addRule() async {
    final controller = TextEditingController();
    var isRegex = true;
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Hide a pattern'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                style: AppText.body,
                decoration: const InputDecoration(
                  hintText: r'^\s*read the next chapter\b.*',
                  // Raw string: a bare `$` in a Dart string starts an
                  // interpolation, and `^`/`$` are exactly what this is
                  // teaching.
                  helperText: r'Anchored with ^ and $ to match a whole line.',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text('Regular expression', style: AppText.caption),
                  ),
                  Switch.adaptive(
                    value: isRegex,
                    onChanged: (v) => setLocal(() => isRegex = v),
                    activeThumbColor: AppColors.accent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                if (isRegex) {
                  try {
                    RegExp(text);
                  } on FormatException {
                    return; // Keep the dialog open: it is a typo, not a cancel.
                  }
                }
                Navigator.of(context).pop((text, isRegex));
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    final (pattern, regex) = result;
    final rules = _prefs.textFilterRules;
    if (rules.any((r) => r.pattern == pattern)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('That pattern is already in the list.')),
      );
      return;
    }
    await _prefs.setTextFilterRules([
      ...rules,
      TextFilterRule(
        id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
        pattern: pattern,
        isRegex: regex,
        label: regex ? pattern : 'Text: $pattern',
      ),
    ]);
    if (mounted) setState(() {});
  }
}
