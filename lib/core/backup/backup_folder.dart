import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../hive/safe_box.dart';
import '../platform/saf_uri.dart';
import 'backup_file.dart';

/// Automatic backup: a rolling set of JSON files in a folder the user picked
/// once, with no account and no server in the loop.
///
/// The folder is a SAF tree (`ACTION_OPEN_DOCUMENT_TREE`) held under a
/// persisted permission, so the write works from a background isolate with no
/// foreground activity and no storage permission. Point it at a cloud-synced
/// folder (Google Drive, OneDrive, Nextcloud) and off-device backup comes free
/// from whatever app syncs it - the app itself only writes a file.
class BackupFolderPrefs {
  static const String boxName = 'backup_folder';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  /// The picked SAF tree URI, or null when automatic backup is off.
  String? get treeUri => _box.get('treeUri') as String?;

  /// A short human name for the picked folder, for the settings subtitle.
  String? get treeLabel => _box.get('treeLabel') as String?;

  /// When the last successful automatic backup was written, if ever.
  DateTime? get lastBackupAt {
    final ms = _box.get('lastBackupAt') as int?;
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Off until the user has picked a folder; on by default after that.
  bool get autoEnabled => _box.get('autoEnabled', defaultValue: true) as bool;

  /// How many backups to keep in the folder. Older ones are pruned.
  int get keep => _box.get('keep', defaultValue: 5) as int;

  bool get isConfigured => (treeUri ?? '').isNotEmpty;

  Future<void> setFolder(String? uri, String? label) async {
    if (uri == null) {
      await _box.delete('treeUri');
      await _box.delete('treeLabel');
    } else {
      await _box.put('treeUri', uri);
      await _box.put('treeLabel', label);
    }
  }

  Future<void> setAutoEnabled(bool on) => _box.put('autoEnabled', on);

  Future<void> setKeep(int n) => _box.put('keep', n);

  Future<void> markBackedUp(DateTime at) =>
      _box.put('lastBackupAt', at.millisecondsSinceEpoch);
}

// ── Pure policy (tested) ──────────────────────────────────────────────────────

/// How often an automatic backup is written, once one is due.
const Duration kAutoBackupInterval = Duration(hours: 24);

/// Whether a backup should be written now.
///
/// Never backed up counts as due - a folder that was just picked should get its
/// first file straight away rather than a day later. Everything else is
/// measured from the last *successful* write, so a folder whose write failed
/// (permission revoked, folder deleted) is retried on the next pass instead of
/// being silently skipped for a day.
bool isAutoBackupDue({
  required DateTime? lastBackupAt,
  required DateTime now,
  Duration interval = kAutoBackupInterval,
}) {
  if (lastBackupAt == null) return true;
  return now.difference(lastBackupAt) >= interval;
}

/// The backup file names to delete so only the newest [keep] remain.
///
/// Only this app's own backup names are ever considered: a folder picked for
/// backups is a real folder that may hold other files, and a rolling window
/// must not eat them. Names embed a `YYYYMMDD-HHMM` stamp, so sorting by name
/// sorts by time and the tail is the oldest.
List<String> prunePlan(List<String> names, {required int keep}) {
  if (keep < 0) return const [];
  final ours = names.where(isBackupFileName).toList()..sort();
  if (ours.length <= keep) return const [];
  return ours.take(ours.length - keep).toList();
}

/// True for a file this app wrote as a backup - `zangetsu-backup-<stamp>.json`.
///
/// The stamp is checked rather than just the prefix so a hand-copied
/// `zangetsu-backup-notes.json` in the same folder is left alone.
bool isBackupFileName(String name) =>
    RegExp(r'^zangetsu-backup-\d{8}-\d{4}\.json$').hasMatch(name);

// ── Transport ─────────────────────────────────────────────────────────────────

class BackupFolder {
  static const MethodChannel _channel =
      MethodChannel('com.spyou.watch_app/device');

  final BackupFolderPrefs _prefs;

  /// When this process last *tried* an automatic backup (see [runIfDue]).
  DateTime? _lastAttemptAt;

  BackupFolder([BackupFolderPrefs? prefs])
    : _prefs = prefs ?? BackupFolderPrefs();

