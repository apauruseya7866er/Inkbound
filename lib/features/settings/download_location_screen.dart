import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_prefs.dart';
import '../../core/platform/saf_uri.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/settings_widgets.dart';

/// Lets the user pick a custom SAF directory for MP4 downloads, or reset
/// back to the default Downloads › Zangetsu location.
class DownloadLocationScreen extends StatefulWidget {
  const DownloadLocationScreen({super.key});

  @override
  State<DownloadLocationScreen> createState() => _DownloadLocationScreenState();
}

class _DownloadLocationScreenState extends State<DownloadLocationScreen> {
  // Detected drives (internal + any SD/USB/SSD) — the CloudStream-style list
  // that works without the SAF picker. Loaded from the native side.
  List<({String path, String label, bool removable})> _volumes = const [];

  @override
  void initState() {
    super.initState();
    _loadVolumes();
  }

  Future<void> _loadVolumes() async {
    final v = await sl<DownloadManager>().listDownloadVolumes();
    if (mounted) setState(() => _volumes = v);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = sl<DownloadPrefs>();
    final current = prefs.locationUri;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.downloadLocation),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          SettingsSectionLabel(context.l10n.currentLocation),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_rounded,
                      color: AppColors.textSecondary,
                      size: 22,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        prefs.locationLabel ?? context.l10n.downloadsZangetsu,
                        style: AppText.body,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_volumes.isNotEmpty) ...[
            SettingsSectionLabel(context.l10n.availableDrives),
            SettingsCard(
              children: [
                for (final v in _volumes)
                  SettingsTile(
                    icon: v.removable
                        ? Icons.sd_storage_rounded
                        : Icons.smartphone_rounded,
                    title: v.label,
                    subtitle:
                        v.removable ? context.l10n.removableDrive : context.l10n.onThisDevice,
                    iconAccent: current == v.path,
                    trailing: current == v.path
                        ? Icon(Icons.check_rounded,
                            color: AppColors.accent, size: 20)
                        : null,
                    onTap: () async {
                      await sl<DownloadPrefs>().setLocation(v.path, v.label);
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ),
          ],
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.folder_open_outlined,
                title: context.l10n.chooseFolder,
                onTap: () async {
                  final uri = await FileDownloader().uri.pickDirectory(
                    persistedUriPermission: true,
                  );
                  if (uri == null) return; // canceled
                  await sl<DownloadPrefs>().setLocation(
                    uri.toString(),
                    folderLabelFromUri(uri),
                  );
                  if (mounted) setState(() {});
                },
              ),
              if (prefs.locationUri != null)
                SettingsTile(
                  icon: Icons.restore_rounded,
                  title: context.l10n.resetToDefault,
                  onTap: () async {
                    await sl<DownloadPrefs>().setLocation(null, null);
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              context.l10n.newDownloadsSaveHere,
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}
