import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../mode/novel_only.dart';

/// A tab the phone dock can show.
///
/// A STABLE identity, deliberately not a position. The shell used to key
/// everything off the slot number (`_index == 4` meant Settings, `== 1` meant
/// Schedule), which is fine while the five tabs are hardcoded and wrong the
/// moment the user can reorder or hide them.
enum DockTab {
  home('Home'),
  myList('My List'),
  downloads('Downloads'),
  history('History'),
  sources('Sources'),
  profile('Profile');

  const DockTab(this.label);

  /// What the dock prints under the icon.
  final String label;

  /// Profile is the only way into Settings — and Settings is where this very
  /// list is edited. Hiding it would strand the user with no way back, so it
  /// is pinned: always present, never reorderable off the end.
  bool get isPinned => this == DockTab.profile;
}

/// Which tabs the phone dock shows, and in what order.
///
/// Phone only — the TV rail ([RootShellTv]) has its own fixed list and is
/// untouched by this.
class NavPrefs extends ChangeNotifier {
  static const String boxName = 'nav_prefs';
  static const String _tabsKey = 'tabs';
  static const String _startKey = 'start';

  /// The dock is a fixed-width capsule that fits five icons; below three it
  /// looks empty and above five the labels start colliding.
  ///
  /// The cap is four, not five, because the mode switcher is drawn between
  /// the tabs as the dock's centre button and is not a [DockTab] — so the
  /// bar always renders one more icon than there are tabs.
  ///
  /// Novel-only build: the floor drops to two. My List and Sources are not
  /// offered (see [unavailableTabs]) and the mode switcher is gone too, so
  /// Home + Profile is the whole bar — and a floor of three would have made
  /// the default dock illegal, sending every reader who had never touched the
  /// setting into a fallback on launch.
  static int get minTabs => kNovelOnly ? 2 : 3;
  static const int maxTabs = 4;

  /// Tabs this build does not offer at all.
  ///
  /// Not "hidden by default" — unavailable, so they cannot be re-added from the
  /// nav settings screen and a dock saved before the change is filtered on the
  /// way out rather than stranding the reader on a tab this build has no
  /// business showing.
  ///
  /// My List and Sources are both catalogues of *everything*: mixed novels,
  /// manga and shows, from every provider the app can reach. In a build that
  /// is only ever novels, both are lists of novels, reachable already — a book
  /// is one tap from Home, and the sources behind it are the same installed
  /// set the reader set up. They are navigation to nowhere, and a dock is the
  /// most valuable screen real estate in the app.
  static Set<DockTab> get unavailableTabs => kNovelOnly
      ? const {DockTab.myList, DockTab.sources}
      : const {};

  /// Every tab this build offers, in enum order.
  static List<DockTab> get availableTabs => [
    for (final t in DockTab.values)
      if (!unavailableTabs.contains(t)) t,
  ];

  /// What the dock shipped with, and what a corrupt or empty value falls back
  /// to. Search lives in the Home header and Schedule on the Home card row,
  /// so neither is here. Sources moved down from the Home header, where a
  /// small icon was doing the work of a destination; the mode switcher sits
  /// between My List and Sources as the dock's centre button rather than a
  /// tab, so these four names fill all five icon slots.
  ///
  /// Novel-only build: My List and Sources are unavailable, which leaves Home
  /// and Profile.
  static final List<DockTab> defaultTabs = kNovelOnly
      ? const [DockTab.home, DockTab.profile]
      : const [
          DockTab.home,
          DockTab.myList,
          DockTab.sources,
          DockTab.profile,
        ];

  /// Opens the box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// The user's dock, or [defaultTabs].
  ///
  /// Everything stored is re-validated on the way out rather than trusted: a
  /// value written by an older build can name a tab that no longer exists, a
  /// half-written list could otherwise leave the app with a dock it can't
  /// navigate out of, and a dock saved before this build dropped My List and
  /// Sources would keep offering tabs that are no longer reachable.
  List<DockTab> get tabs {
    final raw = _box?.get(_tabsKey);
    if (raw is! List || raw.isEmpty) return defaultTabs;
    final out = <DockTab>[];
    for (final name in raw) {
      final tab = DockTab.values.where((t) => t.name == name).firstOrNull;
      if (tab != null && !out.contains(tab)) out.add(tab);
    }
    return _sanitize(out);
  }

  Future<void> setTabs(List<DockTab> tabs) async {
    final clean = _sanitize(tabs);
    await _box?.put(_tabsKey, [for (final t in clean) t.name]);
    notifyListeners();
  }

  /// The tab the app lands on at launch.
  ///
  /// Validated against [tabs] on the way out rather than on the way in: a tab
  /// the user later hides would otherwise open a page the dock has no way back
  /// to. Falls back to the leftmost tab, which is where the app used to always
  /// start.
  DockTab get startTab {
    final shown = tabs;
    final saved = DockTab.values
        .where((t) => t.name == _box?.get(_startKey))
        .firstOrNull;
    return saved != null && shown.contains(saved) ? saved : shown.first;
  }

  Future<void> setStartTab(DockTab tab) async {
    await _box?.put(_startKey, tab.name);
    notifyListeners();
  }

  Future<void> reset() async {
    await _box?.delete(_tabsKey);
    await _box?.delete(_startKey);
    notifyListeners();
  }

  bool get isDefault =>
      listEquals(tabs, defaultTabs) && startTab == defaultTabs.first;

  /// The validation the getter and setter both apply, exposed so the
  /// invariants can be tested without opening a Hive box.
  @visibleForTesting
  static List<DockTab> sanitizeForTest(List<DockTab> tabs) => _sanitize(tabs);

  /// Forces every invariant the dock depends on: only tabs this build offers
  /// are kept, the pinned tab is present, no duplicates, and the count is
  /// inside [minTabs]..[maxTabs]. Anything that can't be satisfied falls back to
  /// [defaultTabs] rather than leaving a dock the user can't recover from.
  static List<DockTab> _sanitize(List<DockTab> tabs) {
    final unavailable = unavailableTabs;
    final seen = <DockTab>{};
    final out = <DockTab>[
      for (final t in tabs)
        if (!unavailable.contains(t) && seen.add(t)) t,
    ];
    for (final pinned in DockTab.values.where(
      (t) => t.isPinned && !unavailable.contains(t),
    )) {
      if (!out.contains(pinned)) out.add(pinned);
    }
    if (out.length > maxTabs) {
      // Drop from the end, but never the pinned tab.
      while (out.length > maxTabs) {
        final victim = out.lastWhere(
          (t) => !t.isPinned,
          orElse: () => out.last,
        );
        out.remove(victim);
      }
    }
    if (out.length < minTabs) return defaultTabs;
    return List.unmodifiable(out);
  }
}
