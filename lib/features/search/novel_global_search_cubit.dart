import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/pinned_sources.dart';
import '../../core/playback/search_source_prefs.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/repository/source_repository.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/zmode/zmode_ids.dart';

/// Where one source got to with a query.
enum NovelSourceStatus { loading, hits, empty, failed }

/// One source's row: its own state, its own results.
///
/// Results are per source and are never merged. Two sites carrying the same
/// novel are two different books as far as this screen is concerned - they are
/// read from different places, saved to different libraries, and a reader who
/// wants one has no way of getting the other. Deduplicating on title would
/// silently pick a winner for them.
class NovelSourceGroup {
  const NovelSourceGroup({
    required this.sourceId,
    required this.sourceName,
    required this.status,
    this.language,
    this.items = const [],
  });

  final String sourceId;
  final String sourceName;

  /// Shown under the name, so a reader with several sources of the same name
  /// can tell them apart without reading each one's catalogue.
  final String? language;
  final NovelSourceStatus status;
  final List<MediaItem> items;

  NovelSourceGroup copyWith({
    NovelSourceStatus? status,
    List<MediaItem>? items,
  }) => NovelSourceGroup(
    sourceId: sourceId,
    sourceName: sourceName,
    status: status ?? this.status,
    language: language,
    items: items ?? this.items,
  );
}

/// Search every novel source at once, one row per source.
///
/// The general search screen answers "what can I find on the source I am
/// looking at", and its scope follows whatever mode Home happens to be in. This
/// answers the other question - "which of my sources has this book?" - so it
/// pins the source set to novel and ignores the current mode entirely.
///
/// Deliberately its own model rather than a configured [SearchBloc]: that one
/// fans out to every selected source at once, with no cap, which is fine when
/// the set is "the active source plus a couple" and not fine when it is every
/// novel source the user has ever installed.
class NovelGlobalSearchCubit extends Cubit<NovelGlobalSearchState> {
  NovelGlobalSearchCubit({
    CatalogueRepository? repo,
    SearchSourcePrefs? prefs,
    Map<String, String>? languages,
    bool Function(String id)? isPinned,
    int maxConcurrent = defaultMaxConcurrent,
    Duration debounce = defaultDebounce,
  }) : _repo = repo ?? sl<CatalogueRepository>(),
       _prefs = prefs ?? sl<SearchSourcePrefs>(),
       // Not on the interface: `sourceLanguages` is a SourceRepository detail,
       // and putting it on CatalogueRepository would force every implementation
       // - including the test doubles - to grow a member they have no use for.
       _languages =
           languages ??
           (repo is SourceRepository ? repo.sourceLanguages : const {}),
       _isPinned = isPinned ?? PinnedSources.isPinned,
       _maxConcurrent = maxConcurrent,
       _debounce = debounce,
       super(const NovelGlobalSearchState());

  /// Five at a time, the same cap Reikai uses. Beyond this the connections
  /// queue behind each other and every source finishes later for no gain, while
  /// a phone's radio is trying to hold them all open at once.
  static const int defaultMaxConcurrent = 5;

  /// Long enough not to fire on every keystroke, short enough that a title
  /// feels typed rather than pasted.
  static const Duration defaultDebounce = Duration(milliseconds: 450);

  final CatalogueRepository _repo;
  final SearchSourcePrefs _prefs;
  final Map<String, String> _languages;
  final bool Function(String id) _isPinned;
  final int _maxConcurrent;
  final Duration _debounce;

  Timer? _debounceTimer;

  /// Bumped by every search. A response from an older one is dropped rather
  /// than applied, which is the whole reason this exists: a slow source
  /// answering after the reader has already typed the next title would
  /// otherwise repaint the screen with the previous query's results.
  int _generation = 0;

  void queryChanged(String raw) {
    _debounceTimer?.cancel();
    final query = raw.trim();
    if (query.isEmpty) {
      search(query);
      return;
    }
    _debounceTimer = Timer(_debounce, () => search(query));
  }

