import 'browse_sources_screen_tv.dart';
import '../../core/di/injector.dart';
import '../../core/app_mode.dart';
import 'package:flutter/material.dart';

import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../home/search_screen.dart';
import 'browse_source_kinds.dart';
import 'browse_source_screen.dart';
import 'browse_sources_list.dart';

/// Entry point for browsing installed sources without disturbing Home's
/// active source, reached from Home's header action while Z Mode is on (see
/// `HomeBrowseSourcesAction`) — picking a source pushes the existing
/// [BrowseSourceScreen], same as it did as Search's idle state.
///
/// Kind tabs (Streaming / Manga / Novel) narrow [BrowseSourcesList] to one
/// bucket group; the field above them filters by source name within
/// whichever tab is selected. The search action in the app bar is a
/// different thing entirely — it's content search fanned out across every
/// installed source (see [SearchScreen.forceSources]), the replacement for
/// the all-sources search that left the main Search screen when Z Mode is on.
class BrowseSourcesScreen extends StatefulWidget {
  const BrowseSourcesScreen({super.key});

  @override
  State<BrowseSourcesScreen> createState() => _BrowseSourcesScreenState();
}

class _BrowseSourcesScreenState extends State<BrowseSourcesScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  String _query = '';

  /// Phone-only. On TV this build hands off to [BrowseSourcesScreenTv], which
  /// has its own tabs — creating a second controller here just to dispose it
  /// tore down a ticker whose ancestors were already gone.
  TabController? _tabOrNull;
  TabController get _tab =>
      _tabOrNull ??= TabController(length: _kinds.length, vsync: this);

  /// The tab order, and the index every content-mode lookup below relies on.
  /// Novel-only build: one tab (Novel) rather than three, so the search
  /// button's forceMode can't hand Search a Streaming/Manga mode the rest of
  /// the app no longer exposes.
  static final List<SourceListKind> _kinds = BrowseSourceKinds.available();

  /// [SourceListKind] and [ContentMode] both split streaming/manga/novel the
  /// same way; this just names the mapping for [SearchScreen.forceMode].
  ContentMode _modeOf(SourceListKind kind) =>
      BrowseSourceKinds.contentModeOf(kind);

  @override
  void dispose() {
    _controller.dispose();
    _tabOrNull?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // TV gets its own 10-foot layout, the same way SearchScreen hands off to
    // SearchScreenTv. The TV screen and its test came over with the TV work;
    // the hand-off itself never landed, so nothing could reach it.
    if (sl.isRegistered<AppMode>() && sl<AppMode>().isTv) {
      return const BrowseSourcesScreenTv();
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.sources, style: AppText.headline),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: context.l10n.search,
            // forceMode: the tab this was opened from, so the search fans out
            // over that tab's sources instead of Home's global content mode —
            // see [SearchScreen.forceMode].
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchScreen(
                  forceSources: true,
                  forceMode: _modeOf(_kinds[_tab.index]),
                ),
              ),
            ),
          ),
        ],
        // Novel-only build: one tab that says "Novel" and cannot be changed is
        // a label, not a control, so the bar is not drawn. The controller still
        // has that one tab, so every `_kinds[_tab.index]` below resolves the
        // same either way.
        bottom: _kinds.length > 1
            ? TabBar(
                controller: _tab,
                // Drop the default full-width hairline under the bar — same
                // treatment as History's tabs.
                dividerColor: Colors.transparent,
                dividerHeight: 0,
                indicatorSize: TabBarIndicatorSize.label,
                indicator: UnderlineTabIndicator(
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                  borderSide: BorderSide(width: 3, color: AppColors.accent),
                  insets: const EdgeInsets.symmetric(horizontal: -6),
                ),
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.textSecondary,
                overlayColor: WidgetStateProperty.all(Colors.transparent),
                tabs: [
                  // Novel-only build: only the modes this build exposes. See
                  // [_kinds].
                  for (final kind in _kinds)
                    Tab(text: BrowseSourceKinds.tabLabel(context.l10n, kind)),
                ],
              )
            : null,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const Icon(
                    Icons.search,
                    size: 20,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onChanged: (v) => setState(() => _query = v),
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                      ),
                      cursorColor: AppColors.accent,
                      decoration: InputDecoration(
                        hintText: context.l10n.searchSources,
                        hintStyle: AppText.body,
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: AppColors.textTertiary,
                      ),
                      tooltip: context.l10n.clear,
                      onPressed: () => setState(() {
                        _controller.clear();
                        _query = '';
                      }),
                    )
                  else
                    const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                for (final k in _kinds)
                  BrowseSourcesList(
                    kind: k,
                    query: _query,
                    onBrowse: (id, name) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            BrowseSourceScreen(sourceId: id, title: name),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
