import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/network/cloudflare_bypass_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';

/// Settings for the optional self-hosted Cloudflare bypass proxy.
///
/// Most sources need nothing here: the app's WebView solves the challenge
/// itself. This is for the sources it cannot — a Cloudflare tier where the
/// clearance is bound to the solver's TLS fingerprint and cannot be replayed by
/// the app's own HTTP client. For those, a proxy the user runs solves in a real
/// browser and returns the page.
///
/// Off by default. A URL alone does nothing, so a half-typed address cannot send
/// every challenged request somewhere unreachable.
class CloudflareBypassScreen extends StatefulWidget {
  const CloudflareBypassScreen({super.key});

  @override
  State<CloudflareBypassScreen> createState() => _CloudflareBypassScreenState();
}

class _CloudflareBypassScreenState extends State<CloudflareBypassScreen> {
  final _urlCtrl = TextEditingController();
  String? _testError;
  bool _testing = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = sl<CloudflareBypassPrefs>().url;
    _loaded = true;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _save({bool? enabled}) async {
    final prefs = sl<CloudflareBypassPrefs>();
    await prefs.set(
      enabled: enabled ?? prefs.enabled,
      url: _urlCtrl.text,
    );
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    final prefs = sl<CloudflareBypassPrefs>();
    setState(() {
      _testing = true;
      _testError = null;
    });
    // Persist first so the native side is holding the URL being tested.
    await prefs.set(enabled: prefs.enabled, url: _urlCtrl.text);
    final error = await prefs.test(_urlCtrl.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testError = error;
    });
    final ok = error == null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? context.l10n.cfBypassTestOk : context.l10n.cfBypassTestFailed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final prefs = sl<CloudflareBypassPrefs>();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.cfBypassTitle),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          SettingsSectionLabel(context.l10n.networking),
          SettingsCard(
            children: [
              SwitchListTile.adaptive(
                value: prefs.enabled,
                onChanged: (v) => _save(enabled: v),
                activeThumbColor: AppColors.accent,
                contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                secondary: const Icon(
                  Icons.shield_moon_outlined,
                  color: AppColors.textSecondary,
                  size: 22,
                ),
                title: Text(
                  context.l10n.cfBypassEnable,
                  style: AppText.headline.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(context.l10n.cfBypassBlurb, style: AppText.caption),
          ),
          SettingsSectionLabel(context.l10n.cfBypassProxy),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: TextField(
                  controller: _urlCtrl,
                  enabled: prefs.enabled,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  cursorColor: AppColors.accent,
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: context.l10n.cfBypassUrlLabel,
                    hintText: 'http://192.168.1.10:8191',
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.cfBypassUrlBlurb,
                        style: AppText.caption,
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: (!_testing && prefs.enabled) ? _test : null,
                      child: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.l10n.cfBypassTest),
                    ),
                  ],
                ),
              ),
              if (_testError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Text(
                    _testError!,
                    style: AppText.caption.copyWith(color: AppColors.accent),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              context.l10n.cfBypassHowTo,
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}