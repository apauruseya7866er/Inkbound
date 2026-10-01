import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:watch_app/core/hive/hive_key.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../models/provider_info.dart';
import '../privacy/incognito_mode.dart';

/// Parse a persisted [ReadEntry.type] name. Only 'manga'/'novel' are
/// meaningful here; anything else — including a row saved before this field
/// existed — falls back to [ProviderType.novel]. That's a deliberate,
/// backward-compatible default: every entry ever written before this field
/// existed was ALWAYS opened via NovelReaderScreen (that was true even after
/// MangaReaderScreen shipped — [ReadEntry] had no discriminator for
/// `_resumeReading` to route on), so defaulting a fieldless legacy row to
/// `novel` reproduces exactly the routing it already got. A legacy manga row
/// keeps today's (pre-existing) mis-routing instead of gaining a NEW failure
/// mode; only entries saved from this point on carry a real type and route
/// correctly.
ProviderType readEntryTypeFromName(String? name) =>
    name == ProviderType.manga.name ? ProviderType.manga : ProviderType.novel;

class ReadEntry {
  ReadEntry({
    required this.sourceId,
    required this.showId,
    required this.title,
    this.cover,
    required this.chapterId,
    this.chapterNumber,
    required this.chapterUrl,
    required this.pos,
    required this.total,
    required this.updatedMs,
    required this.type,
  });

  final String sourceId, showId, title, chapterId, chapterUrl;
  final String? cover;
  final double? chapterNumber;
  final int pos, total, updatedMs;

  /// manga or novel — which reader [showId]'s chapters open in. See
  /// [readEntryTypeFromName] for the missing/legacy-row default.
  final ProviderType type;

  /// Same finished rule as [ReadStore]: total == 1000 is the novel
  /// scroll-permille convention (>=950 counts as done); otherwise last
  /// page/chapter (manga).
  bool get finished =>
      total > 0 && (total == 1000 ? pos >= 950 : pos >= total - 1);

  /// Reconstructs the internal native-image marker (`x-mihon-src` / `x-ani-src`)
  /// from the stored [sourceId], so Continue-Reading covers on a Cloudflare-gated
  /// image host route through the native, cf_clearance-carrying image path — the
  /// same way fresh browse covers do (see `mihon_mapping`/`aniyomi_mapping`). The
  /// marker is a UI-only key, never sent over the network. Null for JS/other
  /// sources, which fall back to CachedNetworkImage as before.
  Map<String, String>? get coverHeaders {
    if (sourceId.startsWith('mihon:')) {
      return {'x-mihon-src': sourceId.substring(6)};
    }
    if (sourceId.startsWith('ani:')) {
      return {'x-ani-src': sourceId.substring(4)};
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'showId': showId,
    'title': title,
    'cover': cover,
    'chapterId': chapterId,
    'chapterNumber': chapterNumber,
    'chapterUrl': chapterUrl,
    'pos': pos,
    'total': total,
    'updatedMs': updatedMs,
    'type': type.name,
  };

  factory ReadEntry.fromJson(Map<String, dynamic> m) => ReadEntry(
    sourceId: m['sourceId'] as String,
    showId: m['showId'] as String,
    title: m['title'] as String? ?? '',
    cover: m['cover'] as String?,
    chapterId: m['chapterId'] as String? ?? '',
    chapterNumber: (m['chapterNumber'] as num?)?.toDouble(),
    chapterUrl: m['chapterUrl'] as String? ?? '',
    pos: (m['pos'] as num?)?.toInt() ?? 0,
    total: (m['total'] as num?)?.toInt() ?? 0,
    updatedMs: (m['updatedMs'] as num?)?.toInt() ?? 0,
    type: readEntryTypeFromName(m['type'] as String?),
  );
}

/// Continue Reading, in a local Hive box. Local only: [save] writes the box
/// and that is the whole truth, so resume is instant and works offline with no
/// account.
class ReadHistory {
  ReadHistory();

  static const String boxName = 'read_history';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(String sourceId, String showId) => hiveKey('$sourceId::$showId');

  /// Persist reading progress. One local write per call.
  Future<void> save(ReadEntry e) async {
    if (IncognitoMode.on) return; // incognito: don't record what's read
    await _box.put(_key(e.sourceId, e.showId), e.toJson());
  }

  /// Pushes pending writes to disk.
  ///
  /// See `ReadStore.flush` for why this exists: [save] is deliberately not
  /// awaited by the reader, so without this a chapter reopened after the process
  /// died can come back with neither a position nor a Continue Reading entry.
  Future<void> flush() => _box.flush();

  ReadEntry _fromMap(Map raw) =>
      ReadEntry.fromJson(Map<String, dynamic>.from(raw));

  /// Newest-first, excluding finished chapters (the Continue Reading feed).
  /// [type] filters to one kind (manga or novel) — the box mixes both, so the
  /// Continue Reading row passes the current mode's type to avoid showing manga
  /// under Novel and vice versa. Filtering happens BEFORE [limit] so a busy
  /// other-kind history can't crowd this kind out of the row.
  List<ReadEntry> recent({int limit = 20, ProviderType? type}) {
    final all = _box.values
        .map(_fromMap)
        .where((e) => !e.finished && (type == null || e.type == type))
        .toList()
      ..sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
    return all.take(limit).toList();
  }

  /// Every read title, newest-first, including finished ones — backs both the
  /// full reading-History screen and the library backup, not just the
  /// unfinished subset [recent] surfaces. The box mixes manga and novel;
  /// callers filter on [ReadEntry.type].
  List<ReadEntry> all() {
    return _box.values.map(_fromMap).toList()
      ..sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
  }

  /// Notifies the Home "Continue Reading" row on any local change.
  ValueListenable<Box> listenable() => _box.listenable();

  /// The saved row for one title, or null when it isn't in reading history.
  /// Same key as [remove].
  ReadEntry? get(String sourceId, String showId) {
    final raw = _box.get(_key(sourceId, showId));
    return raw == null ? null : _fromMap(raw);
  }

  /// Remove a single title from reading history.
  Future<void> remove(String sourceId, String showId) async {
    await _box.delete(_key(sourceId, showId));
  }

  /// User-initiated "Clear history" for ONE kind (manga or novel), leaving the
  /// other kind untouched — both live in this one box.
  Future<void> clearType(ProviderType type) async {
    final keys = _box.keys.where((k) {
      final raw = _box.get(k);
      return raw != null &&
          readEntryTypeFromName(raw['type'] as String?) == type;
    }).toList();
    for (final k in keys) {
      await _box.delete(k);
    }
  }

  /// Wipe every reading-history row.
  Future<void> clearLocal() async {
    await _box.clear();
  }
}