import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive/hive.dart';

import '../aniyomi/aniyomi_extension_service.dart';
import '../aniyomi/aniyomi_provider.dart';
import '../di/injector.dart';
import '../lnreader/lnreader_manager.dart';
import '../mihon/mihon_extension_service.dart';
import '../mihon/mihon_manager.dart';
import '../mihon/mihon_provider.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_manager.dart';
import '../provider/provider_registry.dart';

/// Outcome of one uninstall attempt.
///
/// [failure] is null on success. A failure is a short human-readable reason, not
/// an exception — matching [MihonExtensionService.uninstall], which reports why
/// it could not delete instead of throwing so the source list stays consistent
/// and the caller can show the reason.
class SourceUninstallResult {
  const SourceUninstallResult(this.failure);

  const SourceUninstallResult.success() : failure = null;

  /// Null on success; otherwise a short human-readable reason.
  final String? failure;

  bool get ok => failure == null;
}

/// Which ecosystem's delete path a source id belongs to.
enum SourceEcosystem {
  cloudStream,
  aniyomi,
  mihon,
  lnReader,

  /// A JS provider from an Inkbound/Zangetsu repo. The unmarked default: these
  /// ids carry no prefix.
  jsProvider,
}

/// Removes an installed source, whatever ecosystem it belongs to.
///
/// This is the ONE place in the app that deletes a source. The per-ecosystem
/// sources screens used to each carry their own copy of this — delete the APK,
/// drop the Hive entry, detach from the manager — which is how a stale APK or a
/// leftover Hive row resurrects a source on the next launch, silently. With
/// several screens deleting the same way, the copies drift, and the screen with
/// the bug is whichever one nobody re-reads.
///
/// Callers own the two things this deliberately does not: the confirmation
/// dialog, and what the UI does afterwards (drop the row, toast, refresh). Every
/// caller should route here rather than re-implementing the delete.
abstract final class SourceUninstaller {
  /// Z-Mode is a meta-source — a switch between modes, with nothing installed
  /// behind it — so there is nothing to delete.
  static const String zModeSourceId = 'zm';

  /// Whether [sourceId] is something this can actually remove. False for Z-Mode
  /// and for a blank id, so a caller can hide the action rather than offer one
  /// that goes nowhere.
  static bool canUninstall(String sourceId) =>
      sourceId.isNotEmpty && sourceId != zModeSourceId;

  /// The ecosystem [sourceId] belongs to, i.e. which delete runs for it.
  ///
  /// Prefix order matters: `mihon:` has to be recognised before the unprefixed
  /// JS fallback, or every Mihon source would try to delete a registry entry
  /// that was never there.
  static SourceEcosystem ecosystemOf(String sourceId) {
    if (sourceId.startsWith('cs:')) return SourceEcosystem.cloudStream;
    if (sourceId.startsWith('ani:')) return SourceEcosystem.aniyomi;
    if (sourceId.startsWith('mihon:')) return SourceEcosystem.mihon;
    if (sourceId.startsWith('lnr:')) return SourceEcosystem.lnReader;
    return SourceEcosystem.jsProvider;
  }

  /// Uninstalls the source behind [sourceId].
  ///
  /// Never throws: any failure is reported as a non-null [SourceUninstallResult
  /// .failure] so a bulk uninstall keeps going through the rest of the selection
  /// instead of abandoning the remainder on the first bad one.
  static Future<SourceUninstallResult> uninstall(String sourceId) async {
    if (!canUninstall(sourceId)) {
      return const SourceUninstallResult('not an installed source');
    }
    try {
      return switch (ecosystemOf(sourceId)) {
        SourceEcosystem.cloudStream => await _uninstallCloudStream(sourceId),
        SourceEcosystem.aniyomi => await _uninstallAniyomi(sourceId),
        SourceEcosystem.mihon => await _uninstallMihon(sourceId),
        SourceEcosystem.lnReader => await _uninstallLnReader(sourceId),
        SourceEcosystem.jsProvider => await _uninstallJsProvider(sourceId),
      };
    } catch (e) {
      debugPrint('[source-uninstall] $sourceId failed: $e');
      return SourceUninstallResult('$e');
    }
  }

  /// Uninstalls a whole Mihon extension (every language copy of one APK).
  ///
  /// Kept separate from [uninstall] because the Mihon/Aniyomi repository tabs
  /// uninstall by PACKAGE — an extension the user picked out of a repo — while
  /// a source row and this file's callers hold a single source id.
  static Future<SourceUninstallResult> uninstallMihonExtension(
    String pkg,
  ) async {
    if (!sl.isRegistered<MihonManager>()) {
      return const SourceUninstallResult('no Mihon manager');
    }
    String? failure;
    try {
      failure = await MihonExtensionService.uninstall(pkg);
    } catch (e) {
      debugPrint('[source-uninstall] mihon $pkg: $e');
      failure = '$e';
    }
    // Detach UNCONDITIONALLY, even when the on-disk delete failed or threw. The
    // manager is what the picker, cross-source search and the health screen all
    // read, so a provider left registered after a failed uninstall is precisely
    // the "still listed, still searched, still broken" state the user opened
    // this screen to escape. An orphaned APK is the milder failure: it is
    // re-cleanable from the Mihon sources screen.
    sl<MihonManager>().removeWhere((p) => p.pkg == pkg);
    return SourceUninstallResult(failure);
  }

