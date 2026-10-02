// About: version, updates, support and the developer credits.
part of 'settings_screen.dart';


// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

class AboutSettingsScreen extends StatefulWidget {
  const AboutSettingsScreen({super.key});

  @override
  State<AboutSettingsScreen> createState() => _AboutSettingsScreenState();
}

class _AboutSettingsScreenState extends State<AboutSettingsScreen> {
  // No website: this fork has no landing page of its own, and the upstream
  // site is not this app's. No Telegram/Discord either — see kDiscordInviteUrl.
  static const String _githubUrl = 'https://github.com/apauruseya7866er/Inkbound';

  final UpdateService _updateService = UpdateService();
  bool _betaUpdates = false;

  @override
  void initState() {
    super.initState();
    _updateService.betaOptIn().then((v) {
      if (mounted) setState(() => _betaUpdates = v);
    });
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  void _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.about),
      body: ListView(
        padding: const EdgeInsets.only(top: 24, bottom: 30),
        children: [
          const _ProfileCard(),
          const SizedBox(height: 24),
          SettingsSectionLabel(context.l10n.social, muted: true),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.code_rounded,
                title: context.l10n.github,
                subtitle: context.l10n.viewTheSourceCode,
                onTap: () => _open(_githubUrl),
              ),
            ],
          ),
          SettingsSectionLabel(context.l10n.appSection, muted: true),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.help_outline_rounded,
                title: context.l10n.howItWorks,
                subtitle: context.l10n.howItWorksSubtitle,
                onTap: () => _push(const HowItWorksScreen()),
              ),
              SettingsTile(
                icon: Icons.system_update_rounded,
                title: context.l10n.checkForUpdates,
                subtitle: context.l10n.checkForUpdatesSubtitle,
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.checkingForUpdates)),
                  );
                  maybeShowUpdateDialog(context, manual: true);
                },
              ),
              SettingsTile(
                icon: Icons.science_outlined,
                title: context.l10n.betaUpdates,
                subtitle: context.l10n.betaUpdatesSubtitle,
                subtitleMaxLines: null,
                trailing: Switch.adaptive(
                  value: _betaUpdates,
                  activeThumbColor: AppColors.accent,
                  onChanged: (v) async {
                    // Turning it on: confirm first so it's never a silent opt-in.
                    if (v && !await confirmJoinBeta(context)) return;
                    await _updateService.setBetaOptIn(v);
                    if (!mounted) return;
                    setState(() => _betaUpdates = v);
                    // Then check right away so a waiting beta shows up.
                    if (v && context.mounted) {
                      maybeShowUpdateDialog(context, manual: true);
                    }
                  },
                ),
              ),
              SettingsTile(
                icon: Icons.favorite_border_rounded,
                title: context.l10n.supportTheApp,
                subtitle: context.l10n.buyMeACoffee,
                onTap: () => _push(const DonateScreen()),
              ),
              if (sl.isRegistered<AppMode>() &&
                  sl<AppMode>().isTv &&
                  kExoSpikeEnabled)
                SettingsTile(
                  icon: Icons.speed_rounded,
                  title: context.l10n.exoplayerSpikeDev,
                  subtitle: context.l10n.sp0TestSurfaceViewPlaybackSmoothness,
                  onTap: () => _push(const TvExoSpikeScreen()),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '© ${DateTime.now().year}  $kAppName',
              style: AppText.caption.copyWith(
                color: AppColors.textTertiary,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The app header: the clean logo mark, name and version floating on the page
/// (no grey box), then the lead-developer card.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 6),
        Image.asset('assets/icon/logo_mark.png', height: 96),
        const SizedBox(height: 16),
        Text(kAppName, style: AppText.largeTitle.copyWith(fontSize: 25)),
        const SizedBox(height: 3),
        Text(
          'v$kAppVersion',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
      ],
    );
  }
}