  Future<void> search(String query) async {
    _debounceTimer?.cancel();
    final q = query.trim();
    final generation = ++_generation;

    if (q.isEmpty) {
      emit(const NovelGlobalSearchState());
      return;
    }

    final sources = _novelSources();
    emit(
      state.copyWith(
        query: q,
        searching: true,
        sourceCount: sources.length,
        groups: [
          for (final s in sources)
            NovelSourceGroup(
              sourceId: s.id,
              sourceName: s.name,
              language: s.lang,
              status: NovelSourceStatus.loading,
            ),
        ],
      ),
    );

    if (sources.isEmpty) {
      final excluded = _excludedNovelSources();
      // Logged because "nothing here" is otherwise indistinguishable from a
      // bug: this names every source that was loaded and every one that was
      // switched off, so "why is it empty" is answered by the log rather than
      // guessed at.
      debugPrint(
        '[novel-search] "$q": no searchable novel source. '
        'loaded=${_repo.loadedSources.map((s) => s.id).join(',')} '
        'excluded=${excluded.map((s) => s.id).join(',')}',
      );
      emit(
        state.copyWith(
          searching: false,
          noSources: true,
          excludedCount: excluded.length,
        ),
      );
      return;
    }

    // A small worker pool rather than Future.wait over the whole set: the
    // capped concurrency is the point.
    var next = 0;
    final workers = List.generate(
      _maxConcurrent.clamp(1, sources.length),
      (_) async {
        while (true) {
          final index = next++;
          if (index >= sources.length) return;
          final source = sources[index];
          final outcome = await _run(source, q);
          // A response for a superseded query is discarded, not applied.
          if (generation != _generation) return;
          _apply(source, outcome);
        }
      },
    );
    await Future.wait(workers);

    if (generation != _generation) return;
    emit(state.copyWith(searching: false));
  }

  Future<({List<MediaItem> items, bool failed})> _run(
    ({String id, String name, String? lang}) source,
    String query,
  ) async {
    try {
      final res = await _repo.searchStatus(
        query,
        sourceId: source.id,
        cache: true,
      );
      final List<MediaItem> items = res.items;
      return (items: items, failed: res.outcome == SourceOutcome.error);
    } catch (_) {
      // The general search distinguishes error from timeout; here both mean the
      // same thing to a reader - this source had nothing for us - and the row
      // says which sources came back empty either way.
      return (items: const <MediaItem>[], failed: true);
    }
  }

  void _apply(
    ({String id, String name, String? lang}) source,
    ({List<MediaItem> items, bool failed}) outcome,
  ) {
    emit(
      state.copyWith(
        groups: [
          for (final g in state.groups)
            if (g.sourceId == source.id)
              g.copyWith(
                status: outcome.failed
                    ? NovelSourceStatus.failed
                    : outcome.items.isEmpty
                    ? NovelSourceStatus.empty
                    : NovelSourceStatus.hits,
                items: outcome.items,
              )
            else
              g,
        ],
      ),
    );
  }

  /// Every installed novel source that is switched on for search.
  ///
  /// Novel by provider type rather than by whatever Home is showing: this
  /// screen is the one place a reader goes to search everything regardless of
  /// the mode they left Home in.
  List<({String id, String name, String? lang})> _novelSources() {
    final languages = _languages;
    // The Z Mode pseudo-source is dropped before anything asks what type it is.
    //
    // It types as novel while browsing novels, and its display name is whatever
    // catalogue is configured - AniList, MAL, TMDB - but it is a list of
    // canonical entries, not a place a novel can be read from. Left in, it is
    // the one section a reader sees, and it answers with metadata rather than
    // with anything they could open.
    //
    // Excluded by id rather than by type, because its type is exactly the thing
    // that is misleading here.
    final candidates = {
      for (final s in _repo.loadedSources)
        if (s.id != ZmodeIds.sourceId) s.id: s,
    };
    final eligible = filterSourcesForMode(
      candidates,
      ContentMode.novel,
      (s) => sourceTypeOf(s.id),
    ).values;
    return [
      for (final s in eligible)
        if (_prefs.isIncluded(s.id))
          (id: s.id, name: s.name, lang: languages[s.id]),
    ];
  }