  /// Aniyomi's uninstall deletes the extension APK as well as the box entry.
  ///
  /// The Aniyomi repository tab's own `_defaultUninstall` used to skip the APK
  /// delete, so an extension uninstalled from the Repositories tab came BACK on
  /// the next cold start — `loadInstalled` re-reads the directory — while the
  /// same uninstall from the Installed tab stuck. Both paths call this now.
  static Future<SourceUninstallResult> uninstallAniyomiExtension(
    String pkg,
  ) async {
    if (!sl.isRegistered<AniyomiManager>()) {
      return const SourceUninstallResult('no Aniyomi manager');
    }
    String? failure;
    try {
      failure = await _deleteAniyomiApk(pkg);
    } catch (e) {
      debugPrint('[source-uninstall] aniyomi $pkg: $e');
      failure = '$e';
    }
    // Unconditional, for the same reason as Mihon above.
    sl<AniyomiManager>().removeWhere(
      (p) => p is AniyomiProvider && p.pkg == pkg,
    );
    return SourceUninstallResult(failure);
  }

  // ── ecosystems ─────────────────────────────────────────────────────────────

  static Future<SourceUninstallResult> _uninstallLnReader(
    String sourceId,
  ) async {
    if (!sl.isRegistered<LnReaderManager>()) {
      return const SourceUninstallResult('no LNReader manager');
    }
    await sl<LnReaderManager>().uninstall(sourceId.substring('lnr:'.length));
    return const SourceUninstallResult.success();
  }

  /// Mihon: the box entry AND the APK, then detach every source of that package
  /// from the manager. Extension-scoped — one APK serves one source per
  /// language, so removing any of them removes the install they share. Same as
  /// the Mihon sources screen has always done.
  static Future<SourceUninstallResult> _uninstallMihon(String sourceId) async {
    if (!sl.isRegistered<MihonManager>()) {
      return const SourceUninstallResult('no Mihon manager');
    }
    final manager = sl<MihonManager>();
    final provider = manager.get(sourceId);
    if (provider is! MihonProvider) {
      return const SourceUninstallResult('source not installed');
    }
    return uninstallMihonExtension(provider.pkg);
  }

  static Future<SourceUninstallResult> _uninstallAniyomi(
    String sourceId,
  ) async {
    if (!sl.isRegistered<AniyomiManager>()) {
      return const SourceUninstallResult('no Aniyomi manager');
    }
    final manager = sl<AniyomiManager>();
    final provider = manager.get(sourceId);
    final pkg = provider is AniyomiProvider ? provider.pkg : null;
    if (pkg != null && pkg.isNotEmpty) {
      return uninstallAniyomiExtension(pkg);
    }
    // No package (a source that did not come from a repo install): drop it from
    // the manager alone, which is all there is to drop.
    manager.removeWhere((p) => p.sourceId == sourceId);
    return const SourceUninstallResult.success();
  }

  /// JS (Zangetsu repo) provider: the registry entry is keyed by
  /// `'$repoUrl::$sourceId'`, not by the bare source id, so the composite key is
  /// rebuilt from the entry itself rather than guessed.
  static Future<SourceUninstallResult> _uninstallJsProvider(
    String sourceId,
  ) async {
    if (!sl.isRegistered<ProviderRegistry>()) {
      return const SourceUninstallResult('no provider registry');
    }
    final registry = sl<ProviderRegistry>();
    final entry = registry.entryFor(sourceId);
    if (entry == null) {
      // Not persisted (e.g. a bundled provider): there is no entry to delete,
      // but it still has to leave the runtime or the picker keeps offering it.
      if (sl.isRegistered<ProviderManager>()) {
        sl<ProviderManager>().remove(sourceId);
      }
      return const SourceUninstallResult.success();
    }
    await registry.uninstall(
      ProviderRegistry.providerKey(entry.originRepoUrl, entry.name),
    );
    return const SourceUninstallResult.success();
  }

  /// CloudStream: delegates to the manager, which owns the repo-scoped native
  /// call. Everything CS-specific (which repo an install came from, which catalog
  /// entry matches it) stays in the manager that already answers those questions
  /// for the CS sources screen.
  static Future<SourceUninstallResult> _uninstallCloudStream(
    String sourceId,
  ) async {
    if (!sl.isRegistered<CloudStreamManager>()) {
      return const SourceUninstallResult('no CloudStream manager');
    }
    final internalName = CloudStreamManager.identityOf(sourceId);
    if (internalName.isEmpty) {
      return const SourceUninstallResult('source not installed');
    }
    await sl<CloudStreamManager>().uninstallPluginByName(internalName);
    return const SourceUninstallResult.success();
  }

  /// Deletes the APK an Aniyomi package installed, plus its box entry.
  ///
  /// Box first, then file: a crash between the two leaves an orphaned APK
  /// (still loadable, and still uninstallable) rather than a box entry pointing
  /// at a file that isn't there — invisible in the list, with no row left to
  /// uninstall from. Same ordering Mihon uses, for the same reason.
  static Future<String?> _deleteAniyomiApk(String pkg) async {
    if (!Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
      return null;
    }
    final box = Hive.box<dynamic>(AniyomiExtensionService.installedBoxName);
    final apkPath = box.get(pkg) as String?;
    await box.delete(pkg);
    if (apkPath == null) return null;
    try {
      final f = File(apkPath);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[source-uninstall] deleting $apkPath failed: $e');
      return '$e';
    }
    return null;
  }
}
