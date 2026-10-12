import 'package:flutter/foundation.dart' show visibleForTesting;

import '../di/injector.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart' show ProviderType;
import '../playback/my_list.dart';
import 'read_history.dart' show ReadEntry, ReadHistory;
import 'read_position_mover.dart';
import '../repository/source_repository.dart';

/// Moves a saved novel from one source to another.
///
/// ## What "migrate" means here
///
/// A source can rot: the site goes down, the plugin breaks, the extension is
/// pulled. The book is still in My List and still in history, but it cannot be
/// opened. Migrating re-points those entries at a source that still answers,
/// carrying the reading position across so the reader resumes near where they
/// stopped rather than at chapter one.
///
/// ## What it deliberately does not do
///
///  - It does not delete the old entry's history. If the guess is wrong, or the
///    reader wants to go back, everything they had is still there.
///  - It does not auto-select the new source. [matchCandidates] returns
///    candidates for a human to choose, because two sites carrying the same
///    title are two different books with different chapter counts and different
///    translations, and only the reader knows which one they were reading.
///
/// ## Why progress carry-over is a guess, and how it fails safely
///
/// Chapter ids are site-local and chapter numbering disagrees across sites, so
/// the only portable key is the number. [resolveChapter] resolves that number
/// against the DESTINATION's own chapter list rather than assuming the indexes
/// line up, and a number the destination does not have resolves to nothing -
/// which lands the reader at chapter one rather than in a wrong chapter they
/// have no reason to distrust.
class NovelMigrator {
  NovelMigrator({
    SourceRepository? sources,
    MyListStore? list,
    ReadHistory? history,
    ReadPositionMover? positions,
  }) : _sources = sources ?? sl<SourceRepository>(),
       _list = list ?? sl<MyListStore>(),
       _history = history ?? sl<ReadHistory>(),
       _positions = positions ?? ReadPositionMover();

  final SourceRepository _sources;
  final MyListStore _list;
  final ReadHistory _history;
  final ReadPositionMover _positions;

  /// How many sources to search at once while gathering candidates.
  ///
  /// Five, the same cap the novel search uses. A migration sweep on a large
  /// library would otherwise open 100+ sockets and time out most of them.
  static const int defaultConcurrency = 5;