  /// Novel sources that exist but are switched off for search.
  ///
  /// Reported alongside the empty state so "all of them are off" is a
  /// different sentence from "you have none" - one is a setting, the other is
  /// an install.
  List<({String id, String name, String? lang})> _excludedNovelSources() {
    final excluded = <({String id, String name, String? lang})>[];
    for (final s in _repo.loadedSources) {
      if (s.id == ZmodeIds.sourceId) continue;
      if (!ContentMode.novel.matchesProvider(sourceTypeOf(s.id))) continue;
      if (_prefs.isIncluded(s.id)) continue;
      excluded.add((id: s.id, name: s.name, lang: _languages[s.id]));
    }
    return excluded;
  }

  /// Pinned only, which is the narrowing Reikai offers.
  void setPinnedOnly(bool value) {
    if (state.pinnedOnly == value) return;
    emit(state.copyWith(pinnedOnly: value));
  }

  /// Hide the sources that finished with nothing.
  ///
  /// Only meaningful once the search has settled - hiding a row that is still
  /// loading would make the page look finished before it is.
  void setHideEmpty(bool value) {
    if (state.hideEmpty == value) return;
    emit(state.copyWith(hideEmpty: value));
  }

  /// The rows to show, under the current filters.
  List<NovelSourceGroup> visibleGroups() {
    final settled = !state.searching;
    return [
      for (final g in state.groups)
        if (!state.pinnedOnly || _isPinned(g.sourceId))
          if (!state.hideEmpty ||
              !settled ||
              g.status == NovelSourceStatus.hits)
            g,
    ];
  }

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    return super.close();
  }
}

class NovelGlobalSearchState {
  const NovelGlobalSearchState({
    this.query = '',
    this.searching = false,
    this.noSources = false,
    this.sourceCount = 0,
    this.excludedCount = 0,
    this.pinnedOnly = false,
    this.hideEmpty = false,
    this.groups = const [],
  });

  final String query;
  final bool searching;

  /// Nothing to search at all - no novel sources installed, or all switched
  /// off for search. Distinct from "searched and found nothing".
  final bool noSources;

  /// Novel sources that exist and are searchable, before the query ran.
  ///
  /// Shown so an empty screen can say "searched 7 sources" instead of
  /// leaving the reader to wonder whether anything was tried.
  final int sourceCount;

  /// Novel sources that exist but are switched off for search - the difference
  /// between "none installed" and "none switched on".
  final int excludedCount;

  final bool pinnedOnly;
  final bool hideEmpty;
  final List<NovelSourceGroup> groups;

  /// Nothing at all came back, and every source got a real answer.
  bool get allEmpty =>
      !searching &&
      !noSources &&
      groups.isNotEmpty &&
      groups.every((g) => g.status == NovelSourceStatus.empty);

  NovelGlobalSearchState copyWith({
    String? query,
    bool? searching,
    bool? noSources,
    int? sourceCount,
    int? excludedCount,
    bool? pinnedOnly,
    bool? hideEmpty,
    List<NovelSourceGroup>? groups,
  }) => NovelGlobalSearchState(
    query: query ?? this.query,
    searching: searching ?? this.searching,
    noSources: noSources ?? this.noSources,
    sourceCount: sourceCount ?? this.sourceCount,
    excludedCount: excludedCount ?? this.excludedCount,
    pinnedOnly: pinnedOnly ?? this.pinnedOnly,
    hideEmpty: hideEmpty ?? this.hideEmpty,
    groups: groups ?? this.groups,
  );
}