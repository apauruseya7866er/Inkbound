import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../zmode/zmode_ids.dart';
import 'content_mode.dart';
import 'novel_only.dart';

/// The non-video capabilities that remain meaningful when this build exposes
/// only novels.
enum NovelCapability {
  /// Browse and read novel sources.
  novelSources,

  /// Video playback, trailers, schedules, and streaming catalogues.
  video,
}

/// Central statement of what the novel-only build may do.
///
/// The boolean flag in [novel_only.dart] is still the only switch, but callers
/// outside the UI must not re-derive its consequences from prefixes or modes.
/// This policy owns:
/// * which content, providers, and individual titles can be opened;
/// * how stale non-novel values carried by notifications are normalized;
/// * which boot-time source IDs may become active.
///
/// It intentionally knows nothing about widgets, navigation, or GetIt. That
/// keeps the policy unit-testable and prevents another low-level helper from
/// importing the UI layer.
abstract final class ModePolicy {
  /// Whether [mode] may be selected or rendered in this build.
  static bool isModeAllowed(ContentMode mode) => modeAvailable(mode);

  /// Whether a provider type may supply browsable sources in this build.
  static bool isProviderTypeAllowed(ProviderType type) =>
      !kNovelOnly || type == ProviderType.novel;

  /// Whether video-backed capabilities may run in this build.
  static bool isCapabilityAllowed(NovelCapability capability) {
    if (!kNovelOnly) return true;
    return capability == NovelCapability.novelSources;
  }

  /// Whether [sourceId] may be used for routing or restored as the active
  /// source in this build.
  ///
  /// Prefixes identify the extension ecosystems without a registry lookup.
  /// Bare JS provider IDs cannot be classified from the ID alone, so an
  /// optional resolved manifest type narrows them. An unknown type remains
  /// allowed: absence of metadata is not treated as evidence that an
  /// installed source is unavailable.
  static bool isSourceRouteAllowed(
    String sourceId, {
    Map<String, String>? manifestTypes,
    ProviderType? resolvedType,
  }) {
    if (!kNovelOnly) return true;
    if (sourceId.isEmpty || sourceId == ZmodeIds.sourceId) return true;
    if (sourceId.startsWith('lnr:')) return true;
    if (sourceId.startsWith('cs:') ||
        sourceId.startsWith('ani:') ||
        sourceId.startsWith('mihon:')) {
      return false;
    }

    final type = resolvedType ?? _providerTypeForManifest(manifestTypes?[sourceId]);
    if (type == null) return true;
    return type == ProviderType.novel;
  }

  /// Whether a route for [item] may be opened in this build.
  ///
  /// Metadata URLs are classified by their canonical kind rather than by the
  /// item's possibly stale provider type. A malformed metadata URL is not
  /// routable because there is no catalogue that can answer it.
  static bool isMediaItemRouteAllowed(MediaItem item) {
    if (!kNovelOnly) return true;
    if (ZmodeIds.isZ(item.url)) {
      return ZmodeIds.parseShow(item.url)?.kind == ZKind.novel;
    }
    return isSourceRouteAllowed(item.sourceId, resolvedType: item.type);
  }

  /// Normalizes a stored notification mode for this build.
  ///
  /// A pre-fork notification may carry Streaming or Manga while every surface
  /// that can act on it is novel-only. The notification still names a title
  /// the reader may own, so it opens as a novel rather than being discarded.
  static ProviderType notificationType(ContentMode? mode) {
    if (!kNovelOnly) {
      return switch (mode) {
        ContentMode.manga => ProviderType.manga,
        ContentMode.novel => ProviderType.novel,
        _ => ProviderType.anime,
      };
    }
    return ProviderType.novel;
  }

  /// Retains only the boot-time source IDs this build may activate.
  static Set<String> filterAllowedSourceIds(
    Iterable<String> sourceIds, {
    Map<String, String>? manifestTypes,
  }) => {
    for (final id in sourceIds)
      if (isSourceRouteAllowed(id, manifestTypes: manifestTypes)) id,
  };

  static ProviderType? _providerTypeForManifest(String? manifestType) =>
      switch (manifestType) {
        'anime' => ProviderType.anime,
        'movie' => ProviderType.movie,
        'manga' => ProviderType.manga,
        'novel' => ProviderType.novel,
        _ => null,
      };
}