  /// Opens the system folder picker and stores the choice. Returns the picked
  /// label, or null if the user backed out.
  Future<String?> pick() async {
    final uri = await FileDownloader().uri.pickDirectory(
      persistedUriPermission: true,
    );
    if (uri == null) return null;
    final label = folderLabelFromUri(uri);
    await _prefs.setFolder(uri.toString(), label);
    return label;
  }

  /// Writes [payload] into the picked folder as a timestamped JSON file, then
  /// prunes the folder back to [_prefs.keep] files. Returns the file name
  /// written, or null when no folder is picked or the write failed.
  Future<String?> write(Map<String, dynamic> payload) async {
    final treeUri = _prefs.treeUri;
    if (treeUri == null || treeUri.isEmpty) return null;

    final name = backupFileName(DateTime.now());
    final tmp = await getTemporaryDirectory();
    final staging = File('${tmp.path}/$name');
    await staging.writeAsString(jsonEncode(payload));

    try {
      final uri = await _channel.invokeMethod<String>('moveIntoTree', {
        'localPath': staging.path,
        'treeUri': treeUri,
        'filename': name,
        'mimeType': 'application/json',
      });
      if (uri == null || uri.isEmpty) {
        debugPrint('[backup] folder write failed · $treeUri');
        return null;
      }
    } catch (e) {
      debugPrint('[backup] folder write threw · $e');
      return null;
    } finally {
      // moveIntoTree deletes the staging file on success; clean up on failure
      // so a permanently unwritable folder doesn't fill the cache.
      if (staging.existsSync()) {
        try {
          staging.deleteSync();
        } catch (_) {/* best effort */}
      }
    }

    await _prefs.markBackedUp(DateTime.now());
    await prune();
    return name;
  }

  /// File names currently in the picked folder, or empty when it can't be read
  /// (permission revoked, folder deleted, no folder picked).
  Future<List<String>> listNames() async {
    final treeUri = _prefs.treeUri;
    if (treeUri == null || treeUri.isEmpty) return const [];
    try {
      final names = await _channel.invokeListMethod<String>('listTree', {
        'treeUri': treeUri,
      });
      return names ?? const [];
    } catch (e) {
      debugPrint('[backup] folder list failed · $e');
      return const [];
    }
  }

  /// Deletes everything but the newest [_prefs.keep] backups. Best effort: a
  /// folder that can't be pruned keeps its files, which is untidy rather than
  /// lossy.
  Future<int> prune() async {
    final treeUri = _prefs.treeUri;
    if (treeUri == null || treeUri.isEmpty) return 0;
    final doomed = prunePlan(await listNames(), keep: _prefs.keep);
    if (doomed.isEmpty) return 0;
    try {
      final deleted = await _channel.invokeMethod<int>('deleteInTree', {
        'treeUri': treeUri,
        'names': doomed,
      });
      return deleted ?? 0;
    } catch (e) {
      debugPrint('[backup] folder prune failed · $e');
      return 0;
    }
  }

  /// Writes a backup if one is due. Called at launch and when the app is
  /// backgrounded; silent and cheap when it isn't due. Returns the file name
  /// written, or null if nothing was.
  ///
  /// [lastBackupAt] only moves on a successful write, so a folder that has
  /// stopped working is retried rather than skipped for a day - but "next
  /// opportunity" is every app switch, so an in-memory floor keeps one broken
  /// folder from being retried fifty times a minute.
  Future<String?> runIfDue({
    required Map<String, dynamic> Function() build,
    DateTime? now,
  }) async {
    if (!_prefs.isConfigured || !_prefs.autoEnabled) return null;
    final at = now ?? DateTime.now();
    if (_lastAttemptAt != null &&
        at.difference(_lastAttemptAt!) < kAutoBackupRetryFloor) {
      return null;
    }
    if (!isAutoBackupDue(lastBackupAt: _prefs.lastBackupAt, now: at)) {
      return null;
    }
    _lastAttemptAt = at;
    return write(build());
  }
}

/// The shortest gap between two automatic attempts in one session.
const Duration kAutoBackupRetryFloor = Duration(minutes: 30);
