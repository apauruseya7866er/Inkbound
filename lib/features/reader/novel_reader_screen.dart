import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/reading/chapter_nav.dart';
import '../../core/models/page_content.dart';
import '../../core/models/provider_info.dart';
import '../../core/reading/read_history.dart';
import '../../core/reading/read_store.dart';
import '../../core/reading/reader_prefs.dart';
import '../../core/reading/tap_zones.dart';
import '../../core/reading/text_filter.dart';
import '../../core/reading/tts/sentence_parser.dart';
import '../../core/reading/tts/tts_chapters.dart';
import '../../core/reading/tts/tts_cubit.dart';
import '../../core/reading/tts/tts_platform.dart';
import '../../core/reading/tts/tts_prefs.dart';
import '../../core/reading/tts/tts_state.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import 'novel_html.dart';
import 'novel_paginator.dart';
import 'reader_chrome.dart';
import 'reader_auto_scroll.dart';
import 'reader_auto_scroll_ui.dart';
import 'reader_comfort.dart';
import 'reader_pull_chapter.dart';
import 'tts_alignment.dart';
import 'tts_highlight_box.dart';
import 'tts_player_bar.dart';
import '../../l10n/l10n.dart';

/// Text reader for manga/novel chapters — the reading counterpart of the
/// video player. Phone-only (no TV twin, no TV focus handling needed).
///
/// Nothing routes here yet; Task 11 wires the Detail screen to push it.
class NovelReaderScreen extends StatefulWidget {
  /// Called when the foreground narration notification is tapped while this
  /// reader is already in the navigation stack.
  static Future<bool> Function()? ttsNotificationHandler;

  const NovelReaderScreen({
    super.key,
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    required this.cover,
    required this.chapters, // sorted ascending
    required this.startIndex,
    this.malId,
    this.resolveChapters = false,
    this.peek = false,
    this.restoreTtsPosition = false,
  });

  final String sourceId;
  final String showId;
  final String showTitle;
  final String? cover;
  final List<Episode> chapters;
  final int startIndex;

  /// Opened as a look-ahead (or look-back) rather than as your current place:
  /// nothing is persisted. Every write lives behind [_saveProgress] — the
  /// per-chapter mark, the Continue entry AND the tracker scrobble — so one
  /// guard there covers all three. The mark matters as much as the rest,
  /// because the detail screen derives "where you left off" from the highest
  /// marked chapter; a peek mark alone would move your place.
  final bool peek;

  /// MAL id, when known — identifies the title for tracker chapter scrobble
  /// (AniList/MAL manga list). Falls back to [showTitle] when null/unmatched.
  final int? malId;

  /// True when [chapters] may be a single-chapter placeholder (e.g. a
  /// Continue Reading resume, which only has the last-read chapter) that
  /// should widen to the show's real chapter list in the background — see
  /// `_maybeResolveChapters`. Default false: every other caller (Detail
  /// screen) already passes the full list, so this is a no-op for them.
  final bool resolveChapters;

  /// Opened from the read-aloud notification. The saved sentence is restored
  /// and followed without starting narration again.
  final bool restoreTtsPosition;

  @override
  State<NovelReaderScreen> createState() => _NovelReaderScreenState();
}

