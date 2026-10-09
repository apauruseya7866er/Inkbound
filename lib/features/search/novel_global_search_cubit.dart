import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/pinned_sources.dart';
import '../../core/playback/search_source_prefs.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/ui/source_switcher.dart';

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
    this.items = const [],
  });

  final String sourceId;
  final String sourceName;
  final NovelSourceStatus status;
  final List<MediaItem> items;

  NovelSourceGroup copyWith({
    NovelSourceStatus? status,
    List<MediaItem>? items,
  }) => NovelSourceGroup(
    sourceId: sourceId,
    sourceName: sourceName,
    status: status ?? this.status,
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
    bool Function(String id)? isPinned,
    int maxConcurrent = defaultMaxConcurrent,
    Duration debounce = defaultDebounce,
  }) : _repo = repo ?? sl<CatalogueRepository>(),
       _prefs = prefs ?? sl<SearchSourcePrefs>(),
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
        groups: [
          for (final s in sources)
            NovelSourceGroup(
              sourceId: s.id,
              sourceName: s.name,
              status: NovelSourceStatus.loading,
            ),
        ],
      ),
    );

    if (sources.isEmpty) {
      emit(
        state.copyWith(
          searching: false,
          noSources: true,
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
    ({String id, String name}) source,
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
    ({String id, String name}) source,
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
  List<({String id, String name})> _novelSources() => filterSourcesForMode(
    {for (final s in _repo.loadedSources) s.id: s},
    ContentMode.novel,
    (s) => sourceTypeOf(s.id),
  ).values.where((s) => _prefs.isIncluded(s.id)).toList();

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
    this.pinnedOnly = false,
    this.hideEmpty = false,
    this.groups = const [],
  });

  final String query;
  final bool searching;

  /// Nothing to search at all - no novel sources installed, or all switched
  /// off for search. Distinct from "searched and found nothing".
  final bool noSources;

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
    bool? pinnedOnly,
    bool? hideEmpty,
    List<NovelSourceGroup>? groups,
  }) => NovelGlobalSearchState(
    query: query ?? this.query,
    searching: searching ?? this.searching,
    noSources: noSources ?? this.noSources,
    pinnedOnly: pinnedOnly ?? this.pinnedOnly,
    hideEmpty: hideEmpty ?? this.hideEmpty,
    groups: groups ?? this.groups,
  );
}