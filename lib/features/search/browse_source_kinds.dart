import '../../core/mode/content_mode.dart';
import '../../core/mode/novel_only.dart';
import '../../l10n/l10n.dart';
import 'browse_sources_list.dart';

/// One source of truth for the source-browser kind tabs shared by phone and TV.
///
/// Phone and TV previously each mapped [SourceListKind] to [ContentMode],
/// ordered the tabs, and localized their labels independently. The two copies
/// drifted: the phone follows [availableModes], while TV always offered all
/// three tabs even in the novel-only build.
abstract final class BrowseSourceKinds {
  /// Tabs in display order, restricted to the modes this build exposes.
  static List<SourceListKind> available([List<ContentMode>? modes]) {
    final source = modes ?? availableModes;
    return [
      for (final mode in source)
        switch (mode) {
          ContentMode.anime => SourceListKind.streaming,
          ContentMode.manga => SourceListKind.manga,
          ContentMode.novel => SourceListKind.novel,
        },
    ];
  }

  /// The content mode a source-browser tab searches within.
  static ContentMode contentModeOf(SourceListKind kind) => switch (kind) {
    SourceListKind.streaming => ContentMode.anime,
    SourceListKind.manga => ContentMode.manga,
    SourceListKind.novel => ContentMode.novel,
  };

  /// Localized tab label for a source-browser kind.
  static String tabLabel(AppLocalizations l10n, SourceListKind kind) =>
      switch (kind) {
        SourceListKind.streaming => l10n.modeStreaming,
        SourceListKind.manga => l10n.modeManga,
        SourceListKind.novel => l10n.modeNovel,
      };

  /// Localized labels in the same order as [available].
  static List<String> tabLabels(AppLocalizations l10n, [List<ContentMode>? modes]) => [
    for (final kind in available(modes)) tabLabel(l10n, kind),
  ];
}
