import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sentence_parser.dart';

/// Supplies chapter text for read-aloud beyond the one on screen.
///
/// An interface because advancing a chapter means fetching from a plugin source
/// over the network, and that must be fakeable in tests — the alternative is an
/// auto-advance test suite that only runs against a live site.
abstract class TtsChapterSource {
  /// Number of chapters available.
  Future<int> chapterCount();

  /// Human-readable title, for the notification.
  Future<String> chapterTitle(int index);

  /// Raw chapter HTML. The coordinator parses it; callers hand back markup.
  Future<String> chapterText(int index);

  /// Stable identifier for the chapter at [index] — the same value the reader
  /// uses when it opens that chapter directly.
  ///
  /// Separate from the index because the resume point is keyed on it: derive it
  /// by appending to the previous one instead and the key stops matching any
  /// chapter the app can navigate to, so the saved position becomes
  /// unreachable and the resume offer silently never appears.
  String chapterId(int index);
}

/// A chapter ready to be spoken.
class TtsChapterTarget {
  const TtsChapterTarget({
    required this.index,
    required this.chapterId,
    required this.title,
    required this.content,
  });

  final int index;

  /// Stable id from [TtsChapterSource.chapterId].
  final String chapterId;
  final String title;
  final TtsChapterContent content;
}

/// Moves read-aloud to the next chapter, and preloads the one after that.
///
/// ### Why prefetch
/// Without a prefetch, finishing a chapter means a network round trip while the
/// user watches a silent notification. Prefetching the next chapter as soon as
/// the current one starts means the gap is normally just a parse.
///
/// The cache holds exactly one chapter — the next one. Holding more wastes
/// memory on long books (a chapter can be hundreds of KB of parsed sentences)
/// and is rarely useful, because nobody reads three chapters ahead.
class TtsAutoAdvance {
  TtsAutoAdvance({required this.source, required this.index});

  final TtsChapterSource source;

  /// Index of the chapter currently being read.
  int index;

  TtsChapterTarget? _prefetched;
  int? _prefetchedIndex;
  Future<TtsChapterTarget?>? _inFlight;

  /// The chapter after the current one, or null at the end of the book.
  int? get nextIndex {
    if (_count == 0) return null;
    final n = index + 1;
    return n < _count ? n : null;
  }

  int _count = 0;

  /// Loads chapter count once; auto-advance cannot work without knowing where
  /// the end is.
  Future<void> ensureCount() async {
    try {
      _count = await source.chapterCount();
    } catch (e) {
      debugPrint('[TtsAutoAdvance] chapter count unavailable: $e');
      _count = 0;
    }
    // The count is what bounds [nextIndex], so any prefetch asked for before it
    // arrived silently did nothing. Re-run it now, or the very first chapter of
    // every session would be the one without a prefetched successor.
    if (prefetchOnCount) await prefetch();
  }

  /// Set by [prefetch] when it is called before the count is known, so the
  /// pending request is not lost.
  bool prefetchOnCount = false;

  /// Warms the next chapter. Safe to call repeatedly; a fetch already in flight
  /// is reused rather than started again.
  Future<void> prefetch() async {
    if (_count == 0) {
      // The count has not arrived (or failed): remember the request instead of
      // dropping it, so [ensureCount] can honour it.
      prefetchOnCount = true;
      return;
    }
    final next = nextIndex;
    if (next == null || _prefetchedIndex == next) return;
    _inFlight ??= _load(next);
    try {
      await _inFlight;
    } finally {
      _inFlight = null;
    }
  }

  Future<TtsChapterTarget?> _load(int i) async {
    try {
      final html = await source.chapterText(i);
      if (html.trim().isEmpty) {
        debugPrint('[TtsAutoAdvance] chapter $i came back empty');
        return null;
      }
      final target = TtsChapterTarget(
        index: i,
        chapterId: source.chapterId(i),
        title: await _titleOf(i),
        content: SentenceParser.parseHtml(html),
      );
      // Only cache if still the chapter we wanted: a slow fetch for chapter 3
      // must not overwrite the prefetch for chapter 2 when the user moved on.
      if (nextIndex == i) {
        _prefetched = target;
        _prefetchedIndex = i;
      }
      return target;
    } catch (e) {
      debugPrint('[TtsAutoAdvance] could not load chapter $i: $e');
      return null;
    }
  }

  Future<String> _titleOf(int i) async {
    try {
      return await source.chapterTitle(i);
    } catch (_) {
      return 'Chapter ${i + 1}';
    }
  }

  /// Returns the next chapter ready to speak, or null at the end of the book.
  ///
  /// Uses the prefetch when it matches, so a normal advance costs nothing.
  Future<TtsChapterTarget?> advance() async {
    final next = nextIndex;
    if (next == null) return null;

    TtsChapterTarget? target;
    if (_prefetchedIndex == next) {
      target = _prefetched;
    } else {
      target = await _load(next);
    }

    if (target == null) return null;

    _prefetched = null;
    _prefetchedIndex = null;
    index = target.index;
    return target;
  }

  /// Drops the cached chapter. Called when the user navigates manually, so a
  /// stale prefetch is never spoken.
  void invalidate() {
    _prefetched = null;
    _prefetchedIndex = null;
  }

  @visibleForTesting
  bool get hasPrefetched => _prefetched != null;
}
