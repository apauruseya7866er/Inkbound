import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../di/injector.dart';
import '../hive/hive_key.dart';
import '../hive/safe_box.dart';
import '../models/media_item.dart';
import '../zmode/metadata_repository.dart';
import '../zmode/zmode_ids.dart';

/// My List: the titles a person saved, in a local Hive box.
///
/// There is no account and no server. [all] reads the box directly so the UI
/// stays synchronous and offline-friendly, and [toggle] is the only writer.
/// [revision] is bumped on every change so listeners (MyListCubit) can refresh.
class MyListStore {
  MyListStore();

  /// Bumped whenever the contents change (toggle / clear) so listeners like
  /// MyListCubit can refresh.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const String boxName = 'my_list';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(MediaItem m) => hiveKey('${m.sourceId}::${m.id}');

  bool contains(MediaItem m) => _box.containsKey(_key(m));

  List<MediaItem> all() =>
      _box.values.map(_itemFromHive).whereType<MediaItem>().toList();

  /// Deserialise a stored [MediaItem]. Hive returns nested maps (here,
  /// `coverHeaders`) as `Map<dynamic, dynamic>` on a cold read from disk, but
  /// [MediaItem]'s generated `fromJson` casts `coverHeaders` to
  /// `Map<String, dynamic>` — which throws on that runtime type. That crash
  /// only surfaced AFTER an app restart (in-session, Hive returns the original
  /// in-memory object with types intact), and rendered My List as a blank grey
  /// error box. Normalise the nested map to string keys/values first so the
  /// read can never throw. `coverHeaders` is the only nested field on
  /// [MediaItem]; every other field is a scalar.
  ///
  /// Returns null for a record this build can't read, rather than throwing.
  /// Records outlive the schema that wrote them: a list saved by a build with
  /// extra `ProviderType` values (e.g. `manga`) decodes to an ArgumentError
  /// here, and because [all] maps over the whole box, one such row used to take
  /// down the entire screen. Skipping costs that one row; throwing costs the
  /// list.
  ///
  /// Deliberately NOT deleted — if a later build understands the value again,
  /// the row decodes again. Dropping it would be silent data loss.
  static MediaItem? _itemFromHive(Map raw) {
    try {
      final m = Map<String, dynamic>.from(raw);
      final h = m['coverHeaders'];
      if (h is Map) {
        m['coverHeaders'] = h.map((k, v) => MapEntry('$k', '$v'));
      }
      return MediaItem.fromJson(m);
    } catch (_) {
      return null;
    }
  }

  /// Ensure [m] is in the list (no-op if already present). Used by the status
  /// sheet, where picking any status implies membership.
  Future<void> add(MediaItem m) async {
    if (_box.containsKey(_key(m))) return;
    await toggle(m);
  }

  /// Records which catalogue a metadata title came from, once, on the way in.
  ///
  /// Done here rather than at the four call sites that add to the list, so no
  /// path can forget. A saved title then keeps its origin: change the Settings
  /// provider later and the list still opens each entry where it came from.
  /// Source titles are left alone — [MediaItem.sourceId] already names theirs.
  MediaItem _stamped(MediaItem m) {
    // The date goes on everything, including source titles: "recently added"
    // has to mean something for those too.
    var out = m.savedAtMs != null
        ? m
        : m.copyWith(savedAtMs: DateTime.now().millisecondsSinceEpoch);
    if (out.savedFrom != null || out.sourceId != ZmodeIds.sourceId) return out;
    final c = ZmodeIds.parseShow(out.url);
    if (c == null) return out;
    final name = sl.isRegistered<MetadataRepository>()
        ? sl<MetadataRepository>().nameForKind(c.kind)
        : null;
    return name == null ? out : out.copyWith(savedFrom: name);
  }

  /// Remove [m] from the list (no-op if absent).
  Future<void> remove(MediaItem m) async {
    if (!_box.containsKey(_key(m))) return;
    await toggle(m);
  }

  /// Add [m] if it isn't saved, remove it if it is. The box is the whole
  /// truth: the write lands here or it did not happen.
  Future<void> toggle(MediaItem m) async {
    final k = _key(m);
    if (_box.containsKey(k)) {
      await _box.delete(k);
    } else {
      await _box.put(k, _stamped(m).toJson());
    }
    revision.value++;
  }

  /// Wipe the local cache.
  Future<void> clearLocal() async {
    await _box.clear();
    revision.value++;
  }
}