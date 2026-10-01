import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/hive_key.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../privacy/incognito_mode.dart';

class HistoryEntry {
  HistoryEntry({
    required this.sourceId,
    required this.showId,
    required this.showTitle,
    this.cover,
    this.coverHeaders,
    this.thumbnail,
    required this.showUrl,
    required this.category,
    required this.episodeId,
    required this.episodeNumber,
    required this.episodeUrl,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.malId,
  });
  final String sourceId,
      showId,
      showTitle,
      showUrl,
      category,
      episodeId,
      episodeUrl;
  final String? cover;
  final Map<String, String>? coverHeaders;

  /// Landscape episode thumbnail (16:9) for the Continue Watching card. Local
  /// only — a resumed entry from another device falls back to [cover]. Null for
  /// older entries and sources without episode thumbnails.
  final String? thumbnail;
  final double? episodeNumber;

  /// MyAnimeList id (anime), carried so a resume from Continue Watching can
  /// still auto-scrobble to AniList.
  final int? malId;
  final Duration position, duration;
  final int updatedAt;
  bool get finished =>
      duration.inMilliseconds > 0 &&
      position.inMilliseconds >= duration.inMilliseconds * 0.92;
  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}

/// Continue Watching, in a local Hive box.
///
/// Local only: the box is the whole truth, so resume is instant and works
/// offline with no account. [save] is the single writer; [recent] is the
/// Continue Watching feed and [all] backs the full History screen.
class WatchHistory {
  WatchHistory();

  static const String boxName = 'watch_history';

  /// Shared box for this app's one-time local migrations (see
  /// `HistoryCanonicalMerge`, which stores its "already ran" flag here). It used
  /// to hold cloud-pull throttles as well; nothing is synced any more, so it is
  /// just the migrations box.
  static const String syncMetaBox = 'library_sync_meta';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
    if (!Hive.isBoxOpen(syncMetaBox)) {
      await openBoxSafely(syncMetaBox);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);
  String _key(String sourceId, String showId) =>
      hiveKey('$sourceId::$showId');

  /// Persist progress. The local write is immediate, so resume is instant; the
  /// player calls this about once a second during playback, which is cheap
  /// because it is one box put.
  Future<void> save(HistoryEntry e) async {
    if (IncognitoMode.on) return; // incognito: don't record what's watched
    final key = _key(e.sourceId, e.showId);
    await _box.put(key, {
      'sourceId': e.sourceId,
      'showId': e.showId,
      'showTitle': e.showTitle,
      'cover': e.cover,
      'coverHeaders': e.coverHeaders,
      'thumbnail': e.thumbnail,
      'showUrl': e.showUrl,
      'category': e.category,
      'episodeId': e.episodeId,
      'episodeNumber': e.episodeNumber,
      'episodeUrl': e.episodeUrl,
      'positionMs': e.position.inMilliseconds,
      'durationMs': e.duration.inMilliseconds,
      'updatedAt': e.updatedAt,
      'malId': e.malId,
    });
  }

  HistoryEntry _fromMap(Map raw) {
    final m = Map<String, dynamic>.from(raw);
    return HistoryEntry(
      sourceId: m['sourceId'] as String,
      showId: m['showId'] as String,
      showTitle: m['showTitle'] as String? ?? '',
      cover: m['cover'] as String?,
      coverHeaders: (m['coverHeaders'] as Map?)?.map(
        (k, v) => MapEntry('$k', '$v'),
      ),
      thumbnail: m['thumbnail'] as String?,
      showUrl: m['showUrl'] as String? ?? '',
      category: m['category'] as String? ?? 'sub',
      episodeId: m['episodeId'] as String? ?? '',
      episodeNumber: (m['episodeNumber'] as num?)?.toDouble(),
      episodeUrl: m['episodeUrl'] as String? ?? '',
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      malId: (m['malId'] as num?)?.toInt(),
    );
  }

  /// Newest-first, excluding finished episodes (the Continue Watching feed).
  List<HistoryEntry> recent({int limit = 20}) {
    final all = _box.values.map(_fromMap).where((e) => !e.finished).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all.take(limit).toList();
  }

  /// Every watched show, newest-first, including finished ones — the full
  /// History screen (Continue Watching only surfaces the unfinished subset).
  List<HistoryEntry> all() {
    return _box.values.map(_fromMap).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// The saved row for one show, or null when it isn't in Continue Watching.
  HistoryEntry? get(String sourceId, String showId) {
    final raw = _box.get(_key(sourceId, showId));
    return raw == null ? null : _fromMap(raw);
  }

  /// Remove a single show from Continue Watching.
  Future<void> remove(String sourceId, String showId) async {
    await _box.delete(_key(sourceId, showId));
  }

  /// User-initiated "Clear history": wipe Continue Watching.
  Future<void> clearAll() async {
    await _box.clear();
  }
}