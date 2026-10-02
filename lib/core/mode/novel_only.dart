import 'content_mode.dart';

/// Novel-only build flag.
///
/// This fork keeps the full Zangetsu source tree intact but makes the anime
/// ("Streaming") and manga code paths unreachable at runtime, so the app ships
/// as a novel reader. Every gate in the app reads this single constant, which
/// means the anime/manga code can be revived by flipping one `false` rather
/// than by re-deriving a dozen conditions.
///
/// Why a flag instead of deleting the enum values: `ContentMode`,
/// `ProviderType`, `ZKind` and `MediaKind` are matched exhaustively in
/// hundreds of `switch` expressions. Removing a case from any of them is a
/// compile error in every one of those switches, so a real delete is a
/// multi-thousand-line refactor. Gating instead keeps the analyzer green while
/// producing an identical user-visible result.
const bool kNovelOnly = true;

/// The one content mode this build exposes.
const ContentMode kOnlyMode = ContentMode.novel;

/// The modes reachable in this build — a single-element list so any widget
/// that iterates modes (mode cards, kind tab rows) collapses to one entry.
List<ContentMode> get availableModes =>
    kNovelOnly ? const [kOnlyMode] : ContentMode.values;

/// True when [mode] is one this build exposes.
bool modeAvailable(ContentMode mode) => !kNovelOnly || mode == kOnlyMode;
