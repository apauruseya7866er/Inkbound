import 'package:hive/hive.dart';

import '../di/injector.dart' show sl;
import '../hive/hive_key.dart';
import 'read_store.dart';

/// Moves per-chapter reading positions from one source's copy of a novel to
/// another's.
///
/// ## Why this needs to exist at all
///
/// [ReadStore] keys a position by `sourceId::showId::chapterId`
/// (`read_store.dart:28`). Migrating a novel changes the first two, so every
/// position written under the old source stops being found — not deleted, just
/// orphaned. Without this the reader arrives at the new source at chapter one
/// with a "read nothing" history, which reads as losing the book rather than
/// as moving it.
///
/// ## Why it is chapter-NUMBER keyed, not chapter-id keyed
///
/// Chapter ids are site-local: `/chapter/1` on one source is `/novel-2-node-187`
/// on another, so there is no cross-source id to translate. Numbers are the only
/// thing two sources agree on, and they disagree — one site's chapter 40 is
/// another's chapter 44, and translations merge or split volumes. So this is a
/// best guess by number, deliberately narrow:
///
///  - only the furthest position is carried, because that is the only one a
///    reader would notice losing;
///  - the chapter is resolved against the DESTINATION's own chapter list by
///    [applyTo], not assumed to be the same index;
///  - nothing is deleted from the old source. A wrong guess costs the reader a
///    re-read of one chapter, and the old positions stay there in case they
///    migrate back.
class ReadPositionMover {
  ReadPositionMover({ReadStore? store}) : _store = store ?? sl<ReadStore>();

  final ReadStore _store;

  /// The raw box key prefix that every position for [sourceId] + [showId]
  /// shares.
  ///
  /// [hiveKey] passes short keys through untouched and md5-hashes only
  /// oversized ones, so a prefix scan is exact for every key a novel actually
  /// produces (source ids and show paths are short) and simply finds nothing for
  /// a pathological hashed one — which is the safe direction to fail.
  String _prefix(String sourceId, String showId) =>
      hiveKey('$sourceId::$showId::');

  /// The furthest position recorded for this novel, or null if none.
  ///
  /// "Furthest" is by scroll position within the chapter, not by chapter order:
  /// the store has no ordering of its own, and the box does not preserve one
  /// across a restart. So this reports the single chapter with the highest
  /// `pos/total` ratio, which is the honest definition of "as far as they got"
  /// that the stored data supports.
  ({int pos, int total, String chapterId})? furthest(String sourceId, String showId) {
    final box = _box;
    if (box == null) return null;
    final prefix = _prefix(sourceId, showId);
    ({int pos, int total, String chapterId})? best;
    for (final key in box.keys) {
      final k = '$key';
      if (!k.startsWith(prefix)) continue;
      final raw = box.get(key);
      if (raw is! Map) continue;
      final pos = (raw['pos'] as num?)?.toInt() ?? 0;
      final total = (raw['total'] as num?)?.toInt() ?? 0;
      if (pos <= 0 || total <= 0) continue;
      // Prefer the chapter read furthest through; ties break toward the later
      // chapter, which is almost always the one they actually stopped on.
      final better = best == null ||
          pos * (best.total == 0 ? 1 : best.total) > best.pos * total;
      if (better) {
        best = (pos: pos, total: total, chapterId: k.substring(prefix.length));
      }
    }
    return best;
  }

  /// The position recorded for ONE specific chapter, or null when there is none.
  ///
  /// [furthest] answers "as far as they got"; this answers "where were they in
  /// THIS chapter". Migration needs the second, not the first: the chapter number
  /// the caller resolved the destination against comes from read history, so
  /// carrying the position of some *other* chapter - one that merely happens to
  /// have a higher scroll ratio - attaches the reader's place to a chapter they
  /// were not on. When history knows the chapter, ask for that chapter's position
  /// and fall back to [furthest] only when it does not.
  /// Same shape as [furthest], so a caller can hold either without caring which
  /// question it asked.
  ({int pos, int total, String chapterId})? at(
    String sourceId,
    String showId,
    String chapterId,
  ) {
    final raw = _store.get(sourceId, showId, chapterId);
    if (raw == null) return null;
    return (pos: raw.pos, total: raw.total, chapterId: chapterId);
  }

  /// Writes [pos]/[total] onto [destChapterId] under the destination novel.
  ///
  /// Called by the migrator only after it has resolved the destination's own
  /// chapter list, so the number is looked up against real chapters rather than
  /// assumed to line up.
  Future<void> applyTo({
    required String sourceId,
    required String showId,
    required String chapterId,
    required int pos,
    required int total,
  }) async {
    await _store.save(sourceId, showId, chapterId, pos: pos, total: total);
    await _store.flush();
  }

  /// Every chapter position for a novel, for callers that need the whole shape
  /// rather than just the furthest point.
  List<({String chapterId, int pos, int total, bool read})> all(
    String sourceId,
    String showId,
  ) {
    final box = _box;
    if (box == null) return const [];
    final prefix = _prefix(sourceId, showId);
    final out = <({String chapterId, int pos, int total, bool read})>[];
    for (final key in box.keys) {
      final k = '$key';
      if (!k.startsWith(prefix)) continue;
      final raw = box.get(key);
      if (raw is! Map) continue;
      out.add((
        chapterId: k.substring(prefix.length),
        pos: (raw['pos'] as num?)?.toInt() ?? 0,
        total: (raw['total'] as num?)?.toInt() ?? 0,
        read: raw['read'] == true,
      ));
    }
    return out;
  }

  Box<Map>? get _box =>
      Hive.isBoxOpen(ReadStore.boxName) ? Hive.box<Map>(ReadStore.boxName) : null;
}