class _NovelReaderScreenState extends State<NovelReaderScreen>
    with
        ReaderComfortMixin<NovelReaderScreen>,
        TickerProviderStateMixin,
        WidgetsBindingObserver {
  /// Hands-free scrolling — scroll mode only; paged mode turns whole pages.
  late final ReaderAutoScroll _autoScroll;
  late int _index;
  // Mutable so a Continue Reading resume (opened with just the one chapter)
  // can widen to the show's full list in the background — see
  // `_maybeResolveChapters`. Every read of the chapter list goes through
  // this, never `widget.chapters` directly.
  late List<Episode> _chapters = widget.chapters;
  late final ScrollController _scrollController;
  late final PageController _pageController;

  bool _loading = true;
  String? _error;
  ChapterText? _text;
  bool _chromeVisible = false;
  bool _atEnd = false;
  int _lastScrollSaveMs = 0;

  /// Takes the Undo bar down on its own — see [_undoHideSnack]. Held so it can
  /// be cancelled when the reader goes away or Undo is pressed.
  Timer? _undoSnackTimer;
  // Last scroll permille computed while the controller was still attached.
  // `dispose()` flushes progress AFTER the Scrollable has detached, so
  // `_currentPermille()` can't read the live position then — it falls back to
  // this instead of saving 0, which would blank the Continue-Reading progress
  // bar and make the chapter reopen at the top. Manga keeps its position in a
  // retained field for the same reason.
  int _lastScrollPermille = 0;

  // Paged (book) mode state — only used when `prefs.novelPaginated` is true.
  // The scroll path above is left completely untouched so the default reader
  // stays byte-for-byte today's behavior. `_paginationKey` fingerprints the
  // inputs (chapter + text style + page size) so we only re-paginate when one
  // of them actually changes, not on every LayoutBuilder tick.
  List<TextSpan> _pages = const [];
  int _pageIndex = 0;
  String? _paginationKey;

  // Chapter ids already scrobbled this session — dedupes a repeated
  // "finished" save (throttled scroll ticks + the flush on chapter
  // change/dispose can all observe the same finished chapter).
  final Set<String> _scrobbled = {};

  // ── read-aloud ─────────────────────────────────────────────────────────────
  //
  // The engine, its segmentation and its filters live in `core/reading/tts` and
  // `features/reader/novel_html.dart`. Everything here is the seam: this screen
  // owns the page, the pagination and the sentence alignment, so it is the only
  // thing that can put a highlight on the words being read and the only thing
  // that can turn the page when a chapter ends.
  TtsCubit? _tts;
  TtsChapterSource? _ttsChapters;
  StreamSubscription<TtsState>? _ttsSubscription;

  /// The chapter segmented against the text this screen actually renders, or
  /// null when it could not be segmented.
  TtsAlignedChapter? _ttsAligned;

  /// The same layout, kept for the scrolling reader's own spans.
  ///
  /// Built from the same HTML as [_ttsAligned] so a block's spans reproduce
  /// exactly the characters a sentence offset points at. If these were two
  /// layouts, the highlight would be measured against a different string than
  /// the one drawn — which is the whole failure mode `novel_html.dart` exists to
  /// prevent.
  NovelTextLayout? _scrollLayout;

  /// The chapter's HTML *after* the text-cleanup rules, which is the only
  /// chapter text anything in this file is allowed to read.
  ///
  /// Cleaning happens once, at load, and everything downstream — the layout, the
  /// pagination, the read-aloud sentences, and the next chapter the narrator
  /// fetches with this reader already closed — tokenizes this one string. Two
  /// cleanups would be two answers to "what does this chapter say", and the one
  /// the narrator uses is the one nobody can see.
  String? _html;

  /// The rules [_html] was cleaned with.
  ///
  /// Cleaning happens once per chapter, so a rule added while the reader is
  /// open — a sentence just hidden, or a switch flipped on the settings screen
  /// the user came back from — would otherwise have no effect until the next
  /// chapter. `build()` compares the live rules against this and re-cleans when
  /// they differ.
  String? _filterStamp;

  /// Set while a read-aloud page turn is in flight, so [_onPageChanged] can tell
  /// our own jump apart from the reader's.
  bool _ttsTurningPage = false;

  /// When the reader last turned a page themselves. Read-aloud defers to it for
  /// [_ttsPageTurnGraceMs].
  int _lastManualPageTurn = 0;

  /// When the reader last dragged the scrolling novel view themselves, in epoch
  /// ms. Read-aloud's follow defers to it — see [_maybeFollowTtsScroll].
  int _lastManualScroll = 0;

  /// Set while a chapter change is happening *because* narration finished.
  ///
  /// A manual chapter change stops the audio — the words on screen have just
  /// changed. An auto-advance is the opposite: the audio reaching the end of the
  /// chapter is the reason the page is turning, so stopping there would end
  /// every session at the first chapter boundary.
  bool _ttsAutoAdvancing = false;

  /// Whether the read-aloud panel is on screen. Off until the bottom-bar button
  /// is tapped, and deliberately not derived from the engine being available:
  /// a feature nobody asked for should not sit permanently on the page.
  bool _ttsPanelOpen = false;
  bool _ttsRestoreFollowing = false;
  bool _manualTtsFollowNeeded = false;
  bool _ttsPositionRestored = false;

  /// Cumulative y of every block, measured once per chapter so the follow can
  /// reach a block the sliver list has never built. Null until first measured.
  List<double>? _blockOffsets;
  String? _blockMetricsKey;
  static const double _readerContentVerticalPadding = 32;

  /// The width and style those offsets were measured at, so the follow can
  /// measure a sentence's position inside its block against exactly the same
  /// layout the block was placed with.
  double? _blockWidth;
  TextStyle? _blockStyle;

  /// Paged mode as of the last build, so the follow knows not to fight the page
  /// turn that already does this job.
  bool _isPaginated = false;
  late final Future<bool> Function() _ttsNotificationHandler =
      _onTtsNotificationOpened;

  void _startTts() {
    setState(() {
      _ttsPanelOpen = true;
      // The panel is chrome now, so it can only be seen with the chrome. Narration
      // can also be started from the notification while the reader sits there
      // with its bars hidden, and opening a panel nobody can see reads as the
      // feature not having started at all.
      _chromeVisible = true;
    });
    // The panel renders the error if there is nothing to read, so this does not
    // need to check first.
    unawaited(_tts?.play() ?? Future<void>.value());
  }

  void _stopTts() {
    setState(() => _ttsPanelOpen = false);
    unawaited(_tts?.stop() ?? Future<void>.value());
  }

  Future<bool> _onTtsNotificationOpened() async {
    final tts = _tts;
    if (tts == null || tts.state.bookId != widget.showId) return false;
    final chapterId = tts.state.chapterId;
    if (chapterId.isNotEmpty && chapterId != _chapter.url) {
      var target = _chapters.indexWhere((chapter) => chapter.url == chapterId);
      if (target < 0) {
        target = _chapters.indexWhere((chapter) => chapter.id == chapterId);
      }
      if (target >= 0) {
        _ttsAutoAdvancing = true;
        try {
          await _changeChapter(target);
        } finally {
          _ttsAutoAdvancing = false;
        }
      } else {
        setState(() {
          _chapters = [
            Episode(id: chapterId, title: 'Chapter', url: chapterId),
          ];
          _index = 0;
        });
        await _load();
      }
    }
    if (!mounted) return false;
    setState(() {
      _ttsPanelOpen = true;
      _chromeVisible = true;
      _ttsRestoreFollowing = true;
      _manualTtsFollowNeeded = false;
    });
    final readerRoute = ModalRoute.of(context);
    if (readerRoute != null) {
      Navigator.of(context).popUntil((route) => identical(route, readerRoute));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _followRestoredSentence(tts.state);
    });
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.startIndex;
    _ttsPanelOpen = widget.restoreTtsPosition;
    _chromeVisible = widget.restoreTtsPosition;
    _scrollController = ScrollController()..addListener(_onScroll);
    _pageController = PageController();
    // Built here, NOT lazily: createTicker reads TickerMode off the
    // context, and a `late final` initialiser would run that on first
    // access — which, if auto-scroll was never used, is dispose(), where
    // the element is already deactivated and the lookup throws.
    _autoScroll = ReaderAutoScroll(vsync: this);
    if (sl.isRegistered<TtsCubit>()) {
      _tts = sl<TtsCubit>();
      _ttsChapters = _ReaderTtsChapterSource(this);
      // Attached before the first chapter loads, so the chapter after this one
      // is already being fetched while the user reads this one.
      _tts!.attachChapterSource(
        autoAdvance: TtsAutoAdvance(source: _ttsChapters!, index: _index),
        workTitle: widget.showTitle,
      );
      // So a finished chapter turns the page instead of being read out over the
      // chapter already on screen. The reader has to own this: it is the only
      // thing that knows how to load, paginate and align the next chapter.
      _tts!.attachChapterNavigator(_navigateForTts);
      // Following the sentence in scrolling mode hangs off the coordinator's
      // stream, not off a block's build: the block holding the spoken sentence
      // is not in the tree while it is off screen, so a block-triggered follow
      // could only ever fire once the scroll it wanted had already happened.
      _ttsSubscription = _tts!.stream.listen(_maybeFollowTtsScroll);
      NovelReaderScreen.ttsNotificationHandler = _ttsNotificationHandler;
    }
    // Wakelock/brightness/orientation — see ReaderComfortMixin. The novel
    // reader never held a wakelock before this; it now does, same as manga.
    applyReaderComfort();
    _load();
    _maybeResolveChapters();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Saved, but NOT flushed. Android always delivers `paused` before it kills a
    // process, and that handler is where the disk write is forced — so by the
    // time this runs the position is already durable if it was going to be.
    // What is left here is an in-app back navigation, where the process lives on
    // and Hive's own write will land anyway. Forcing a flush from `dispose`
    // would mean an async continuation outliving the widget for no gain.
    _saveProgress(flush: false);
    _undoSnackTimer?.cancel();
    // Narration may still be running in the background service; it just must
    // not try to advance into a chapter list that is going away.
    _tts?.detachChapterSource();
    _tts?.detachChapterNavigator();
    _ttsSubscription?.cancel();
    if (identical(
      NovelReaderScreen.ttsNotificationHandler,
      _ttsNotificationHandler,
    )) {
      NovelReaderScreen.ttsNotificationHandler = null;
    }
    _autoScroll.dispose();
    restoreReaderComfort();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Episode get _chapter => _chapters[_index];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the reader, the voice may have stopped without telling us:
    // the notification's stop button, a media key, or the app being swiped out
    // of the task switcher. Without this the panel comes back offering to pause
    // something that has been silent for minutes. See `TtsCubit.syncWithEngine`.
    if (state == AppLifecycleState.resumed) {
      unawaited(_tts?.syncWithEngine() ?? Future<void>.value());
      return;
    }
    // Backgrounding is the last moment before the process can be killed, and it
    // is the one the reader had no save for. Position was otherwise only written
    // while scrolling, on a page turn, on a chapter change and on close — so
    // reading to the end of a chapter, swiping the app away and coming back
    // tomorrow reopened it at the top, which is the whole complaint.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flushProgress();
    }
  }

  /// Background upgrade for a Continue Reading resume: opened with just the
  /// one already-read chapter, this fetches the show's real chapter list
  /// (same repo call the Detail screen uses) and — once it lands — widens
  /// `_chapters` and corrects `_index` to the same chapter's new position,
  /// so prev/next light up without disturbing whatever's already on screen.
  /// Never touches `_load()`/scroll state itself. Silent no-op on any
  /// failure, an empty/single-chapter result, or a chapter that can't be
  /// found in the fetched list — the single chapter stays a perfectly usable
  /// reader on its own.
  Future<void> _maybeResolveChapters() async {
    if (!widget.resolveChapters || _chapters.length > 1) return;
    final current = _chapter;
    try {
      final fetched = await sl<SourceRepository>().episodes(
        widget.showId,
        sourceId: widget.sourceId,
      );
      if (!mounted || fetched.length <= 1) return;
      var newIndex = fetched.indexWhere((c) => c.url == current.url);
      if (newIndex < 0) {
        newIndex = fetched.indexWhere((c) => c.id == current.id);
      }
      if (newIndex < 0) return;
      setState(() {
        _chapters = fetched;
        _index = newIndex;
      });
    } catch (_) {
      // Keep the single chapter — no error UI, no regression.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final text = await sl<SourceRepository>().chapterText(
        _chapter.url,
        sourceId: widget.sourceId,
      );
      if (!mounted) return;
      final prefs = sl<ReaderPrefs>();
      final html = filterNovelHtml(text.html, prefs.textFilterEngine);
      setState(() {
        _text = text;
        _html = html;
        _filterStamp = _stampFor(prefs);
        _loading = false;
      });
      // One layout, two consumers. Built here rather than inside each renderer so
      // the scrolling spans and the read-aloud sentences cannot disagree about
      // where a paragraph ends.
      _scrollLayout = NovelTextLayout.fromHtml(html);
      _syncTtsFor(html);
      _restoreScrollPosition();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = "Couldn't load this chapter.";
        _loading = false;
      });
    }
  }

  /// A fingerprint of the rules, cheap enough to compute on every build.
  static String _stampFor(ReaderPrefs prefs) => [
    prefs.textFiltersEnabled,
    prefs.textFilterRules.length,
    prefs.disabledTextFilterIds.join(','),
  ].join('|');

  /// Re-cleans the open chapter after a rule changed, and re-points read-aloud
  /// at the result.
  ///
  /// Narration stops first, and deliberately. The engine is part-way through an
  /// utterance built from the *old* sentence list; re-adopting a shorter list
  /// underneath it would leave the two disagreeing about what sentence 40 is,
  /// and the panel would show a position the voice had never reached. The
  /// chapter just changed shape — a pause is the honest response, and the play
  /// button is one tap away.
  Future<void> _reapplyTextFilters() async {
    final html = _html;
    if (html == null || _text == null || !mounted) return;
    final prefs = sl<ReaderPrefs>();
    // Only silence the voice when a rule actually removes something. Turning
    // the cleanup off restores text, which does not invalidate a running
    // narration so much as leave it behind.
    if (prefs.textFiltersEnabled) await _tts?.stop();
    if (!mounted) return;

    final cleaned = filterNovelHtml(_text!.html, prefs.textFilterEngine);

    setState(() {
      _html = cleaned;
      _scrollLayout = NovelTextLayout.fromHtml(cleaned);
      // Both are measured off the layout, so both have to be thrown with it.
      _blockMetricsKey = null;
      _blockOffsets = null;
      _pages = const [];
      _paginationKey = null;
      _filterStamp = _stampFor(prefs);
    });

    // The chapter id has not changed, so the cubit would keep the sentence list
    // it already has — the one that still contains the sentence just hidden.
    _ttsAligned = null;
    if (!_adoptAlignedChapter(cleaned, force: true)) {
      _tts?.loadChapter(
        bookId: widget.showId,
        chapterId: _chapter.url,
        html: cleaned,
        force: true,
      );
    }
    // The page the reader was on no longer exists if what was hidden was part of
    // it, so re-anchor to the top rather than leaving them somewhere other than
    // the sentence they were reading.
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _lastScrollPermille = 0;
  }

  /// Jumps to the chapter's saved scroll permille once the fresh content has
  /// laid out. No-op for a never-read chapter (nothing saved, or saved 0).
  ///
  /// The scroll body is now a lazy `SliverList` (see `_buildBody`), so unlike
  /// the old shrink-wrapped `Text.rich`, `maxScrollExtent` is only an
  /// ESTIMATE until enough items have actually laid out — a single
  /// post-frame `jumpTo` lands short. Poll instead: re-jump to the same
  /// target FRACTION every tick, so each tick corrects the previous one's
  /// guess against the current (better) estimate. Stops once the estimate
  /// stops moving, the user grabs the scrollbar themselves (don't yank
  /// them), or a ~3s ceiling either way.
  void _restoreScrollPosition() {
    if (_ttsRestoreFollowing) return;
    final saved = sl<ReadStore>().get(
      widget.sourceId,
      widget.showId,
      _chapter.id,
    );
    if (saved == null || saved.pos <= 0) return;
    // Set now, not after the poll lands — a dispose before the poll settles
    // must not fall back to 0 (see `_lastScrollPermille`'s own doc).
    _lastScrollPermille = saved.pos;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _pollRestoreScroll(saved.pos / 1000),
    );
  }

  Future<void> _pollRestoreScroll(double fraction) async {
    // Bounded by a fixed tick count, NOT a DateTime.now() deadline: widget
    // tests run on a faked clock where wall-time barely advances, so a
    // real-clock deadline would never trip and this loop would spin forever
    // (hanging pumpAndSettle). 60 ticks × 50ms ≈ 3s of lazy layout to catch up.
    double? lastMax;
    for (
      var tick = 0;
      tick < 60 && mounted && _scrollController.hasClients;
      tick++
    ) {
      final pos = _scrollController.position;
      // A jump already landed and the user has since dragged away from it —
      // leave them alone instead of yanking them back mid-read.
      if (lastMax != null && (pos.pixels - fraction * lastMax).abs() > 8) {
        return;
      }
      final max = pos.maxScrollExtent;
      if (max > 0) {
        _scrollController.jumpTo((fraction * max).clamp(0, max));
        if (lastMax != null && (max - lastMax).abs() < 1) return; // settled
        lastMax = max;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atEnd =
        pos.maxScrollExtent <= 0 || pos.pixels >= pos.maxScrollExtent - 4;
    if (atEnd != _atEnd) setState(() => _atEnd = atEnd);

    // Throttle routine in-chapter saves to ~once/second.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollSaveMs < 1000) return;
    _lastScrollSaveMs = now;
    _saveProgress(flush: false);
  }

  int _currentPermille() {
    // Both modes speak the same 0–1000 permille scale, so ReadStore/scrobble/
    // resume semantics are identical — only the source of the number differs.
    if (sl<ReaderPrefs>().novelPaginated) return _pagedPermille();
    // Controller already detached (e.g. inside dispose's flush) — reuse the
    // last value captured while scrolling instead of clobbering progress with 0.
    if (!_scrollController.hasClients) return _lastScrollPermille;
    final pos = _scrollController.position;
    // Nothing to scroll means "the whole chapter fits on screen" — finished —
    // but ONLY when there's actually a chapter there. A blank page (a source
    // that returned no text) is unscrollable too, and counting that as read
    // would mark it finished and scrobble it to the user's tracker.
    if (pos.maxScrollExtent <= 0) {
      final hasText = (_html?.trim().isNotEmpty ?? false);
      return _lastScrollPermille = hasText ? 1000 : 0;
    }
    final raw = (pos.pixels / pos.maxScrollExtent * 1000).round();
    return _lastScrollPermille = raw.clamp(0, 1000);
  }

  /// Paged-mode permille: the last page is 1000 (= finished, ≥ ReadStore's 950
  /// novel rule), so mark-read + scrobble fire at the end of a paged chapter
  /// exactly like they do when scrolling to the bottom.
  int _pagedPermille() {
    final count = _pages.length;
    if (count <= 1) return 1000; // single page = whole chapter on screen
    final raw = (_pageIndex / (count - 1) * 1000).round();
    if (raw < 0) return 0;
    if (raw > 1000) return 1000;
    return raw;
  }

  /// The chapter's saved permille (0 when never read) — the paged analogue of
  /// what `_restoreScrollPosition` reads.
  int _savedPermille() {
    final saved = sl<ReadStore>().get(
      widget.sourceId,
      widget.showId,
      _chapter.id,
    );
    if (saved == null) return 0;
    final p = saved.pos;
    if (p < 0) return 0;
    if (p > 1000) return 1000;
    return p;
  }

  /// Converts a saved permille to a starting page, so resuming lands on the
  /// same spot the scroll mode would — and switching modes mid-chapter keeps
  /// the reader at roughly the same place.
  int _pageForPermille(int permille, int count) {
    if (count <= 1) return 0;
    final page = (permille / 1000 * (count - 1)).round();
    if (page < 0) return 0;
    if (page >= count) return count - 1;
    return page;
  }

  /// Persists the current chapter's position. `ReadStore.save`/
  /// `ReadHistory.save` both already start with `if (IncognitoMode.on)
  /// return;` internally, so no extra guard belongs here — adding one would
  /// duplicate that check for no behavioral change.
  ///
  /// Fire-and-forget by design, and [flush] does NOT change that: the record is
  /// handed to Hive and the call returns, because a scroll must not wait on
  /// disk. What [flush] adds is asking Hive to get the pending write out to the
  /// file. Without it the write sits in memory on Hive's own schedule, a process
  /// that dies first loses it, and the chapter reopens at the top — so the
  /// paths that mean "this is the last chance" (chapter change, reader close,
  /// app backgrounded) pass `true`.
  void _saveProgress({required bool flush}) {
    if (widget.peek) return; // just looking — leave saved progress alone
    if (_text == null) return; // nothing loaded for this chapter yet
    final ep = _chapter;
    final permille = _currentPermille();
    sl<ReadStore>().save(
      widget.sourceId,
      widget.showId,
      ep.id,
      pos: permille,
      total: 1000,
    );
    sl<ReadHistory>().save(
      ReadEntry(
        sourceId: widget.sourceId,
        showId: widget.showId,
        title: widget.showTitle,
        cover: widget.cover,
        chapterId: ep.id,
        chapterNumber: ep.number,
        chapterUrl: ep.url,
        pos: permille,
        total: 1000,
        updatedMs: DateTime.now().millisecondsSinceEpoch,
        type: ProviderType.novel,
      ),
    );
    if (sl<ReadStore>().finished(widget.sourceId, widget.showId, ep.id)) {
      _maybeScrobble(ep);
    }
    if (flush) unawaited(_flushStores());
  }

  /// Asks both boxes to finish writing.
  ///
  /// Started, not awaited: every caller is synchronous (a scroll listener, a
  /// dispose, a lifecycle callback) and none of them can wait. `Box.flush`
  /// waits for whatever is already pending, so starting it straight after the
  /// save is what makes the position durable — and it must stay off the scroll
  /// path, where a write per tick is not worth the I/O.
  Future<void> _flushStores() async {
    // Resolved BEFORE the first await, deliberately. This runs unawaited, so its
    // continuation can land after the widget is gone — and in a test, after the
    // injector has been reset. Looking the stores up first means the lookup
    // happens while this screen still owns them, and the only thing left running
    // late is the disk write.
    final positions = sl<ReadStore>();
    final history = sl<ReadHistory>();
    try {
      await positions.flush();
      await history.flush();
    } catch (e) {
      // Best-effort by construction: this is a nudge to get an already-queued
      // write onto the disk, not a write the reader depends on. The record is in
      // Hive either way, and a closed box or a full disk is not something the
      // reader can act on — so it must not surface as a crash, here or in a test
      // that has already torn the box down.
      debugPrint('[reader] progress flush failed: $e');
    }
  }

  /// Chapter scrobble on completion — mirrors player_controller.dart's
  /// _maybeScrobble guard structure exactly (TrackerHub registration check,
  /// a dedupe set, then TrackerHub.scrobble). TrackerHub already gates
  /// incognito internally, so no extra check belongs here.
  void _maybeScrobble(Episode ep) {
    if (_scrobbled.contains(ep.id)) return;
    final n = ep.number;
    if (n == null || n <= 0 || n != n.truncateToDouble()) return;
    if (!sl.isRegistered<TrackerHub>()) return;
    _scrobbled.add(ep.id);
    sl<TrackerHub>().scrobble(
      malId: widget.malId,
      title: widget.showTitle,
      episode: n.toInt(),
      kind: MediaKind.manga,
      novel: true, // AniList files this under manga+format:NOVEL, not manga
    );
  }

  void _flushProgress() => _saveProgress(flush: true);

  /// Where next/prev actually go — same multi-group rule the manga reader
  /// uses, so a source that lists several groups doesn't send the reader to
  /// the chapter it just finished under a different name.
  int? get _nextIndex => adjacentChapterIndex(_chapters, _index, step: 1);
  int? get _prevIndex => adjacentChapterIndex(_chapters, _index, step: -1);

  void _goToChapter(int? newIndex) {
    unawaited(_changeChapter(newIndex));
  }

  /// Moves to [newIndex] and reports whether the reader ended up on a chapter
  /// that loaded.
  ///
  /// [_goToChapter] is the fire-and-forget wrapper the buttons, swipes and
  /// chapter list use. Read-aloud needs the outcome: it is about to start
  /// narrating the new chapter, and doing that into a page that never arrived
  /// is how the voice and the screen end up disagreeing.
  Future<bool> _changeChapter(int? newIndex) async {
    // See the manga reader: a live auto-scroll must not survive into a chapter
    // that hasn't laid out yet.
    _autoScroll.stop();
    // Audio belongs to the text on screen. Leaving it running would read the old
    // chapter while the new one is displayed, and its highlight would point at
    // sentences the user cannot see. The position in the chapter being left is
    // kept, so coming back offers to resume.
    //
    // Except during an auto-advance, where this change *is* the narration
    // finishing. Stopping here would end every session at the first chapter
    // boundary — the exact moment it is supposed to continue.
    if (!_ttsAutoAdvancing) {
      _tts?.stop(clearPosition: false);
    }
    if (newIndex == null || newIndex < 0 || newIndex >= _chapters.length) {
      return false;
    }
    if (newIndex == _index) return false;
    _flushProgress(); // chapter change: push the chapter we're leaving now
    if (!mounted) return false;
    setState(() {
      _index = newIndex;
      _text = null;
      _scrollLayout = null;
      _ttsAligned = null;
      // The old chapter's measured offsets describe text that is gone.
      _blockOffsets = null;
      _blockMetricsKey = null;
      _error = null;
      _atEnd = false;
      _lastScrollSaveMs = 0;
      _lastScrollPermille = 0; // don't carry the old chapter's progress over
      // Drop the old chapter's pages so paged mode re-paginates the new one
      // and restores from ITS saved permille (empty pages → use saved, below).
      _pages = const [];
      _paginationKey = null;
      _pageIndex = 0;
    });
    // Point the read-aloud coordinator at the chapter now on screen, so a
    // completion advances to the right neighbour rather than the one the
    // prefetch was started for.
    _tts?.setChapterIndex(newIndex);
    await _load();
    final ok = mounted && _error == null && _text != null;
    // The chapter ids, not the indices: if these match, the reader adopted the
    // chapter it is now showing, and any mismatch between the queue and the
    // highlight starts here.
    debugPrint(
      '[TtsCubit] reader loaded ${_chapter.url} '
      '(aligned=${_ttsAligned != null}, ${_ttsAligned?.total ?? 0} sentences, '
      'loaded=$ok)',
    );
    return ok;
  }

  /// Turns to the next chapter because narration reached the end of this one.
  ///
  /// The reader decides which chapter that is. The coordinator has no way to
  /// know where the reader actually is — it only ever sees the index it was
  /// given when the chapter list was attached, which is not the same thing once
  /// the list has been widened or a chapter opened directly.
  ///
  /// Reports false at the end of the book or when the chapter will not load, so
  /// the coordinator treats it as the end of the session rather than sitting in
  /// a speaking state with nothing queued.
  Future<bool> _navigateForTts() async {
    final target = _index + 1;
    _ttsAutoAdvancing = true;
    try {
      final ok = await _changeChapter(target);
      debugPrint(
        '[TtsCubit] reader turned ${ok ? 'to' : 'nowhere from'} index $target '
        '(of ${_chapters.length})',
      );
      return ok;
    } finally {
      _ttsAutoAdvancing = false;
    }
  }

  /// Hands the freshly loaded chapter to read-aloud.
  ///
  /// Drop the previous chapter's alignment first: a stale one would highlight
  /// offsets from text that is no longer on screen.
  ///
  /// Deliberately does not start speech. Opening a chapter should not start
  /// audio — that would make scrolling through a book unusable.
  void _syncTtsFor(String html) {
    _ttsAligned = null;
    // The aligned path replaces the plain one rather than running alongside it.
    // Doing both would parse the chapter twice per load and briefly install a
    // sentence list built from different text than the page renders.
    if (!_adoptAlignedChapter(html)) {
      _tts?.loadChapter(
        // The chapter URL is the stable per-chapter key here; `showId` scopes
        // the resume point to the book so two books' positions never mix.
        bookId: widget.showId,
        chapterId: _chapter.url,
        html: html,
      );
    }
    _restoreTtsSentence();
  }

  void _restoreTtsSentence() {
    if (!widget.restoreTtsPosition || _ttsPositionRestored) return;
    final tts = _tts;
    if (tts == null) return;
    _ttsPositionRestored = true;
    _ttsRestoreFollowing = true;

    if (tts.state.chapterId == _chapter.url && tts.state.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _followRestoredSentence(tts.state);
      });
      return;
    }

    final point = sl<TtsPrefs>().savedPosition(widget.showId);
    if (point == null || point.chapterId != _chapter.url) return;
    unawaited(tts.seek(tts.resolveResumeIndex(point)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _followRestoredSentence(tts.state);
    });
  }

  void _followRestoredSentence(TtsState state) {
    if (_isPaginated) {
      _maybeFollowTts(state);
    } else {
      _maybeFollowTtsScroll(state);
    }
  }

  /// Segments the chapter against its *rendered* text and hands the result to
  /// the controller, so the sentence being spoken can be pointed at.
  ///
  /// Uses the same tokenizer the paged renderer builds its spans from.
  /// Segmenting from the raw HTML instead would produce offsets into a string
  /// the page never contains, and the highlight would land on the wrong words
  /// with nothing to indicate why.
  ///
  /// Returns whether the chapter was adopted, so the caller can fall back to
  /// plain HTML segmentation.
  bool _adoptAlignedChapter(String html, {bool force = false}) {
    final tts = _tts;
    if (tts == null) return false;
    try {
      final aligned = alignChapter(
        _scrollLayout ?? NovelTextLayout.fromHtml(html),
      );
      // This is the first thing to check when the panel tracks the voice but
      // nothing is highlighted on the page: it is the line that says whether
      // there is a sentence list to point at. `debugPrint` because main.dart
      // mirrors it into the app's own log, which is where a reader can see it.
      debugPrint(
        '[TtsCubit] segmented ${aligned.total} sentences in '
        '${aligned.layout.blocks.length} blocks '
        '(${aligned.layout.length} chars)',
      );
      if (aligned.isEmpty) return false;
      _ttsAligned = aligned;
      tts.adoptChapter(
        bookId: widget.showId,
        chapterId: _chapter.url,
        force: force,
        views: [
          for (final s in aligned.sentences)
            TtsSentenceView(
              index: s.index,
              text: s.text,
              blockIndex: s.blockIndex,
              pauseAfterMs: s.pauseAfterMs,
              start: s.startIndex,
              end: s.endIndex,
            ),
        ],
      );
      return true;
    } catch (e) {
      debugPrint('[TtsCubit] could not segment this chapter: $e');
      return false;
    }
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  /// Re-cleans the open chapter when the rules changed while it was on screen.
  ///
  /// The settings screen is a route *above* the reader, so a rule toggled there
  /// is already saved by the time the reader is visible again — the chapter just
  /// has not been rebuilt. Checked here rather than on the way into the reader
  /// because the reader is also where a sentence gets hidden, and both need the
  /// same rebuild.
  ///
  /// Deferred to after the frame rather than done here: this is a build method,
  /// and a rule can only change from a tap, a dialog or a route the user just
  /// came back from — never during a build. The stamp is re-checked inside the
  /// callback, so a build that queued two of them does the work once.
  void _watchTextFilterChanges(ReaderPrefs prefs) {
    if (_html == null) return;
    if (_stampFor(prefs) == _filterStamp) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _html == null) return;
      if (_stampFor(sl<ReaderPrefs>()) == _filterStamp) return;
      unawaited(_reapplyTextFilters());
    });
  }

  // ── hiding a sentence from the page and from every other novel ───────────

  /// What a long press found under the finger.
  ///
  /// The sentence text *and* the block it came from, because the text alone is
  /// not enough to hide it: the rule is matched per line, so the block decides
  /// which line of a chapter the sentence is on and a bare text match could
  /// take out a paragraph that merely contains the same words somewhere else.
  ({String text, int blockIndex, int start, int end})? _sentenceAt(
    Offset global,
  ) {
    final layout = _scrollLayout;
    final prefs = sl<ReaderPrefs>();
    if (layout == null || layout.blocks.isEmpty) return null;
    final base = _baseTextStyle(prefs);
    final width = (MediaQuery.sizeOf(context).width - prefs.marginWidth * 2)
        .clamp(1.0, double.infinity);

    int chapterOffset;
    if (_isPaginated) {
      if (_pages.isEmpty) return null;
      final painter = TextPainter(
        text: _pages[_pageIndex.clamp(0, _pages.length - 1)],
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        textAlign: _textAlign,
      )..layout(maxWidth: width);
      final position = painter.getPositionForOffset(
        Offset(global.dx - prefs.marginWidth, global.dy - 32),
      );
      painter.dispose();
      // The page is a contiguous slice of the chapter, so the page's own start
      // is the sum of the pages before it — the same accumulate-and-clip walk
      // `pageSliceFor` uses to go the other way.
      var pageStart = 0;
      for (var i = 0; i < _pages.length; i++) {
        final pageEnd = pageStart + _pages[i].toPlainText().length;
        if (i == _pageIndex) break;
        pageStart = pageEnd;
      }
      chapterOffset = pageStart + position.offset;
    } else {
      final offsets = _blockOffsets;
      if (offsets == null || !_scrollController.hasClients) return null;
      // 32 is the `SliverPadding` above the first block, and the body sits under
      // the system bars only after `SafeArea` has taken them out.
      final topInContent = global.dy + _scrollController.position.pixels;
      int? block;
      var yInBlock = 0.0;
      for (var b = 0; b + 1 < offsets.length; b++) {
        final top = offsets[b] + 32;
        if (topInContent < top) break;
        if (topInContent < offsets[b + 1] + 32) {
          block = b;
          yInBlock = topInContent - top;
          break;
        }
      }
      if (block == null) return null;
      final painter = TextPainter(
        text: TextSpan(
          style: base,
          children: novelBlockSpans(layout, block, base: base),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        textAlign: _textAlign,
      )..layout(maxWidth: width);
      final position = painter.getPositionForOffset(
        Offset(global.dx - prefs.marginWidth, yInBlock),
      );
      painter.dispose();
      chapterOffset = layout.blocks[block].start + position.offset;
    }

    if (chapterOffset < 0 || chapterOffset >= layout.length) return null;
    final hit = hideableRangeAt(layout, chapterOffset, _sentences());
    if (hit == null) return null;
    // The *page's* words, not the sentence the narrator would speak. A TTS
    // sentence is normalised on the way out — URLs removed, quotes rewritten,
    // `--` folded into a dash — and a rule built from that would no longer match
    // the text it is supposed to be hiding. The offsets are exact either way, so
    // this is a slice, not a re-segmentation.
    return (
      text: hit.text,
      blockIndex: hit.blockIndex,
      start: hit.start,
      end: hit.end,
    );
  }

  /// The segmentation the long press is measured against.
  ///
  /// Prefers the one read-aloud is already using — it is the same list the
  /// panel quotes, so a sentence the user highlights by touch is the sentence
  /// they would hear. Falls back to segmenting on demand when narration has
  /// never run, because hiding a sentence must not require starting the voice.
  ///
  /// The fallback segments with the narration filter *off*: the sentences
  /// NarrationFilter drops are the donation pleas and chapter footers, which is
  /// precisely what somebody long-pressing an ad is trying to get rid of.
  List<TtsSentence> _sentences() {
    final aligned = _ttsAligned;
    if (aligned != null) return aligned.sentences;
    final layout = _scrollLayout;
    if (layout == null) return const [];
    return alignChapter(layout, narrationFilter: false).sentences;
  }

  /// Body text style for the page - the one thing every renderer, the block
  /// measurements and the long-press hit test have to agree on.
  ///
  /// A second copy of this is not a shortcut, it is a bug waiting: a long press
  /// measured against a different font size or line height lands on a different
  /// word, and the sentence it offers to hide is the wrong one.
  TextStyle _baseTextStyle(ReaderPrefs prefs) => TextStyle(
    fontFamily: novelFontFamily(prefs.fontFamily),
    fontSize: prefs.fontSize,
    height: prefs.lineHeight,
    letterSpacing: prefs.letterSpacing,
    wordSpacing: prefs.wordSpacing,
    color: _readerTheme(prefs.theme).text,
  );

  /// Long press on a sentence: offer to hide it everywhere.
  ///
  /// Deliberately only a hide. Every other thing a reader might want from a
  /// sentence — copy, share, look up — is a gesture in the app they can already
  /// reach, and a menu that has grown a submenu since the last time anyone used
  /// it is a menu nobody reads.
  Future<void> _onSentenceLongPress(Offset global) async {
    if (!mounted) return;
    final hit = _sentenceAt(global);
    if (hit == null) return;
    final prefs = sl<ReaderPrefs>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          hit.text,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: AppText.body,
        ),
        content: Text(
          'Hidden in every novel, not just this one — the same line comes back '
          'in every chapter.',
          style: AppText.caption,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Hide'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final rule = await prefs.hideTextEverywhere(hit.text);
    if (!mounted) return;
    await _reapplyTextFilters();
    if (!mounted) return;
    _undoHideSnack(rule, hit.text);
  }

  /// Confirms the hide and offers the one-tap way back, because a rule that
  /// deletes prose has to be reversible from where it was made — a settings
  /// screen three taps away is not "undo" when the thing that went wrong is one
  /// sentence of the chapter you are reading.
  ///
  /// The bar is taken down by [Timer] rather than left to the SnackBar's own
  /// duration. A SnackBar carrying a [SnackBarAction] is not auto-dismissed on
  /// this Flutter version — it sat there until the app was restarted, which is
  /// exactly what it is supposed to be telling you is reversible. An explicit
  /// `duration` does not help, and neither does `SnackBarBehavior.floating`;
  /// hiding it through the messenger is the only thing that does. Five seconds is
  /// long enough to hit Undo and short enough that it is not in the way.
  void _undoHideSnack(TextFilterRule rule, String sentence) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Hidden everywhere: ${_shorten(sentence)}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            _undoSnackTimer?.cancel();
            final prefs = sl<ReaderPrefs>();
            unawaited(
              prefs.removeTextFilterRule(rule.id).then((_) {
                if (mounted) unawaited(_reapplyTextFilters());
              }),
            );
          },
        ),
      ),
    );
    _undoSnackTimer?.cancel();
    _undoSnackTimer = Timer(_undoSnackVisibleFor, () {
      _undoSnackTimer = null;
      if (mounted) messenger.hideCurrentSnackBar();
    });
  }

  /// How long the Undo bar stays before the reader takes it down itself.
  static const Duration _undoSnackVisibleFor = Duration(seconds: 5);

  static String _shorten(String text) =>
      text.length > 40 ? '${text.substring(0, 40)}…' : text;

  @override
  Widget build(BuildContext context) {
    final prefs = sl<ReaderPrefs>();
    final theme = _readerTheme(prefs.theme);
    _isPaginated = prefs.novelPaginated;
    _watchTextFilterChanges(prefs);
    return Scaffold(
      backgroundColor: _dimmedBg(theme, prefs.novelBgOpacity),
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _dispatchTap(d.globalPosition),
              onLongPressStart: (d) => _onSentenceLongPress(d.globalPosition),
              // Touch pauses; lifting resumes after a grace. See the manga
              // reader — stopping outright on a drag made a nudge fatal.
              child: Listener(
                onPointerDown: (_) => _autoScroll.pauseForTouch(),
                onPointerUp: (_) => _autoScroll.resumeAfterTouch(),
                onPointerCancel: (_) => _autoScroll.resumeAfterTouch(),
                child: ReaderPullChapter(
                  enabled: prefs.overscrollChapter,
                  hasPrev: _prevIndex != null,
                  hasNext: _nextIndex != null,
                  prevLabel: _chapterLabel(_prevIndex),
                  nextLabel: _chapterLabel(_nextIndex),
                  onChangeChapter: (d) =>
                      _goToChapter(d > 0 ? _nextIndex : _prevIndex),
                  // A drag, not a fling or a jump: this is the reader taking
                  // the page back, and read-aloud's follow should let them.
                  child: NotificationListener<ScrollStartNotification>(
                    onNotification: (n) {
                      if (n.dragDetails != null) {
                        _lastManualScroll =
                            DateTime.now().millisecondsSinceEpoch;
                        _manualTtsFollowNeeded = true;
                        _ttsRestoreFollowing = false;
                      }
                      return false;
                    },
                    child: _buildBody(theme, prefs),
                  ),
                ),
              ),
            ),
          ),
          // Always mounted now (fade instead of build-if-visible) — see the
          // IgnorePointer inside each for why that doesn't eat page taps.
          _buildTopBar(),
          _buildBottomBar(),
          // The read-aloud panel floats over the text, above the bottom bar.
          // Opt-in: it only appears once the bottom-bar button has been tapped,
          // so a reader who is not listening pays nothing for the feature and
          // the page is not permanently furniture.
          if (_tts != null && _ttsPanelOpen)
            Positioned(
              left: 0,
              right: 0,
              // Clears the bottom bar's pill, which is SafeArea + 12 padding +
              // the pill itself.
              bottom: 72,
              // Hides with the top and bottom bars, on the same terms.
              //
              // It is the largest thing on screen and it sits over the prose, so
              // a listener who is reading along has a third of the page covered
              // for the whole chapter — which is the opposite of what read-aloud
              // is for. It was the one piece of chrome that ignored the toggle,
              // which is why a reader who had just dismissed the top and bottom
              // bars to get on with the book still had a panel in the way.
              //
              // IgnorePointer while hidden, for the reason the other two bars
              // carry it: an invisible panel left in the tree would keep
              // swallowing the tap that is supposed to bring the chrome back.
              // Narration itself is unaffected — it runs in the foreground
              // service, so hiding this costs the reader nothing but the
              // controls, and one tap brings them back.
              child: IgnorePointer(
                ignoring: !_chromeVisible,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _chromeVisible ? 1 : 0,
                  child: TtsPlayerBar(
                    cubit: _tts!,
                    onOpenSettings: _openTtsSheet,
                    onClose: () {
                      setState(() => _ttsPanelOpen = false);
                      _tts?.stop();
                    },
                  ),
                ),
              ),
            ),
          if (_tts != null)
            AnimatedBuilder(
              animation: Listenable.merge([_scrollController, _pageController]),
              builder: (context, _) {
                final state = _tts!.state;
                final target = _isPaginated
                    ? _ttsPageTarget(state)
                    : _ttsScrollTarget(state);
                if (!_manualTtsFollowNeeded ||
                    (!state.isActive && !_ttsRestoreFollowing) ||
                    target == null ||
                    (_isPaginated && target == _pageIndex)) {
                  return const SizedBox.shrink();
                }
                return Positioned(
                  right: 16,
                  bottom: _ttsPanelOpen ? 250 : 24,
                  child: Semantics(
                    button: true,
                    label: 'Follow the currently read sentence',
                    child: FilledButton.icon(
                      onPressed: () {
                        _manualTtsFollowNeeded = false;
                        _ttsRestoreFollowing = true;
                        _lastManualScroll = 0;
                        if (_isPaginated) {
                          _maybeFollowTts(state);
                        } else {
                          _maybeFollowTtsScroll(state);
                        }
                      },
                      icon: const Icon(Icons.my_location_rounded, size: 18),
                      label: const Text('Follow narration'),
                      style: FilledButton.styleFrom(
                        backgroundColor: TtsHighlightText.fillColor,
                        foregroundColor: TtsHighlightText.textColor,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          if (prefs.autoScrollButton)
            ReaderAutoScrollButton(
              autoScroll: _autoScroll,
              onTap: _openAutoScrollSheet,
              initialX: prefs.autoScrollButtonX,
              initialY: prefs.autoScrollButtonY,
              onMoved: prefs.setAutoScrollButtonPos,
            ),
        ],
      ),
    );
  }

  // ── read-aloud's view of the chapter list ──────────────────────────────────

  int get chapterCountForTts => _chapters.length;

  Episode? chapterAtForTts(int i) =>
      (i >= 0 && i < _chapters.length) ? _chapters[i] : null;

  String chapterTitleForTts(int i) => _chapterLabel(i) ?? 'Chapter ${i + 1}';

  /// Feeds read-aloud from the reader's own chapter list.
  ///
  /// Reads the live list rather than a copy, so a Continue-Reading resume that
  /// widens to the full chapter list in the background is picked up without the
  /// coordinator having to be told.
  ///
  /// Fetches through [SourceRepository] exactly as the reader does, rather than
  /// talking to a source directly: that is the layer that already handles plugin
  /// routing, headers and per-source quirks, and duplicating it here would mean
  /// two code paths that drift.
  String? _chapterLabel(int? i) {
    if (i == null || i < 0 || i >= _chapters.length) return null;
    final t = _chapters[i].title.trim();
    return t.isNotEmpty ? t : 'Chapter ${chapterNumberLabel(_chapters, i)}';
  }

  Widget _buildBody(_ReaderTheme theme, ReaderPrefs prefs) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          color: theme.text.withValues(alpha: 0.6),
        ),
      );
    }
    if (_error != null) return _buildError(theme);
    final text = _text;
    if (text == null) return const SizedBox.shrink();

    // Optional page-flip mode. When off (the default) the scroll path below is
    // left exactly as it was — same widgets, same restore, same behavior.
    if (prefs.novelPaginated) return _buildPaged(theme, prefs, text);

    final base = _baseTextStyle(prefs);
    final hasNext = _nextIndex != null;
    // Same condition the old trailing `if (_atEnd && hasNext)` child used —
    // just expressed as one extra sliver, so it only exists (and only adds
    // to maxScrollExtent) once the chapter's actually been scrolled to the
    // bottom.
    final showNext = _atEnd && hasNext;
    final direction = resolveNovelDirection(prefs, _html ?? text.html);
    // Measured here, where the width is known, so the follow can reach a block
    // the sliver list has not built. Deferred past the frame: it costs one text
    // layout per block and has no business delaying the chapter's first paint.
    if (_scrollLayout != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureBlockMetrics(prefs, base);
      });
    }

    // One `Text.rich` per block, built from the same `NovelTextLayout` the
    // read-aloud sentences were segmented from.
    //
    // This used to hand the chapter to `HtmlWidget`, which owns its text, and a
    // widget that owns the text cannot be handed a decorated copy of it — so
    // read-aloud had no way to mark the sentence being read. Reikai solves this
    // by rendering in a WebView and toggling a CSS class on the DOM element,
    // which highlights whole paragraphs because an element is the smallest
    // thing a class can go on. We already hold a character range for the exact
    // sentence, so this builds the blocks from our own tokens instead and gets
    // sentence-level precision. See `novelBlockSpans`.
    //
    // The cost is honest and worth naming: an `<img>` inside a chapter no longer
    // renders, where `HtmlWidget` handled it. Novels from the sources this reads
    // do not use inline images, and a chapter that did would show its text with
    // the picture missing.
    //
    // Still lazy, which is what `RenderMode.sliverList` was bought for:
    // `SliverList.builder` only lays out the blocks near the viewport. Same
    // `_scrollController`, so progress, resume and mark-read — all
    // pixels/maxScrollExtent based — are untouched.
    return SafeArea(
      child: Directionality(
        textDirection: direction,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.symmetric(
                horizontal: prefs.marginWidth,
                vertical: _readerContentVerticalPadding,
              ),
              sliver: SliverList.builder(
                itemCount: _scrollLayout?.blocks.length ?? 0,
                itemBuilder: (context, i) =>
                    _ttsScrollBlock(context, i, base, prefs),
              ),
            ),
            if (showNext)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 28, bottom: 40),
                  child: Center(
                    child: TextButton(
                      onPressed: () => _goToChapter(_nextIndex),
                      child: Text(
                        context.l10n.nextChapter2,
                        style: AppText.body.copyWith(color: AppColors.accent),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One paragraph of the scrolling reader, highlighted if it holds the sentence
  /// being read.
  ///
  /// Rebuilds only when the spoken sentence changes: [BlocBuilder]'s
  /// `buildWhen` keeps a settings change or a scroll from re-laying the chapter
  /// out, and when it does rebuild, [SliverList] only rebuilds what is near the
  /// viewport.
  Widget _ttsScrollBlock(
    BuildContext context,
    int blockIndex,
    TextStyle base,
    ReaderPrefs prefs,
  ) {
    final layout = _scrollLayout;
    if (layout == null) return const SizedBox.shrink();
    final tts = _tts;
    if (tts == null) {
      return _scrollBlockText(blockIndex, base, prefs);
    }

    return BlocBuilder<TtsCubit, TtsState>(
      bloc: tts,
      buildWhen: (a, b) =>
          a.currentIndex != b.currentIndex || a.isActive != b.isActive,
      builder: (context, state) {
        // The range comes from the sentence the cubit is actually speaking — the
        // same object the player's panel quotes — rather than from this screen's
        // own copy of the alignment. Two copies of the same segmentation can
        // drift apart (a chapter adopted from HTML falls back to no offsets at
        // all, a re-parse lands on a different split), and when they do the box
        // ends up marking a different, shorter stretch of words than the voice is
        // reading: a highlight that stops mid-sentence and looks broken.
        final view = state.currentSentence;
        final speaking =
            (state.isActive || _ttsRestoreFollowing) &&
            view != null &&
            view.isHighlightable;
        return _scrollBlockText(
          blockIndex,
          base,
          prefs,
          highlightStart: speaking ? view.start : null,
          highlightEnd: speaking ? view.end : null,
        );
      },
    );
  }

  Widget _scrollBlockText(
    int blockIndex,
    TextStyle base,
    ReaderPrefs prefs, {
    int? highlightStart,
    int? highlightEnd,
  }) {
    final layout = _scrollLayout;
    if (layout == null) return const SizedBox.shrink();
    final slice = (highlightStart != null && highlightEnd != null)
        ? blockSliceFor(layout, blockIndex, highlightStart, highlightEnd)
        : null;
    return Padding(
      // The gap the old `margin: 0 0 paragraphSpacing` produced, now expressed
      // in Flutter's layout rather than CSS.
      padding: EdgeInsets.only(bottom: prefs.paragraphSpacing),
      child: TtsHighlightText(
        span: TextSpan(
          style: base,
          children: novelBlockSpans(layout, blockIndex, base: base),
        ),
        textAlign: prefs.textAlignJustify ? TextAlign.justify : TextAlign.start,
        rangeStart: slice?.from,
        rangeEnd: slice?.to,
      ),
    );
  }

  /// Keeps the sentence being read near the middle of the screen.
  ///
  /// Driven by the coordinator's stream rather than by a block's own builder,
  /// and that is the whole trick. A block widget can only ever follow itself: a
  /// `SliverList` does not build the blocks off screen, so the block holding the
  /// spoken sentence — the one place a follow could be triggered from — is not
  /// in the tree until the reader is already there. Asking a block to scroll to
  /// itself waits for the very scroll it was supposed to cause.
  ///
  /// So the sentence is located arithmetically instead: its offset gives a
  /// block, the block's measured y gives a scroll position, and no widget has to
  /// exist. Measured with the same painter the paginator uses, so the position
  /// is the one the scroll view actually produces rather than an estimate that
  /// lands a paragraph out on every sentence.
  ///
  /// ### Centred, not merely visible
  ///
  /// Bringing a sentence to the top edge technically "follows" it and is what
  /// this did first, but it reads like a page turning under you: the sentence
  /// being spoken sits in the corner, the next screenful of prose is jammed
  /// below it, and someone who wants to read along has nowhere to look. Holding
  /// it near the middle leaves the text above *and* below on screen, which is
  /// what makes reading along possible at all.
  double? _ttsScrollTarget(TtsState state) {
    final layout = _scrollLayout;
    final offsets = _blockOffsets;
    final width = _blockWidth;
    final base = _blockStyle;
    if (layout == null || offsets == null || width == null || base == null) {
      return null;
    }
    // The same sentence the panel is quoting, so the view follows the words the
    // voice is actually on rather than a second segmentation's idea of them.
    final view = state.currentSentence;
    if (view == null || !view.isHighlightable) return null;
    final block = view.blockIndex;
    if (block < 0 || block + 1 >= offsets.length) return null;
    if (!_scrollController.hasClients) return null;

    final position = _scrollController.position;
    if (!position.hasContentDimensions) return null;

    final yInBlock = _sentenceTopInBlock(
      layout: layout,
      base: base,
      width: width,
      blockIndex: block,
      start: view.start,
      end: view.end,
    );

    return ttsFollowScrollTarget(
      blockOffset: offsets[block],
      sentenceOffset: yInBlock,
      contentTopInset: _readerContentVerticalPadding,
      scrollOffset: position.pixels,
      viewportHeight: position.viewportDimension,
      anchorFraction: _ttsFollowAnchor,
      toleranceFraction: _ttsFollowTolerance,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
    );
  }

  void _maybeFollowTtsScroll(TtsState state) {
    if (!state.isSpeaking && !_ttsRestoreFollowing) return;
    if (_isPaginated) return; // paged mode turns the page instead
    if (!sl<ReaderPrefs>().novelFollowNarration && !_ttsRestoreFollowing) {
      return;
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;

    // Their scroll wins for a moment. Yanking the page back mid-drag is the
    // fastest way to make an auto-follow feel broken; after the grace the
    // sentence takes over again, so pausing it does not mean switching it off.
    final sinceScroll =
        DateTime.now().millisecondsSinceEpoch - _lastManualScroll;
    if (sinceScroll < _ttsScrollGraceMs && !_ttsRestoreFollowing) return;

    // Only the first line matters: a long sentence spanning six lines cannot
    // be centred, and chasing its middle would scroll the page on every one of
    // its sentences.
    final target = _ttsScrollTarget(state);
    if (target == null) return;
    _manualTtsFollowNeeded = false;
    // Animated, so a sentence that starts a couple of lines lower glides there
    // instead of teleporting the text out from under the reader's eye.
    // New sentences can retarget an in-flight animation.
    position.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// Where the sentence's first line falls inside its block, in pixels.
  ///
  /// 0 when it cannot be measured, which degrades to centring the paragraph —
  /// the old behaviour — rather than to no follow at all.
  double _sentenceTopInBlock({
    required NovelTextLayout layout,
    required TextStyle base,
    required double width,
    required int blockIndex,
    required int start,
    required int end,
  }) {
    final slice = blockSliceFor(layout, blockIndex, start, end);
    if (slice == null) return 0;
    final boxes = ttsHighlightBoxes(
      span: TextSpan(
        style: base,
        children: novelBlockSpans(layout, blockIndex, base: base),
      ),
      start: slice.from,
      end: slice.to,
      maxWidth: width,
      textDirection: Directionality.of(context),
      textAlign: _textAlign,
      textScaler: MediaQuery.textScalerOf(context),
    );
    if (boxes.isEmpty) return 0;
    return boxes.first.top;
  }

  TextAlign get _textAlign =>
      sl<ReaderPrefs>().textAlignJustify ? TextAlign.justify : TextAlign.start;

  /// Where the followed sentence is held, as a fraction of the viewport.
  ///
  /// Just above the middle: that is where the eye rests while reading, and it
  /// leaves more of the *next* text visible below than a true centre would.
  static const double _ttsFollowAnchor = 0.45;

  /// How far the sentence may drift from [_ttsFollowAnchor] before the page
  /// moves, as a fraction of the viewport.
  ///
  /// A dead zone on purpose. Without one, every sentence re-centres the page and
  /// a paragraph of short lines turns into constant scrolling; with it, the view
  /// moves in calm steps and stays put while the reading position is comfortable.
  static const double _ttsFollowTolerance = 0.05;

  /// How long the reader's own scroll suppresses the follow, in milliseconds.
  static const int _ttsScrollGraceMs = 4000;

  /// Lays the chapter out once so the follow can reach blocks that were never
  /// built. Cached against everything that changes the answer, because it costs
  /// one text layout per block.
  void _ensureBlockMetrics(ReaderPrefs prefs, TextStyle base) {
    final layout = _scrollLayout;
    if (layout == null || layout.blocks.isEmpty) return;
    final width = (MediaQuery.sizeOf(context).width - prefs.marginWidth * 2)
        .clamp(1.0, double.infinity);
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final key =
        '${identityHashCode(layout)}|${base.hashCode}'
        '|${textScaler.hashCode}|$textDirection'
        '|${width.toStringAsFixed(1)}|${prefs.paragraphSpacing}';
    if (key == _blockMetricsKey) return;
    _blockMetricsKey = key;
    // Kept so the follow measures the sentence against the same width and style
    // the block was laid out with; measuring at a different width is how a
    // highlight ends up a line out of place.
    _blockWidth = width;
    _blockStyle = base;
    _blockOffsets = measureBlockOffsets(
      layout,
      style: base,
      width: width,
      paragraphSpacing: prefs.paragraphSpacing,
      textDirection: textDirection,
      textScaler: textScaler,
    );
    // A sentence can start speaking before the first frame has produced
    // metrics. Re-check once they exist so following does not depend on another
    // TTS event arriving later.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tts != null) _maybeFollowTtsScroll(_tts!.state);
    });
  }

  /// The page text, with the spoken sentence boxed when [rangeStart] is set.
  ///
  /// The soft fill replaces the old colour wash in both reader modes rather
  /// than layering two competing highlights over the spoken sentence.
  Widget _pageText(
    TextSpan page,
    ReaderPrefs prefs, {
    int? rangeStart,
    int? rangeEnd,
  }) => TtsHighlightText(
    span: page,
    textAlign: prefs.textAlignJustify ? TextAlign.justify : TextAlign.start,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
  );

  /// The slice of the page currently on screen that the spoken sentence covers.
  ///
  /// Read off the cubit's own sentence — the one the panel quotes — for the same
  /// reason the scrolling reader does: two segmentations can disagree, and a
  /// highlight drawn from the wrong one marks words nobody is hearing.
  ///
  /// Null when nothing is being read, or when the sentence is on another page —
  /// which is also the case that makes [_maybeFollowTts] turn to it, so there is
  /// nothing to draw here anyway.
  ({int from, int to})? _ttsPageSlice(
    List<TextSpan> pages,
    int pageIndex,
    TtsState ttsState,
  ) {
    if (!ttsState.isActive && !_ttsRestoreFollowing) return null;
    final view = ttsState.currentSentence;
    if (view == null || !view.isHighlightable) return null;
    return pageSliceFor(pages, pageIndex, view.start, view.end);
  }

  /// How long after a page turn the reader is considered to be in control.
  ///
  /// A read-aloud auto-turn that fires while someone is swiping pages themselves
  /// is worse than no auto-turn at all: it fights them for the page, several
  /// times a minute, and the highlight stops being a way to follow along. Five
  /// seconds is long enough to cover a deliberate turn and a re-read of the
  /// previous sentence, short enough that narration is not ignored for long.
  static const int _ttsPageTurnGraceMs = 5000;

  /// Turns the page when narration moves onto a page the reader is not looking
  /// at.
  ///
  /// Without this, a spoken sentence on the next page is simply invisible — the
  /// highlight is painting somewhere off-screen, which makes read-aloud in paged
  /// mode feel broken even though it is working. Skipped while the reader is
  /// paging themselves (see [_ttsPageTurnGraceMs]) so it assists rather than
  /// takes over.
  void _maybeFollowTts(TtsState state) {
    final pages = _pages;
    if (_ttsAligned == null ||
        pages.isEmpty ||
        (!state.isSpeaking && !_ttsRestoreFollowing)) {
      return;
    }

    final target = _ttsPageTarget(state);
    if (target == null || target == _pageIndex) return;

    final since = DateTime.now().millisecondsSinceEpoch - _lastManualPageTurn;
    if (since < _ttsPageTurnGraceMs && !_ttsRestoreFollowing) return;
    if (_ttsTurningPage) return;

    _ttsTurningPage = true;
    _manualTtsFollowNeeded = false;
    // Post-frame: this is called from a builder, and jumping the controller
    // mid-build is not allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ttsTurningPage = false;
      if (!mounted || !_pageController.hasClients) return;
      if (_pageController.page?.round() == target) return;
      _pageController.jumpToPage(target);
    });
  }

  int? _ttsPageTarget(TtsState state) {
    final aligned = _ttsAligned;
    if (aligned == null || _pages.isEmpty) return null;
    final range = aligned.rangeAt(state.currentIndex);
    if (range == null) return null;
    return pageIndexForRange(_pages, range.start, range.end);
  }

  /// Read-aloud settings: voice, speed, pitch, sleep timer, background
  /// playback, and the resume offer.
  ///
  /// Every control writes straight through to the cubit, so a change is audible
  /// on the next sentence rather than after a stop and restart — the whole point
  /// of a settings sheet you open *during* a listen.
  void _openTtsSheet() {
    final tts = _tts;
    if (tts == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => BlocProvider<TtsCubit>.value(
        value: tts,
        child: BlocBuilder<TtsCubit, TtsState>(
          bloc: tts,
          builder: (context, state) {
            void apply(VoidCallback change) {
              change();
              // The sheet is a separate route, so it does not see the reader's
              // rebuilds; repaint it from the state it just changed.
              if (sheetContext.mounted) {
                (sheetContext as Element).markNeedsBuild();
              }
            }

            return SafeArea(
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      readerSheetSection('Read-aloud settings'),
                      _ttsVoiceRow(tts, apply),
                      readerSheetSection('Speed and pitch'),
                      readerSheetGroup([
                        readerSheetRow(
                          icon: Icons.speed_rounded,
                          label: 'Speed',
                          trailing: Text(
                            // Same formatter as the player's speed chip, so the
                            // two cannot print one speed two ways.
                            TtsSpeed.label(state.rate),
                            style: AppText.body.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                          child: Slider(
                            value: state.rate
                                .clamp(TtsSpeed.min, TtsSpeed.max)
                                .toDouble(),
                            min: TtsSpeed.min,
                            max: TtsSpeed.max,
                            // Fine-grained 0.1 steps across 0.5-3.0; the player
                            // chip offers the simpler 1x–3x preset cycle.
                            divisions: 25,
                            onChanged: (v) => apply(() => tts.setRate(v)),
                          ),
                        ),
                        readerSheetRow(
                          icon: Icons.graphic_eq_rounded,
                          label: 'Pitch',
                          trailing: Text(
                            state.pitch.toStringAsFixed(1),
                            style: AppText.body.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                          child: Slider(
                            value: state.pitch.clamp(0.5, 2.0).toDouble(),
                            min: 0.5,
                            max: 2.0,
                            divisions: 15,
                            onChanged: (v) => apply(() => tts.setPitch(v)),
                          ),
                        ),
                        readerSheetRow(
                          icon: Icons.more_time_rounded,
                          label: 'Gap between sentences',
                          trailing: Text(
                            TtsSentenceGap.labelAt(state.sentenceGap),
                            style: AppText.body.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                          child: Slider(
                            value: state.sentenceGap
                                .clamp(TtsSentenceGap.min, TtsSentenceGap.max)
                                .toDouble(),
                            min: TtsSentenceGap.min.toDouble(),
                            max: TtsSentenceGap.max.toDouble(),
                            // One step per gap, and no more. A continuous gap
                            // gives a slider that rests between two labels while
                            // showing one of them, which reads as a control that
                            // is not quite doing what it says.
                            divisions: TtsSentenceGap.max - TtsSentenceGap.min,
                            onChanged: (v) =>
                                apply(() => tts.setSentenceGap(v.round())),
                          ),
                        ),
                      ]),
                      readerSheetSection('Session'),
                      readerSheetGroup([
                        readerSheetRow(
                          icon: Icons.bedtime_rounded,
                          label: 'Stop after',
                          trailing: Text(
                            state.sleepTimerMinutes <= 0
                                ? 'Off'
                                : '${state.sleepTimerMinutes} min',
                            style: AppText.body.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                          onTap: () => _ttsSleepSheet(tts, apply),
                        ),
                        readerSheetRow(
                          icon: Icons.screen_lock_portrait_rounded,
                          label: 'Keep reading with the screen off',
                          trailing: Switch(
                            value: state.backgroundPlayback,
                            onChanged: (v) =>
                                apply(() => tts.setBackgroundPlayback(v)),
                          ),
                        ),
                      ]),
                      if (tts.resumePointFor(state.bookId, state.chapterId)
                          case final point?)
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.restore_rounded,
                            label:
                                'Resume from sentence '
                                '${tts.resolveResumeIndex(point) + 1}',
                            onTap: () {
                              final index = tts.resolveResumeIndex(point);
                              Navigator.of(sheetContext).maybePop();
                              apply(() => tts.play(from: index));
                            },
                          ),
                        ]),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Sleep timer, as a sheet of presets rather than a picker: the useful values
  /// are a handful, and the panel is already a sheet over a sheet.
  void _ttsSleepSheet(TtsCubit tts, void Function(VoidCallback) apply) {
    const options = <int>[0, 5, 10, 15, 30, 45, 60, 90];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in options)
                ListTile(
                  title: Text(m <= 0 ? 'Off' : '$m minutes'),
                  onTap: () {
                    Navigator.of(sheetContext).maybePop();
                    apply(() => tts.setSleepTimer(m));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The voice picker. Only voices the engine actually offers, so the list is
  /// never a row of "Default" that does nothing.
  Widget _ttsVoiceRow(TtsCubit tts, void Function(VoidCallback) apply) {
    return readerSheetGroup([
      readerSheetRow(
        icon: Icons.record_voice_over_rounded,
        label: 'Voice',
        onTap: () => _ttsVoicePicker(tts, apply),
        trailing: FutureBuilder<List<TtsVoice>>(
          future: tts.voices(),
          builder: (context, snap) {
            final selected = tts.state.voiceName;
            final voices = snap.data;
            // Resolved here rather than in the picker so the row shows a real
            // name the moment the engine answers, instead of a bare id.
            var name = 'Default (system)';
            if (selected != null && voices != null) {
              for (final v in voices) {
                if (v.name == selected) {
                  name = '${v.locale} - ${v.qualityLabel}';
                  break;
                }
              }
              if (name == 'Default (system)') name = selected;
            }
            return Text(
              name,
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            );
          },
        ),
      ),
    ]);
  }

  void _ttsVoicePicker(TtsCubit tts, void Function(VoidCallback) apply) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxHeight: 420),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(18),
          ),
          child: FutureBuilder<List<TtsVoice>>(
            future: tts.voices(),
            builder: (context, snap) {
              final voices = snap.data;
              if (voices == null) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (voices.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'This device has no text-to-speech voices installed.',
                    style: AppText.body,
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: const Text('Default (system)'),
                    onTap: () {
                      Navigator.of(sheetContext).maybePop();
                      apply(() => tts.setVoice(null));
                    },
                  ),
                  for (final v in voices)
                    ListTile(
                      title: Text('${v.locale} - ${v.qualityLabel}'),
                      onTap: () {
                        Navigator.of(sheetContext).maybePop();
                        apply(() => tts.setVoice(v.name));
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildError(_ReaderTheme theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 40,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: AppText.body.copyWith(color: theme.text),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _load,
              child: Text(
                context.l10n.retry,
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Page-flip (book) mode: the same styled text split into page-sized
  /// [TextSpan]s by [paginateSpans] and shown in a horizontal [PageView].
  /// Left/right thirds turn the page, the center toggles chrome — the novel's
  /// analogue of the manga reader's tap zones. The scroll reader is untouched
  /// by this path; `prefs.novelPaginated` picks between them in `_buildBody`.
  Widget _buildPaged(_ReaderTheme theme, ReaderPrefs prefs, ChapterText text) {
    final base = _baseTextStyle(prefs);
    final direction = resolveNovelDirection(prefs, _html ?? text.html);
    return SafeArea(
      child: Directionality(
        // Same auto/user-forced direction as the scroll reader. `textAlign:
        // start` and `AlignmentDirectional.topStart` below then resolve
        // against it, so an RTL chapter's pages read right-to-left.
        textDirection: direction,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The page's text area, matching the item padding below exactly
            // (horizontal margin each side, 32 top + 32 bottom) so a paginated
            // page fills the view without ever overflowing it.
            final pageSize = Size(
              (constraints.maxWidth - prefs.marginWidth * 2).clamp(
                1.0,
                double.infinity,
              ),
              (constraints.maxHeight - 64).clamp(1.0, double.infinity),
            );
            _ensurePaginated(_html ?? text.html, base, pageSize);
            final pages = _pages;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _dispatchTap(d.globalPosition),
              child: PageView.builder(
                controller: _pageController,
                itemCount: pages.isEmpty ? 1 : pages.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, index) {
                  if (pages.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: prefs.marginWidth,
                      vertical: 32,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      // Scoped to the page text rather than the whole reader:
                      // the highlight changes on every sentence, and rebuilding
                      // the chrome, the tap handling and the pagination
                      // bookkeeping several times a minute would be wasteful
                      // for a change that only affects these spans.
                      child: _tts == null
                          ? _pageText(pages[index], prefs)
                          : BlocBuilder<TtsCubit, TtsState>(
                              bloc: _tts,
                              buildWhen: (a, b) =>
                                  a.currentIndex != b.currentIndex ||
                                  a.isActive != b.isActive,
                              builder: (context, ttsState) {
                                // Called from the builder, not from a listener,
                                // so it is already scheduled to run after the
                                // frame that shows the new highlight.
                                _maybeFollowTts(ttsState);
                                final slice = _ttsPageSlice(
                                  pages,
                                  index,
                                  ttsState,
                                );
                                return _pageText(
                                  pages[index],
                                  prefs,
                                  rangeStart: slice?.from,
                                  rangeEnd: slice?.to,
                                );
                              },
                            ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// Recomputes pagination only when the chapter, text style, or page size
  /// changes (not on every rebuild), then jumps the [PageController] to the
  /// resume/carry-over page. A never-read chapter with empty `_pages` uses its
  /// saved permille (0 → page 0); a re-paginate (font/size/rotation) carries
  /// the live position so the reader stays roughly in place.
  void _ensurePaginated(String html, TextStyle base, Size pageSize) {
    final key =
        '${identityHashCode(_html)}|${base.fontSize}|${base.fontFamily}'
        '|${base.height}|${base.letterSpacing}|${base.wordSpacing}'
        '|${pageSize.width.toStringAsFixed(1)}'
        '|${pageSize.height.toStringAsFixed(1)}';
    if (key == _paginationKey) return;
    final carry = _pages.isEmpty ? _savedPermille() : _pagedPermille();
    _paginationKey = key;
    final spans = novelSpans(html, base); // paragraphSpacing 0 → pure TextSpans
    _pages = paginateSpans(
      TextSpan(style: base, children: spans),
      pageSize: pageSize,
      style: base,
    );
    final target = _pageForPermille(carry, _pages.length);
    _pageIndex = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      if (_pageController.page?.round() != target) {
        _pageController.jumpToPage(target);
      }
    });
  }

  void _onPageChanged(int index) {
    // Read-aloud's own jump, not the reader reaching for the page: it defers to
    // the reader for a grace period after *they* turn one, and its own turn
    // would otherwise reset that clock and stop it ever following along.
    if (!_ttsTurningPage) {
      _lastManualPageTurn = DateTime.now().millisecondsSinceEpoch;
    }
    if (index == _pageIndex) return; // e.g. the restore jump landing on target
    setState(() => _pageIndex = index); // refresh the page x / y indicator
    _saveProgress(flush: false); // same save/scrobble path as scroll mode
  }

  /// Run whatever the reader's tap zones say for a tap at [global].
  ///
  /// Paged and scroll mode use different layouts: turning a page means nothing
  /// in a continuous scroll, and scrolling means nothing on a fixed page.
  void _dispatchTap(Offset global) {
    final size = MediaQuery.sizeOf(context);
    if (size.width <= 0 || size.height <= 0) return;
    final prefs = sl<ReaderPrefs>();
    // Novels are laid out left-to-right whichever manga mode is set, so the
    // paged layout is read directly rather than through the reading mode.
    final layout = prefs.tapZones(
      prefs.novelPaginated ? TapZoneLayout.paged : TapZoneLayout.webtoon,
    );
    _runReaderAction(
      layout.actionAt(
        Offset(
          (global.dx / size.width).clamp(0.0, 1.0),
          (global.dy / size.height).clamp(0.0, 1.0),
        ),
      ),
    );
  }

  void _runReaderAction(ReaderAction action) {
    const dur = Duration(milliseconds: 200);
    switch (action) {
      case ReaderAction.none:
        return;
      case ReaderAction.toggleMenu:
        _toggleChrome();
      case ReaderAction.nextPage:
        if (_pageController.hasClients) {
          _pageController.nextPage(duration: dur, curve: Curves.easeOut);
        }
      case ReaderAction.prevPage:
        if (_pageController.hasClients) {
          _pageController.previousPage(duration: dur, curve: Curves.easeOut);
        }
      case ReaderAction.scrollUp:
        _scrollBy(-1);
      case ReaderAction.scrollDown:
        _scrollBy(1);
      case ReaderAction.nextChapter:
        _goToChapter(_nextIndex);
      case ReaderAction.prevChapter:
        _goToChapter(_prevIndex);
    }
  }

  /// One screenful, less a sliver of overlap so the line you were on is still
  /// on screen after the jump.
  void _scrollBy(int direction) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final step = pos.viewportDimension * 0.85 * direction;
    _scrollController.animateTo(
      (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  // Chrome bars are always white-on-scrim now, matching the manga reader —
  // a shared dark overlay reads over any of the three page themes (dark/
  // black/sepia) the same way the player's own control bars read over any
  // video, so these no longer take the page theme as a parameter.
  Widget _buildTopBar() {
    // IgnorePointer, not the old `if (_chromeVisible) build it at all` — the
    // bar is always in the tree so AnimatedOpacity has something to fade,
    // but that means it'd otherwise sit invisible on top of the page
    // catching taps meant for chrome-toggle underneath. Ignoring while
    // hidden keeps that tap zone working exactly as before.
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_chromeVisible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _chromeVisible ? 1 : 0,
          // Same floating pills as the manga reader: back · title (tap for
          // chapters) · settings.
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ReaderPillIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: context.l10n.back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: ReaderTitlePill(
                      title: widget.showTitle,
                      subtitle:
                          'Chapter ${chapterNumberLabel(_chapters, _index)}'
                          ' / ${chapterCountLabel(_chapters)}',
                      onTap: _openChapterSheet,
                    ),
                  ),
                  const SizedBox(width: 9),
                  ReaderPillIconButton(
                    icon: Icons.more_vert_rounded,
                    tooltip: context.l10n.readerSettings,
                    onTap: _openSettingsSheet,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Start/stop hands-free reading. Both modes: scroll mode creeps, paged mode
  /// turns a page every so often.
  void _setAutoScroll(bool on) {
    final prefs = sl<ReaderPrefs>();
    _autoScroll.speed = prefs.autoScrollSpeed;
    if (!on) {
      _autoScroll.stop();
      return;
    }
    if (prefs.novelPaginated) {
      _autoScroll.start(
        advancePage: () => _pageController.nextPage(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        ),
      );
    } else {
      if (!_scrollController.hasClients) return;
      _autoScroll.start(controller: _scrollController);
    }
    if (_chromeVisible) setState(() => _chromeVisible = false);
  }

  void _openAutoScrollSheet() {
    final prefs = sl<ReaderPrefs>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ReaderAutoScrollSheet(
        running: _autoScroll.running.value,
        speed: prefs.autoScrollSpeed,
        showButton: prefs.autoScrollButton,
        onToggle: _setAutoScroll,
        onSpeed: (v) {
          prefs.setAutoScrollSpeed(v);
          _autoScroll.speed = v;
        },
        onShowButton: (v) {
          prefs.setAutoScrollButton(v);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Widget _buildBottomBar() {
    final hasPrev = _prevIndex != null;
    final hasNext = _nextIndex != null;
    final paged = sl<ReaderPrefs>().novelPaginated;
    // Same IgnorePointer-while-hidden reasoning as _buildTopBar.
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_chromeVisible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _chromeVisible ? 1 : 0,
          // One floating pill: prev · page slider · text size · next.
          // The slider only exists in PAGED mode, where pages are discrete and
          // a PageController can jump to one. Scrolling mode has no page to
          // seek to — its position is a scroll fraction that only settles after
          // layout — so it gets the plain label instead of a slider that would
          // fight the resume logic.
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: ReaderBottomPill(
                children: [
                  readerBarButton(
                    Icons.skip_previous_rounded,
                    () => _goToChapter(_prevIndex),
                    enabled: hasPrev,
                  ),
                  Expanded(
                    child: paged && _pages.length > 1
                        ? ReaderSlider(
                            value: _pageIndex.toDouble().clamp(
                              0,
                              (_pages.length - 1).toDouble(),
                            ),
                            min: 0,
                            max: (_pages.length - 1).toDouble(),
                            divisions: _pages.length - 1,
                            onChanged: (v) {
                              final i = v.round();
                              if (i == _pageIndex) return;
                              setState(() => _pageIndex = i);
                              if (_pageController.hasClients) {
                                _pageController.jumpToPage(i);
                              }
                            },
                            onChangeEnd: (_) => _saveProgress(flush: true),
                          )
                        : Center(
                            child: Text(
                              paged
                                  ? 'Page ${_pageIndex + 1} / ${_pages.length}'
                                  : 'Chapter '
                                        '${chapterNumberLabel(_chapters, _index)}'
                                        ' / ${chapterCountLabel(_chapters)}',
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                  ),
                  // Novel-only: the one setting people change mid-read.
                  IconButton(
                    tooltip: context.l10n.textSize,
                    icon: const Icon(
                      Icons.format_size_rounded,
                      color: Colors.white,
                    ),
                    onPressed: _openTextSizeSheet,
                  ),
                  // Read-aloud. The one control that starts the feature, so it
                  // sits with the other transport: hidden entirely when the
                  // engine could never work, and a play/pause toggle while it is
                  // running rather than a button that silently does nothing.
                  if (_tts != null)
                    BlocBuilder<TtsCubit, TtsState>(
                      bloc: _tts,
                      // Only the icon depends on this, and it flips twice per
                      // session at most — rebuilding the whole bar on every
                      // sentence would fight the page slider for no reason.
                      buildWhen: (a, b) => a.isSpeaking != b.isSpeaking,
                      builder: (context, state) => readerBarButton(
                        state.isSpeaking
                            ? Icons.stop_rounded
                            : Icons.headphones_rounded,
                        state.isSpeaking ? _stopTts : _startTts,
                      ),
                    ),
                  readerBarButton(
                    Icons.skip_next_rounded,
                    () => _goToChapter(_nextIndex),
                    enabled: hasNext,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The novel prefs, live-applied: each change writes straight to
  /// [ReaderPrefs] and calls `setState` on both the sheet and the reader
  /// body so the text underneath re-styles immediately. Every row is built
  /// from reader_chrome.dart's shared readerSheetRow/ReaderSegmentedControl/
  /// readerSheetGroup pieces, so this sheet, the manga reader's, and
  /// Settings -> Reader all read as one design.
  /// Chapter list, opened by tapping the title pill. Same [_goToChapter] the
  /// prev/next buttons use, so progress saving and scrobbling are unchanged.
  void _openChapterSheet() {
    if (_chapters.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.noOtherChaptersLoadedYet)),
      );
      return;
    }
    const rowHeight = 52.0;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      // Not readerSheetBody: that wraps its children in a SingleChildScrollView,
      // and a lazy ListView inside one has no bounded height — it would try to
      // build all 100+ rows at once. Same grabber and title, own scrolling.
      builder: (ctx) => ReaderSheetShell(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(0, 8, 0, 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 2),
                child: Text(context.l10n.chapters, style: AppText.headline),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  '${chapterNumberLabel(_chapters, _index)}'
                  ' of ${chapterCountLabel(_chapters)}',
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              // Capped at half the screen: a long list would otherwise let the
              // shrink-wrapped ListView grow the sheet to full height, which
              // reads as a new page rather than a sheet over the reader.
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    controller: ScrollController(
                      initialScrollOffset: ((_index - 2) * rowHeight).clamp(
                        0,
                        double.infinity,
                      ),
                    ),
                    itemCount: _chapters.length,
                    itemExtent: rowHeight,
                    itemBuilder: (context, i) {
                      final current = i == _index;
                      return InkWell(
                        onTap: () {
                          Navigator.of(ctx).pop();
                          if (i != _index) _goToChapter(i);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 46,
                                child: Text(
                                  chapterNumberLabel(_chapters, i),
                                  style: AppText.caption.copyWith(
                                    color: current
                                        ? AppColors.accent
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  _chapters[i].title.trim().isNotEmpty
                                      ? _chapters[i].title
                                      : 'Chapter '
                                            '${chapterNumberLabel(_chapters, i)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.body.copyWith(
                                    color: current
                                        ? AppColors.accent
                                        : Colors.white,
                                    fontWeight: current
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (current)
                                Icon(
                                  Icons.play_arrow_rounded,
                                  size: 18,
                                  color: AppColors.accent,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Font size + line height only — the two things people reach for mid-read.
  /// Everything else (theme, font family, paged mode) stays in the full
  /// settings sheet rather than being duplicated here.
  ///
  /// Writes through the same prefs setters the settings sheet uses, so paged
  /// mode re-paginates through its usual path (`_paginationKey` notices the
  /// text style changed) instead of needing anything special here.
  void _openTextSizeSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final prefs = sl<ReaderPrefs>();
          void apply(VoidCallback change) {
            change();
            setSheetState(() {});
            if (mounted) setState(() {});
          }

          return readerSheetBody(
            context: ctx,
            title: context.l10n.textSize,
            subtitle: context.l10n.appliesStraightAway,
            children: [
              readerSheetSection('Text'),
              readerSheetGroup([
                readerSheetRow(
                  icon: Icons.format_size_rounded,
                  label: context.l10n.fontSize,
                  trailing: Text(
                    prefs.fontSize.round().toString(),
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  child: Slider(
                    value: prefs.fontSize.clamp(12, 28),
                    min: 12,
                    max: 28,
                    activeColor: AppColors.accent,
                    onChanged: (v) => apply(() => prefs.setFontSize(v)),
                  ),
                ),
                readerSheetRow(
                  icon: Icons.format_line_spacing_rounded,
                  label: context.l10n.lineHeight,
                  trailing: Text(
                    prefs.lineHeight.toStringAsFixed(1),
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  child: Slider(
                    value: prefs.lineHeight.clamp(1.2, 2.4),
                    min: 1.2,
                    max: 2.4,
                    activeColor: AppColors.accent,
                    onChanged: (v) => apply(() => prefs.setLineHeight(v)),
                  ),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final prefs = sl<ReaderPrefs>();
          void apply(VoidCallback change) {
            change();
            setSheetState(() {});
            if (mounted) setState(() {});
          }

          final fontOptions = <({String value, String label})>[
            for (final f in const ['inter', 'serif', 'system'])
              (value: f, label: _fontLabel(f)),
          ];
          final alignmentOptions = <({String value, String label})>[
            (value: 'left', label: context.l10n.left),
            (value: 'justify', label: context.l10n.justify),
          ];
          final directionOptions = <({String value, String label})>[
            (value: 'auto', label: context.l10n.auto),
            (value: 'ltr', label: context.l10n.ltr),
            (value: 'rtl', label: context.l10n.rtl),
          ];
          // Recomputed on every sheet rebuild, so picking a light theme pulls
          // the slider (and the page) back up to that theme's floor.
          final bgFloor = _bgOpacityFloor(_readerTheme(prefs.theme));
          final bgOpacity = prefs.novelBgOpacity.clamp(bgFloor, 1.0);

          return ReaderSheetShell(
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: AppColors.textTertiary.withValues(
                                alpha: 0.5,
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Text(
                          context.l10n.readerSettings,
                          style: AppText.headline,
                        ),
                        readerSheetSection('Text'),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.text_fields_rounded,
                            label: context.l10n.font,
                            child: ReaderSegmentedControl(
                              options: fontOptions,
                              selected: prefs.fontFamily,
                              onSelect: (v) =>
                                  apply(() => prefs.setFontFamily(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.format_size_rounded,
                            label: context.l10n.fontSize,
                            child: Slider(
                              value: prefs.fontSize.clamp(12, 28),
                              min: 12,
                              max: 28,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setFontSize(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.format_line_spacing_rounded,
                            label: context.l10n.lineHeight,
                            child: Slider(
                              value: prefs.lineHeight.clamp(1.2, 2.4),
                              min: 1.2,
                              max: 2.4,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setLineHeight(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.text_fields_rounded,
                            label: context.l10n.letterSpacing,
                            trailing: Text(
                              prefs.letterSpacing.toStringAsFixed(1),
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                            child: Slider(
                              value: prefs.letterSpacing.clamp(-0.5, 3),
                              min: -0.5,
                              max: 3,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setLetterSpacing(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.space_bar_rounded,
                            label: context.l10n.wordSpacing,
                            trailing: Text(
                              prefs.wordSpacing.toStringAsFixed(1),
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                            child: Slider(
                              value: prefs.wordSpacing.clamp(0, 10),
                              min: 0,
                              max: 10,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setWordSpacing(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.format_align_justify_rounded,
                            label: context.l10n.alignment,
                            child: ReaderSegmentedControl(
                              options: alignmentOptions,
                              selected: prefs.textAlignJustify
                                  ? 'justify'
                                  : 'left',
                              onSelect: (v) => apply(
                                () => prefs.setTextAlignJustify(v == 'justify'),
                              ),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.format_textdirection_r_to_l_rounded,
                            label: context.l10n.direction,
                            child: ReaderSegmentedControl(
                              options: directionOptions,
                              selected: prefs.textDirection,
                              onSelect: (v) =>
                                  apply(() => prefs.setTextDirection(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.view_stream_outlined,
                            label: context.l10n.paragraphSpacing,
                            child: Slider(
                              value: prefs.paragraphSpacing.clamp(0, 24),
                              min: 0,
                              max: 24,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setParagraphSpacing(v)),
                            ),
                          ),
                        ]),
                        readerSheetSection('Page'),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.format_indent_increase_rounded,
                            label: context.l10n.margin,
                            child: Slider(
                              value: prefs.marginWidth.clamp(0, 48),
                              min: 0,
                              max: 48,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setMarginWidth(v)),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.menu_book_rounded,
                            label: context.l10n.paginated,
                            trailing: Switch(
                              value: prefs.novelPaginated,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                // Persist the spot in the CURRENT mode first,
                                // then switch — so the other mode resumes from
                                // the same permille (see _ensurePaginated /
                                // _restoreScrollPosition).
                                _saveProgress(flush: false);
                                prefs.setNovelPaginated(v);
                                _paginationKey = null;
                                _pages = const [];
                                _pageIndex = 0;
                                if (!v) {
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (mounted) _restoreScrollPosition();
                                  });
                                }
                              }),
                            ),
                          ),
                        ]),
                        readerSheetSection(context.l10n.theme),
                        readerSheetGroup([
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 12,
                            ),
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 10,
                              children: [
                                for (final t in const [
                                  'dark',
                                  'black',
                                  'sepia',
                                  'gray',
                                  'paper',
                                ])
                                  _themeSwatch(
                                    t,
                                    prefs.theme == t,
                                    () => apply(() => prefs.setTheme(t)),
                                  ),
                              ],
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.brightness_2_outlined,
                            label: context.l10n.background,
                            trailing: Text(
                              '${(bgOpacity * 100).round()}%',
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                            child: Slider(
                              value: bgOpacity,
                              min: bgFloor,
                              max: 1,
                              activeColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setNovelBgOpacity(v)),
                            ),
                          ),
                        ]),
                        readerSheetSection('Navigation'),
                        readerSheetGroup([
                          // Read-aloud. Reachable from here as well as from the
                          // player's own gear, because the settings sheet is
                          // where someone goes to find a feature the reader has
                          // not started yet — the panel is behind a tap on the
                          // bottom bar, which a new reader has no reason to try.
                          if (_tts != null) ...[
                            readerSheetRow(
                              icon: _tts!.state.isSpeaking
                                  ? Icons.stop_rounded
                                  : Icons.headphones_rounded,
                              label: 'Read aloud',
                              trailing: _tts!.state.isSpeaking
                                  ? null
                                  : Icon(
                                      Icons.play_arrow_rounded,
                                      color: AppColors.accent,
                                      size: 20,
                                    ),
                              onTap: () {
                                Navigator.of(ctx).pop();
                                if (_tts!.state.isSpeaking) {
                                  _stopTts();
                                } else {
                                  _startTts();
                                }
                              },
                            ),
                            readerSheetRow(
                              icon: Icons.tune_rounded,
                              label: 'Read-aloud settings',
                              trailing: Icon(
                                Icons.chevron_right_rounded,
                                color: AppColors.textSecondary,
                                size: 20,
                              ),
                              onTap: () {
                                Navigator.of(ctx).pop();
                                _openTtsSheet();
                              },
                            ),
                            // Whether the page follows the voice in scrolling
                            // mode. Beside the other read-aloud rows because it
                            // is a read-aloud behaviour, and next to Auto-scroll
                            // because they look like the same feature and are
                            // not: this one moves the page to the sentence
                            // being spoken, the other creeps the page down on a
                            // timer.
                            readerSheetRow(
                              icon: Icons.my_location_rounded,
                              label: 'Follow narration',
                              trailing: Switch(
                                value: prefs.novelFollowNarration,
                                activeThumbColor: AppColors.accent,
                                onChanged: (v) => apply(
                                  () => prefs.setNovelFollowNarration(v),
                                ),
                              ),
                            ),
                          ],
                          readerSheetRow(
                            icon: Icons.play_circle_outline_rounded,
                            label: context.l10n.autoScroll,
                            trailing: Icon(
                              Icons.chevron_right_rounded,
                              color: AppColors.textSecondary,
                              size: 20,
                            ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _openAutoScrollSheet();
                            },
                          ),
                          readerSheetRow(
                            icon: Icons.swipe_vertical_rounded,
                            label: context.l10n.pullToChangeChapter,
                            trailing: Switch(
                              value: prefs.overscrollChapter,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) =>
                                  apply(() => prefs.setOverscrollChapter(v)),
                            ),
                          ),
                        ]),
                        readerSheetSection('Comfort'),
                        readerSheetGroup([
                          readerSheetRow(
                            icon: Icons.visibility_outlined,
                            label: context.l10n.keepScreenOn,
                            trailing: Switch(
                              value: prefs.keepScreenOn,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setKeepScreenOn(v);
                                applyReaderComfort();
                              }),
                            ),
                          ),
                          readerSheetRow(
                            icon: Icons.fullscreen_rounded,
                            label: context.l10n.readerFullscreen,
                            trailing: Switch(
                              value: prefs.fullscreen,
                              activeThumbColor: AppColors.accent,
                              onChanged: (v) => apply(() {
                                prefs.setFullscreen(v);
                                applyReaderComfort();
                              }),
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _fontLabel(String f) => switch (f) {
    'serif' => 'Serif',
    'system' => context.l10n.system,
    _ => 'Inter',
  };

  Widget _themeSwatch(String id, bool selected, VoidCallback onTap) {
    final theme = _readerTheme(id);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.bg,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? AppColors.accent
                : Colors.white.withValues(alpha: 0.16),
            width: selected ? 2 : 1,
          ),
        ),
        child: Center(
          child: Text(
            'A',
            style: TextStyle(color: theme.text, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _ReaderTheme {
  const _ReaderTheme(this.bg, this.text);
  final Color bg;
  final Color text;
}

/// The theme's page colour blended toward black by the `novelBgOpacity` pref.
/// At 1.0 (the default) this hands back the theme colour untouched. Blending
/// rather than an alpha so the page stays opaque — a translucent Scaffold would
/// show the route underneath.
Color _dimmedBg(_ReaderTheme theme, double opacity) => Color.lerp(
  Colors.black,
  theme.bg,
  opacity.clamp(_bgOpacityFloor(theme), 1.0),
)!;

/// How far down a theme may be dimmed. A light theme's text is dark, so taking
/// its page to black would leave the text unreadable — those stop at 0.75,
/// which still clears WCAG AA on sepia (~4.9:1).
double _bgOpacityFloor(_ReaderTheme theme) =>
    theme.bg.computeLuminance() > 0.5 ? 0.75 : 0.0;

_ReaderTheme _readerTheme(String theme) {
  switch (theme) {
    case 'black':
      return const _ReaderTheme(Colors.black, Color(0xFFDDDDDD));
    case 'sepia':
      return const _ReaderTheme(Color(0xFFF0E6D2), Color(0xFF4A3B2A));
    // Soft charcoal — easier on the eyes than true black at night without
    // going all the way to the app's own (near-black) 'dark' background.
    case 'gray':
      return const _ReaderTheme(Color(0xFF2B2B2E), Color(0xFFD6D6D6));
    // Warm off-white "paper" — lighter and more neutral than 'sepia', for
    // readers who want something closer to a printed page than a screen.
    case 'paper':
      return const _ReaderTheme(Color(0xFFFAF6EE), Color(0xFF2B2B2B));
    default: // 'dark'
      return _ReaderTheme(AppColors.bg, AppColors.textPrimary);
  }
}

/// Maps the `fontFamily` pref to a [TextStyle.fontFamily]. 'inter' uses the
/// bundled Inter family (same one the rest of the app's UI text uses);
/// 'serif' hands the engine the generic 'serif' name, which the Android
/// engine resolves to a real system serif font — no bundled asset needed;
/// 'system' returns null so the platform's default text font renders
/// untouched.
String? novelFontFamily(String key) => switch (key) {
  'serif' => 'serif',
  'system' => null,
  _ => 'Inter',
};

/// One decoded run of inline HTML — a text run with its bold/italic state,
/// or a break marker — the unit [novelSpans] walks raw chapter HTML into via
/// [_tokenizeHtml]. Only used by the paged (book) reader mode now; the
/// scroll reader hands its HTML straight to `HtmlWidget` instead (see
/// `_buildBody`).
class _HtmlToken {
  const _HtmlToken.text(this.text, {required this.bold, required this.italic})
    : isBreak = false,
      paragraphBreak = false;
  const _HtmlToken.brk({required this.paragraphBreak})
    : text = '',
      bold = false,
      italic = false,
      isBreak = true;

  final String text;
  final bool bold;
  final bool italic;
  final bool isBreak;
  // Only meaningful when [isBreak] is true: a closed `</p>` (block boundary)
  // vs. a bare `<br>` (soft line break within a paragraph, e.g. a poem line).
  final bool paragraphBreak;
}

/// Walks HTML into a flat list of [_HtmlToken]s for [novelSpans] (the paged
/// reader's only remaining consumer) — kept as its own function since it was
/// pulled out that way rather than folded back inline.
List<_HtmlToken> _tokenizeHtml(String html) {
  // `(?:</\1>|$)` (not just `</\1>`) so an unclosed <script>/<style> tag
  // still gets its raw content stripped through end-of-string instead of
  // leaking into the rendered chapter.
  final cleaned = html.replaceAll(
    RegExp(
      r'<(script|style)[^>]*>.*?(?:</\1>|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    '',
  );

  final tokens = <_HtmlToken>[];
  final buffer = StringBuffer();
  var bold = false;
  var italic = false;

  void flush() {
    if (buffer.isEmpty) return;
    tokens.add(_HtmlToken.text(buffer.toString(), bold: bold, italic: italic));
    buffer.clear();
  }

  final tagRe = RegExp(r'<[^>]*>');
  var last = 0;
  for (final m in tagRe.allMatches(cleaned)) {
    if (m.start > last) {
      buffer.write(_unescapeHtml(cleaned.substring(last, m.start)));
    }
    final tag = cleaned.substring(m.start, m.end).toLowerCase();
    if (tag.startsWith('</p') || tag.startsWith('<br')) {
      flush();
      tokens.add(_HtmlToken.brk(paragraphBreak: tag.startsWith('</p')));
    } else if (tag.startsWith('<b') || tag.startsWith('<strong')) {
      flush();
      bold = true;
    } else if (tag.startsWith('</b') || tag.startsWith('</strong')) {
      flush();
      bold = false;
    } else if (tag.startsWith('<i') || tag.startsWith('<em')) {
      flush();
      italic = true;
    } else if (tag.startsWith('</i') || tag.startsWith('</em')) {
      flush();
      italic = false;
    }
    // everything else (<p>, <div>, <span>, ...): stripped, no-op
    last = m.end;
  }
  if (last < cleaned.length) {
    buffer.write(_unescapeHtml(cleaned.substring(last)));
  }
  flush();
  return tokens;
}

/// HTML → styled spans for the novel body. Pure and top-level so it's
/// unit-testable without pumping a widget.
///
/// `<p>`/`<br>` become paragraph/line breaks, `<b>`/`<strong>` and
/// `<i>`/`<em>` become bold/italic spans, everything else (including
/// `<script>`/`<style>` and their contents) is stripped. A closed `<p>`
/// (not a bare `<br>` line break) additionally gets [paragraphSpacing] of
/// vertical gap via a full-width `WidgetSpan` — the standard way to get a
/// precise pixel gap between blocks inside one `Text.rich` without leaving
/// span-land for a widget-per-paragraph layout. Default 0 reproduces the
/// reader's original spacing exactly (just the `\n`), so every existing
/// caller is unaffected. What the page-flip paginator consumes — the scroll
/// reader renders its HTML directly via `HtmlWidget` instead (see
/// `_buildBody`).
/// Strips a chapter's own inline styling before it's handed to `HtmlWidget`,
/// so the source's baked-in font size / family / line height can't override
/// the reader's settings. Removes `<style>` blocks, `style="…"` attributes,
/// and `<font>` tags (keeping their text). Only the scroll reader's HTML path
/// uses this; the paginator keeps parsing the raw HTML via `novelSpans`.
String cleanNovelHtml(String html) {
  return html
      .replaceAll(
        RegExp(r'<style[^>]*>.*?</style>', dotAll: true, caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp('''\\sstyle\\s*=\\s*("[^"]*"|'[^']*')''', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'</?font[^>]*>', caseSensitive: false), '');
}

/// Matches characters from RTL scripts (Arabic + its supplement/presentation
/// blocks, plus Hebrew) so [resolveNovelDirection] can auto-detect direction
/// straight from chapter text — no per-source configuration needed.
final RegExp _rtlChar = RegExp(
  r'[\u0590-\u05FF\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
);

/// True if at least a third of a sample of the chapter's letters are from an
/// RTL script. A ratio (not "any match") avoids false positives on chapters
/// that are mostly Latin text with the odd Arabic name or quote embedded.
bool _looksRtl(String html) {
  // Clamp against the stripped text, not the html it came from: each tag
  // collapses to a single space, so `plain` is the shorter of the two, and
  // slicing it to the html's length overran the end on any chapter shorter
  // than the sample size.
  final stripped = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
  final plain = stripped.substring(
    0,
    stripped.length < 4000 ? stripped.length : 4000,
  );
  final letters = plain.replaceAll(RegExp(r'[^\p{L}]', unicode: true), '');
  if (letters.isEmpty) return false;
  final rtlCount = _rtlChar.allMatches(letters).length;
  return rtlCount / letters.length > 0.33;
}

/// Resolves the effective [TextDirection] for a chapter: an explicit user
/// choice in Settings wins outright, otherwise it's auto-detected from the
/// chapter's own text so Arabic (and other RTL) novels default to reading
/// right-to-left without a manual per-source toggle.
TextDirection resolveNovelDirection(ReaderPrefs prefs, String html) {
  switch (prefs.textDirection) {
    case 'rtl':
      return TextDirection.rtl;
    case 'ltr':
      return TextDirection.ltr;
    default:
      return _looksRtl(html) ? TextDirection.rtl : TextDirection.ltr;
  }
}

List<InlineSpan> novelSpans(
  String html,
  TextStyle base, {
  double paragraphSpacing = 0,
}) {
  final spans = <InlineSpan>[];
  for (final t in _tokenizeHtml(html)) {
    if (t.isBreak) {
      spans.add(const TextSpan(text: '\n'));
      if (t.paragraphBreak && paragraphSpacing > 0) {
        spans.add(
          WidgetSpan(
            child: SizedBox(height: paragraphSpacing, width: double.infinity),
          ),
        );
      }
      continue;
    }
    spans.add(
      TextSpan(
        text: t.text,
        style: base.copyWith(
          fontWeight: t.bold ? FontWeight.bold : null,
          fontStyle: t.italic ? FontStyle.italic : null,
        ),
      ),
    );
  }
  return spans;
}

const Map<String, String> _htmlEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
};

/// Decodes the handful of HTML entities real scraped chapter text actually
/// contains (named + numeric). Anything unrecognised — including a numeric
/// reference outside the valid Unicode code point range (`&#99999999;`,
/// which a source with odd markup can genuinely contain) — is left as-is
/// rather than crashing: [String.fromCharCode] throws a [RangeError] outside
/// 0..0x10FFFF, and this runs synchronously from `build()`, well outside the
/// try/catch that only guards the network fetch in `_load()`.
///
/// Lone UTF-16 surrogates (0xD800-0xDFFF) are deliberately NOT special-cased:
/// `String.fromCharCode` doesn't throw for them (confirmed), it just renders
/// as tofu — a display quirk, not a crash, so out of scope for this guard.
String _unescapeHtml(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (
    m,
  ) {
    final ref = m.group(1)!;
    if (ref.startsWith('#x')) {
      final code = int.tryParse(ref.substring(2), radix: 16);
      return _charOrRaw(code, m.group(0)!);
    }
    if (ref.startsWith('#')) {
      final code = int.tryParse(ref.substring(1));
      return _charOrRaw(code, m.group(0)!);
    }
    return _htmlEntities[ref] ?? m.group(0)!;
  });
}

String _charOrRaw(int? code, String raw) {
  if (code == null || code < 0 || code > 0x10FFFF) return raw;
  return String.fromCharCode(code);
}

/// Read-aloud's window onto the reader's chapter list.
///
/// The coordinator needs to fetch and name the next chapter when narration runs
/// past the end of this one, and it must be the *same* chapters the reader is
/// showing — a second copy of the list would go stale the moment a
/// Continue-Reading resume widens it, and read-aloud would advance into a
/// chapter that is not the one after the one on screen.
class _ReaderTtsChapterSource implements TtsChapterSource {
  _ReaderTtsChapterSource(this._reader);

  final _NovelReaderScreenState _reader;

  @override
  Future<int> chapterCount() async => _reader.chapterCountForTts;

  @override
  Future<String> chapterTitle(int index) async =>
      _reader.chapterTitleForTts(index);

  /// The chapter for the narrator to read into, cleaned by the same rules the
  /// page was.
  ///
  /// This is the path that runs with the reader closed — narration rolls into
  /// the next chapter from the notification, or from the lock screen — so it is
  /// the one place where cleaning has to happen even though nobody is looking at
  /// a page. Skipping it is how a chapter's donation plea ends up read out loud
  /// in the background while the reader has spent ten minutes making sure it is
  /// never spoken.
  @override
  Future<String> chapterText(int index) async {
    final chapter = _reader.chapterAtForTts(index);
    if (chapter == null) return '';
    final text = await sl<SourceRepository>().chapterText(
      chapter.url,
      sourceId: _reader.widget.sourceId,
    );
    return filterNovelHtml(text.html, sl<ReaderPrefs>().textFilterEngine);
  }

  /// The chapter's own URL, so an auto-advanced resume point names a chapter the
  /// app can actually reopen — the same key the reader uses itself.
  @override
  String chapterId(int index) => _reader.chapterAtForTts(index)?.url ?? '';
}