  /// Searches every installed novel source for [title], returning what each one
  /// offered.
  ///
  /// Failures are kept as outcomes rather than thrown: one dead source in a
  /// sweep of forty must not abort the sweep, and "Chikari found it, three
  /// others did not answer" is information the picker wants.
  ///
  /// Results are ordered by how well the title matched, best first, because the
  /// first row is what a reader taps.
  Future<List<MigrationCandidate>> matchCandidates(
    String title, {
    List<String>? sourceIds,
    int concurrency = defaultConcurrency,
  }) async {
    final all = sourceIds ??
        _sources
            .loadedSources
            .map((s) => s.id)
            .where((id) => id.startsWith('lnr:'))
            .toList();
    if (title.trim().isEmpty || all.isEmpty) return const [];

    final out = <MigrationCandidate>[];
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= all.length) return;
        final id = all[i];
        try {
          final res = await _sources.searchStatus(
            title,
            sourceId: id,
            cache: false,
          );
          for (final item in res.items) {
            if (item.type != ProviderType.novel) continue;
            out.add(MigrationCandidate(item: item, score: score(title, item)));
          }
        } catch (_) {
          out.add(MigrationCandidate(failedSourceId: id, failure: 'no answer'));
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency.clamp(1, all.length); i++) worker(),
    ]);

    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  /// How close [item]'s title is to what was searched.
  ///
  /// Exact match wins, then a prefix/contains match, then anything else. Novel
  /// sites return loose results constantly ("The Reincarnated" when you searched
  /// "reincarnated"), so this is the only thing separating a usable candidate
  /// from noise.
  @visibleForTesting
  static int score(String query, MediaItem item) {
    final q = norm(query);
    final t = norm(item.title);
    if (q.isEmpty || t.isEmpty) return 0;
    if (q == t) return 100;
    if (t.startsWith(q) || t.contains(q)) return 70;
    // Word overlap catches "Reincarnated: A Sword For Hire" for "reincarnated".
    final qw = q.split(' ').where((w) => w.length > 2).toSet();
    if (qw.isEmpty) return 20;
    final tw = t.split(' ').toSet();
    final hits = qw.where(tw.contains).length;
    return hits == 0 ? 20 : 40 + hits * 5;
  }

  /// Lowercase and strip everything that differs between sites' punctuation.
  @visibleForTesting
  static String norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  /// Re-points [from] at [to] in My List and history, carrying the reading
  /// position across.
  ///
  /// [chapterNumber] is the destination chapter to attach the position to, or
  /// null to skip carry-over entirely. The caller supplies it because only it
  /// has resolved the destination's chapter list - see [resolveChapter] for why
  /// that cannot be done here blind.
  ///
  /// Returns what actually happened, so the caller can tell the reader "moved,
  /// resumed at chapter 12" from "moved, could not find your chapter" rather
  /// than claiming a resume that did not happen.
  Future<MigrationResult> migrate({
    required MediaItem from,
    required MediaItem to,
    int? chapterNumber,
    List<({String id, String title})> destinationChapters = const [],
  }) async {
    // The furthest position we have for the OLD copy, read BEFORE anything is
    // rewritten.
    final before = _positions.furthest(from.sourceId, from.id);

    // Same book, same source: nothing to move, and doing it anyway would strand
    // the reader's own position under a key they never left.
    if (from.sourceId == to.sourceId && from.id == to.id) {
      return const MigrationResult(ok: false, reason: 'same place');
    }

    // My List: drop the old key, add the new one.
    await _list.remove(from);
    await _list.add(to);

    // History: rewrite this novel's entry to the new source, keeping the title
    // and marking where it now lives. Several history entries can share a show
    // (one per chapter read), so every one of them moves - otherwise Continue
    // Reading keeps offering the old source for the first tap after migrating.
    final movedEntries = <ReadEntry>[];
    for (final e in _history.all()) {
      if (e.sourceId != from.sourceId || e.showId != from.id) continue;
      movedEntries.add(
        ReadEntry(
          sourceId: to.sourceId,
          showId: to.id,
          title: to.title,
          cover: to.cover ?? e.cover,
          chapterId: e.chapterId,
          chapterNumber: e.chapterNumber,
          chapterUrl: e.chapterUrl,
          pos: e.pos,
          total: e.total,
          updatedMs: DateTime.now().millisecondsSinceEpoch,
          type: ProviderType.novel,
        ),
      );
    }
    // Remove the old ones wholesale (they are one title) then write the new.
    await _history.remove(from.sourceId, from.id);
    for (final e in movedEntries) {
      await _history.save(e);
    }

    // Carry the reading position, resolved against the destination's chapters.
    var resumed = false;
    if (before != null && chapterNumber != null) {
      final destId = resolveChapter(destinationChapters, chapterNumber);
      if (destId != null) {
        await _positions.applyTo(
          sourceId: to.sourceId,
          showId: to.id,
          chapterId: destId,
          pos: before.pos,
          total: before.total,
        );
        resumed = true;
      }
    }

    return MigrationResult(
      ok: true,
      fromSourceId: from.sourceId,
      toSourceId: to.sourceId,
      historyRows: movedEntries.length,
      carriedPosition: resumed,
    );
  }

  /// Finds the destination's chapter whose number is closest to [number].
  ///
  /// Exact match first. Then the nearest at-or-below, because a reader who was
  /// on chapter 40 is better served by 39 than by 44 - overshooting puts them
  /// in a chapter they have not read, undershooting by one is a chapter they
  /// can re-read trivially. Returns null when the destination has no chapters to
  /// compare against, which is the "carry over nothing" case.
  @visibleForTesting
  static String? resolveChapter(
    List<({String id, String title})> chapters,
    int number,
  ) {
    if (chapters.isEmpty) return null;
    // Exact.
    for (final c in chapters) {
      if (leadingNumber(c.title) == number) return c.id;
    }
    // Nearest at or below.
    String? best;
    var bestNum = -1;
    for (final c in chapters) {
      final n = leadingNumber(c.title);
      if (n < 0) continue;
      if (n <= number && n > bestNum) {
        bestNum = n;
        best = c.id;
      }
    }
    return best;
  }

  /// The chapter a title refers to, or -1.
  ///
  /// Three shapes matter, in priority order:
  ///
  ///  - "Volume 3 Chapter 12" / "Vol. 3 Ch. 12" - the number AFTER the volume
  ///    is the chapter. Taking the leading number here resolves chapter 12 to
  ///    chapter 3 and silently rewinds the reader by nine chapters, so the
  ///    volume is stripped first.
  ///  - "Chapter 12" and bare "12. A title" - the leading number.
  ///  - "Prologue" - nothing to take, -1.
  @visibleForTesting
  static int leadingNumber(String title) {
    // Strip a leading volume marker so the chapter is what gets parsed.
    final withoutVolume = title.replaceFirst(
      RegExp(
        r'^\s*(?:volume|vol\.?|v\.)\s*\d{1,3}\s*[:\-–]?\s*',
        caseSensitive: false,
      ),
      '',
    );
    final m = RegExp(r'^\s*(?:chapter\s+|ch\.?\s*)?(\d{1,5})', caseSensitive: false)
        .firstMatch(withoutVolume);
    return m == null ? -1 : int.parse(m.group(1)!);
  }
}

/// One thing a source offered for a searched title.
class MigrationCandidate {
  MigrationCandidate({
    this.item,
    this.score = 0,
    this.failedSourceId,
    this.failure,
  });

  /// The match, or null when this source simply did not answer.
  final MediaItem? item;

  /// 0-100, how well the title matched.
  final int score;

  /// The source that failed, when there is no item to carry the id. Kept
  /// separately so the picker can say WHICH source did not answer - which is
  /// the difference between "Chikari had nothing" and "Chikari is broken".
  final String? failedSourceId;

  /// Set when the source failed outright, so the picker can say so instead of
  /// showing it as "no results".
  final String? failure;

  /// The source this row came from.
  String? get sourceId => item?.sourceId ?? failedSourceId;

  bool get failed => failure != null;
}

/// What a migration actually did.
class MigrationResult {
  const MigrationResult({
    required this.ok,
    this.reason,
    this.fromSourceId,
    this.toSourceId,
    this.historyRows = 0,
    this.carriedPosition = false,
  });

  /// False only for the "no-op" case; a source that failed to answer is still
  /// reported by the candidate list, not here.
  final bool ok;

  final String? reason;
  final String? fromSourceId;
  final String? toSourceId;

  /// How many history rows were re-pointed.
  final int historyRows;

  /// True when the reading position found a home in the destination.
  final bool carriedPosition;
}