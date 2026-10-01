import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/hive/hive_key.dart';

import '../models/media_item.dart';

/// One user-made category ("Persona", "Gym"). [id] is stable and never shown —
/// renaming changes [name] only, so assignments survive a rename.
class ListCategory {
  const ListCategory({
    required this.id,
    required this.name,
    required this.position,
    this.kind,
  });

  final String id;
  final String name;
  final int position;

  /// Which mode this was made in ([ContentMode.name]), or null for the ones
  /// created before categories remembered. A kind means the category belongs
  /// to that mode alone; null keeps the old behaviour, where an empty category
  /// showed everywhere — those already exist on people's devices and quietly
  /// moving them into one mode would look like they had been deleted from the
  /// other two.
  ///
  /// Device-local on purpose: the cloud table has no such column, and sending
  /// one it does not know would fail the upsert and take category creation
  /// down with it.
  final String? kind;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'position': position,
    if (kind != null) 'kind': kind,
  };

  static ListCategory? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String || id.isEmpty || name.isEmpty) {
      return null;
    }
    final kind = raw['kind'];
    return ListCategory(
      id: id,
      name: name,
      position: (raw['position'] as num?)?.toInt() ?? 0,
      kind: kind is String && kind.isNotEmpty ? kind : null,
    );
  }
}

/// Random v4 UUID. Hand-rolled to avoid pulling in a package for one string.
String _uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  String hex(int i, int j) =>
      b.sublist(i, j).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// The user's own categories for My List, and which titles are in them.
///
/// A SEPARATE box from [MyListStore] for the same reason [ListStatusStore] is
/// one: the list box is cleared and repopulated by a cloud pull, and a category
/// must not be collateral damage. Nothing here writes to the saved list — a
/// category is a label beside a title, never a change to it.
///
/// A title can be in several categories at once, so assignments are a set per
/// title rather than a single value. Trackers never see any of this.
class CategoryStore {
  CategoryStore();

  static const String boxName = 'list_categories';
  static const String _catsKey = '__categories__';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  /// Bumped on every change so My List rebuilds.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Same key shape as [ListStatusStore] so the two line up per title.
  String keyOf(MediaItem m) => hiveKey('${m.sourceId}::${m.id}');

  // ── the categories themselves ────────────────────────────────────────────

  /// In display order. Ties fall back to name so the order is never arbitrary.
  List<ListCategory> all() {
    final raw = _box.get(_catsKey);
    if (raw is! List) return const [];
    final out = raw.map(ListCategory.fromMap).whereType<ListCategory>().toList()
      ..sort((a, b) {
        final p = a.position.compareTo(b.position);
        return p != 0 ? p : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return out;
  }

  Future<void> _writeAll(List<ListCategory> cats) async {
    await _box.put(_catsKey, [for (final c in cats) c.toMap()]);
    revision.value++;
  }

  /// Creates a category and returns it, or null when [name] is blank or already
  /// taken (compared case-insensitively — two categories called "gym" and "Gym"
  /// would be indistinguishable on screen).
  Future<ListCategory?> create(String name, {String? kind}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final cats = all();
    if (cats.any((c) => c.name.toLowerCase() == trimmed.toLowerCase())) {
      return null;
    }
    final cat = ListCategory(
      // A real UUID, because the cloud column is one — an id shaped any other
      // way would need a mapping table to sync.
      id: _uuidV4(),
      name: trimmed,
      position: cats.isEmpty ? 0 : cats.last.position + 1,
      kind: kind,
    );
    await _writeAll([...cats, cat]);
    return cat;
  }

  /// Renames in place. Assignments are keyed by id, so they all survive.
  Future<bool> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final cats = all();
    if (cats.any((c) =>
        c.id != id && c.name.toLowerCase() == trimmed.toLowerCase())) {
      return false;
    }
    if (!cats.any((c) => c.id == id)) return false;
    await _writeAll([
      for (final c in cats)
        if (c.id == id)
          ListCategory(id: c.id, name: trimmed, position: c.position)
        else
          c,
    ]);
    return true;
  }

  /// Removes the category and every assignment to it. Titles are untouched —
  /// deleting a category loses the label, never anything from the list.
  Future<void> delete(String id) async {
    await _writeAll(all().where((c) => c.id != id).toList());
    for (final key in _box.keys.toList()) {
      if (key == _catsKey || key is! String) continue;
      final ids = _idsFor(key);
      if (!ids.remove(id)) continue;
      if (ids.isEmpty) {
        await _box.delete(key);
      } else {
        await _box.put(key, ids.toList());
      }
    }
    revision.value++;
  }

  /// Persists a new order. [orderedIds] is the full list, first to last.
  Future<void> reorder(List<String> orderedIds) async {
    final byId = {for (final c in all()) c.id: c};
    final out = <ListCategory>[];
    var i = 0;
    for (final id in orderedIds) {
      final c = byId.remove(id);
      if (c != null) {
        out.add(ListCategory(id: c.id, name: c.name, position: i++));
      }
    }
    // Anything not named keeps its relative order at the end, so a stale list
    // can never silently drop a category.
    for (final c in byId.values) {
      out.add(ListCategory(id: c.id, name: c.name, position: i++));
    }
    await _writeAll(out);
  }

  // ── assignments ─────────────────────────────────────────────────────────

  Set<String> _idsFor(String key) {
    final raw = _box.get(key);
    if (raw is! List) return <String>{};
    return raw.whereType<String>().toSet();
  }

  /// Category ids this title belongs to.
  Set<String> categoriesOf(MediaItem m) => _idsFor(keyOf(m));

  bool isIn(MediaItem m, String categoryId) =>
      _idsFor(keyOf(m)).contains(categoryId);

  Future<void> setMembership(MediaItem m, String categoryId, bool member) async {
    final key = keyOf(m);
    final ids = _idsFor(key);
    if (member ? !ids.add(categoryId) : !ids.remove(categoryId)) return;
    if (ids.isEmpty) {
      await _box.delete(key);
    } else {
      await _box.put(key, ids.toList());
    }
    revision.value++;
  }

  /// Drops every assignment for a title — for when it leaves My List entirely.
  Future<void> clearFor(MediaItem m) async {
    if (_box.containsKey(keyOf(m))) {
      await _box.delete(keyOf(m));
      revision.value++;
    }
  }


  /// How many titles are in a category, counted from the assignments so an
  /// empty category honestly reads 0.
  int countIn(String categoryId) {
    var n = 0;
    for (final key in _box.keys) {
      if (key == _catsKey || key is! String) continue;
      if (_idsFor(key).contains(categoryId)) n++;
    }
    return n;
  }
}
