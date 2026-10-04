import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import 'tap_zones.dart';
import 'text_filter.dart';

/// Persistent reader settings — the manga/novel analogue of PlaybackPrefs.
/// Backed by a tiny untyped Hive box read anywhere via `sl<ReaderPrefs>()`.
/// Values are read with defaults so a fresh install behaves sensibly; numbers
/// are coerced defensively since Hive may round-trip them as `int`/`double`/
/// `num`.
class ReaderPrefs {
  static const String boxName = 'reader_prefs';

  /// Opens the prefs box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  // ── Novel ───────────────────────────────────────────────────────────────
  /// Reader text size in logical pixels.
  double get fontSize =>
      (_box.get('fontSize', defaultValue: 16.0) as num).toDouble();
  Future<void> setFontSize(double value) => _box.put('fontSize', value);

  /// Line-height multiplier for reader body text.
  double get lineHeight =>
      (_box.get('lineHeight', defaultValue: 1.6) as num).toDouble();
  Future<void> setLineHeight(double value) => _box.put('lineHeight', value);

  /// Reader background/text theme: 'dark' | 'black' | 'sepia'.
  String get theme => _box.get('theme', defaultValue: 'dark') as String;
  Future<void> setTheme(String value) => _box.put('theme', value);

  /// Horizontal side margin (logical pixels) around reader text.
  double get marginWidth =>
      (_box.get('marginWidth', defaultValue: 20.0) as num).toDouble();
  Future<void> setMarginWidth(double value) => _box.put('marginWidth', value);

  // ── Manga ───────────────────────────────────────────────────────────────
  /// Page reading direction: 'ltr' | 'rtl' | 'vertical'. Kept working
  /// untouched — [readingMode] below is the new, wider enum and migrates
  /// from this key; the reader itself still reads `direction` directly.
  String get direction => _box.get('direction', defaultValue: 'ltr') as String;
  Future<void> setDirection(String value) => _box.put('direction', value);

  /// Reader background colour: 'black' | 'dark'. Kept working untouched —
  /// [mangaBackground] below is the new, wider enum and migrates from this
  /// key; the reader itself still reads `background` directly.
  String get background =>
      _box.get('background', defaultValue: 'black') as String;
  Future<void> setBackground(String value) => _box.put('background', value);

  /// Whether to keep the screen awake while reading. Shared by both readers
  /// via `ReaderComfortMixin`.
  bool get keepScreenOn =>
      _box.get('keepScreenOn', defaultValue: true) as bool;
  Future<void> setKeepScreenOn(bool value) => _box.put('keepScreenOn', value);

  /// Hide the status and navigation bars while reading. Shared by both
  /// readers via `ReaderComfortMixin`.
  ///
  /// ON by default, matching every other reader: a page is the content, and
  /// a clock and three nav buttons sitting over it are not. `immersiveSticky`
  /// rather than plain `immersive`, so a swipe from either edge brings the
  /// bars back for a moment without leaving the page.
  bool get fullscreen => _box.get('fullscreen', defaultValue: true) as bool;
  Future<void> setFullscreen(bool value) => _box.put('fullscreen', value);

  /// Turn manga pages with the hardware volume keys.
  ///
  /// OFF by default, and deliberately so: this SWALLOWS the volume keys while
  /// the reader is open, so someone who never asked for it would find their
  /// volume dead with no explanation. Opt-in only.
  bool get volumeKeyPaging =>
      _box.get('volumeKeyPaging', defaultValue: false) as bool;
  Future<void> setVolumeKeyPaging(bool value) =>
      _box.put('volumeKeyPaging', value);

  /// Swap which volume key goes forward. Down-is-next matches how most readers
  /// ship; up-is-next suits holding the phone the other way round.
  bool get invertVolumeKeys =>
      _box.get('invertVolumeKeys', defaultValue: false) as bool;
  Future<void> setInvertVolumeKeys(bool value) =>
      _box.put('invertVolumeKeys', value);

  /// Pull past the end of a chapter to open the next one (and past the start
  /// for the previous). ON by default: it only triggers on a deliberate drag
  /// beyond the edge, where there is nothing else to do.
  bool get overscrollChapter =>
      _box.get('overscrollChapter', defaultValue: true) as bool;
  Future<void> setOverscrollChapter(bool value) =>
      _box.put('overscrollChapter', value);

  /// Extra space between letters, in logical pixels. 0 is the font's own.
  double get letterSpacing =>
      (_box.get('letterSpacing', defaultValue: 0.0) as num).toDouble();
  Future<void> setLetterSpacing(double value) =>
      _box.put('letterSpacing', value);

  /// Extra space between words, in logical pixels. 0 is the font's own.
  double get wordSpacing =>
      (_box.get('wordSpacing', defaultValue: 0.0) as num).toDouble();
  Future<void> setWordSpacing(double value) => _box.put('wordSpacing', value);

  /// Switch a long-strip chapter to vertical on its own, even when the
  /// direction pref says left-to-right. Manhwa is one tall image per page, so
  /// paged mode hands you sideways slices of it.
  ///
  /// On by default: someone reading a webtoon in paged mode gets a bad time
  /// and no clue why. A per-series direction override still wins — an explicit
  /// choice shouldn't be second-guessed.
  bool get autoWebtoon =>
      _box.get('autoWebtoon', defaultValue: true) as bool;
  Future<void> setAutoWebtoon(bool value) => _box.put('autoWebtoon', value);

  /// Novel page background, 0 (black) to 1 (the theme's own colour).
  ///
  /// Lets you keep a theme's text colour while darkening the page behind it.
  /// Defaults to 1, which is exactly what the theme gives today.
  double get novelBgOpacity =>
      (_box.get('novelBgOpacity', defaultValue: 1.0) as num).toDouble();
  Future<void> setNovelBgOpacity(double value) =>
      _box.put('novelBgOpacity', value);

  /// Whether the scrolling novel reader moves the page to keep the sentence being
  /// read near the middle of the screen.
  ///
  /// On by default: following the voice is the whole point of a highlighted
  /// read-aloud, and someone reading along wants the sentence held in view with
  /// the text above and below it. Off is for the reader who scrolls on their own
  /// terms and does not want the page moving — the follow otherwise yields for a
  /// few seconds after every manual scroll, but resumes on its own after that.
  bool get novelFollowNarration =>
      _box.get('novelFollowNarration', defaultValue: true) as bool;
  Future<void> setNovelFollowNarration(bool value) =>
      _box.put('novelFollowNarration', value);

  /// Auto-scroll speed on a 1–10 feel scale, not pixels per second: how fast
  /// you like it is a feel, and "60 px/s" means nothing to anyone reading.
  /// [ReaderAutoScroll] maps it to a creep rate or a page dwell depending on
  /// the reading mode.
  ///
  /// Persisted, unlike auto-scroll itself: the speed is a lasting preference,
  /// whereas whether it's *running* belongs to the reading session — nobody
  /// wants to open a chapter and find it already scrolling away. Stored under
  /// a new key so the old pixels-per-second values (60–300) can't be read back
  /// as a 1–10 speed and pin everyone to maximum.
  double get autoScrollSpeed =>
      (_box.get('autoScrollSpeedScale', defaultValue: 3.0) as num).toDouble();
  Future<void> setAutoScrollSpeed(double value) =>
      _box.put('autoScrollSpeedScale', value);

  /// Keep a small floating play/pause button on the reader while auto-scroll
  /// is on. Without it, pausing means revealing the chrome first — which
  /// defeats the point of a hands-free mode. On by default for that reason.
  bool get autoScrollButton =>
      _box.get('autoScrollButton', defaultValue: true) as bool;
  Future<void> setAutoScrollButton(bool value) =>
      _box.put('autoScrollButton', value);

  /// Where the floating auto-scroll button sits, as a fraction of the screen
  /// (0–1 on each axis) rather than pixels — so it lands in the same place
  /// after a rotation or on a different device instead of off-screen.
  /// Defaults to the lower right, clear of the bottom chrome.
  double get autoScrollButtonX =>
      (_box.get('autoScrollButtonX', defaultValue: 0.88) as num).toDouble();
  double get autoScrollButtonY =>
      (_box.get('autoScrollButtonY', defaultValue: 0.74) as num).toDouble();
  Future<void> setAutoScrollButtonPos(double x, double y) async {
    await _box.put('autoScrollButtonX', x);
    await _box.put('autoScrollButtonY', y);
  }

  /// How many pages ahead the reader warms into the disk cache after landing
  /// on a page. Six rather than the three we started with: preloading only
  /// fetches bytes now, so the extra runway costs disk and network instead of
  /// the memory it used to.
  int get preloadCount =>
      (_box.get('preloadCount', defaultValue: 6) as num).toInt().clamp(1, 8);
  Future<void> setPreloadCount(int value) =>
      _box.put('preloadCount', value.clamp(1, 8));

  /// Reading mode: 'ltr' | 'rtl' | 'vertical_paged' | 'webtoon'. Migrate-on-
  /// read from the legacy `direction` key (ltr→ltr, rtl→rtl,
  /// vertical→webtoon) until this key is explicitly written, so a fresh
  /// install and an existing install both start out reading exactly as
  /// `direction` says today.
  String get readingMode {
    final v = _box.get('readingMode') as String?;
    if (v != null) return v;
    return switch (direction) {
      'rtl' => 'rtl',
      'vertical' => 'webtoon',
      _ => 'ltr',
    };
  }

  Future<void> setReadingMode(String value) =>
      _box.put('readingMode', value);

  // ── Tap zones ───────────────────────────────────────────────────────────
  /// What tapping each part of the page does, per reading mode. Stored as JSON
  /// so the shape can change without a migration; anything unreadable falls
  /// back to the default rather than leaving a dead screen.
  TapZoneLayout tapZones(String layoutId) => TapZoneLayout.fromJsonString(
    _box.get('tapZones_$layoutId') as String?,
    layoutId,
  );

  /// The layout for the mode currently being read.
  TapZoneLayout tapZonesForMode(String readingMode) =>
      tapZones(TapZoneLayout.idForReadingMode(readingMode));

  Future<void> setTapZones(TapZoneLayout layout) =>
      _box.put('tapZones_${layout.id}', layout.toJsonString());

  Future<void> resetTapZones() async {
    for (final id in TapZoneLayout.ids) {
      await _box.delete('tapZones_$id');
    }
  }

  /// Page fit: 'contain' | 'width' | 'height' | 'original' | 'smart'.
  /// Default 'contain' renders identically to the reader's current hardcoded
  /// `BoxFit.contain`/`BoxFit.fitWidth`.
  String get fitMode => _box.get('fitMode', defaultValue: 'contain') as String;
  Future<void> setFitMode(String value) => _box.put('fitMode', value);

  /// Manga background: 'black' | 'white' | 'gray' | 'system'. Migrate-on-read
  /// from the legacy `background` key (black→black, dark→system, since
  /// 'dark' already renders the app's own theme background) until this key
  /// is explicitly written.
  String get mangaBackground {
    final v = _box.get('mangaBackground') as String?;
    if (v != null) return v;
    return background == 'black' ? 'black' : 'system';
  }

  Future<void> setMangaBackground(String value) =>
      _box.put('mangaBackground', value);

  /// Pair facing pages into a landscape double-page spread.
  bool get doublePageLandscape =>
      _box.get('doublePageLandscape', defaultValue: false) as bool;
  Future<void> setDoublePageLandscape(bool value) =>
      _box.put('doublePageLandscape', value);

  /// Trim near-uniform edge margins from a page.
  bool get cropBorders => _box.get('cropBorders', defaultValue: false) as bool;
  Future<void> setCropBorders(bool value) => _box.put('cropBorders', value);

  /// Gap in logical pixels between pages in webtoon (vertical) mode.
  double get webtoonPageGap =>
      (_box.get('webtoonPageGap', defaultValue: 0.0) as num).toDouble();
  Future<void> setWebtoonPageGap(double value) =>
      _box.put('webtoonPageGap', value);

  /// Reading colour filter: 'none' | 'grayscale' | 'invert' | 'sepia'.
  String get colorFilter =>
      _box.get('colorFilter', defaultValue: 'none') as String;
  Future<void> setColorFilter(String value) => _box.put('colorFilter', value);

  // ── Shared comfort (both readers) ──────────────────────────────────────
  /// Screen brightness override, 0..1, or -1 for "system" — i.e. no
  /// override, matching the player's own default and today's reader
  /// behavior (the reader has never touched brightness before this).
  double get brightness =>
      (_box.get('brightness', defaultValue: -1.0) as num)
          .toDouble()
          .clamp(-1.0, 1.0);
  Future<void> setBrightness(double value) =>
      _box.put('brightness', value.clamp(-1.0, 1.0));

  /// Orientation lock while reading: 'system' | 'portrait' | 'landscape'.
  /// Default 'system' applies no lock — today's behavior.
  String get orientation =>
      _box.get('orientation', defaultValue: 'system') as String;
  Future<void> setOrientation(String value) => _box.put('orientation', value);

  // ── Novel (typography) ─────────────────────────────────────────────────
  /// Body font family: 'inter' | 'serif' | 'system'.
  String get fontFamily =>
      _box.get('fontFamily', defaultValue: 'inter') as String;
  Future<void> setFontFamily(String value) => _box.put('fontFamily', value);

  /// Whether body text is justified instead of ragged-edge.
  bool get textAlignJustify =>
      _box.get('textAlignJustify', defaultValue: false) as bool;
  Future<void> setTextAlignJustify(bool value) =>
      _box.put('textAlignJustify', value);

  /// Extra spacing (logical pixels) between paragraphs.
  double get paragraphSpacing =>
      (_box.get('paragraphSpacing', defaultValue: 8.0) as num).toDouble();
  Future<void> setParagraphSpacing(double value) =>
      _box.put('paragraphSpacing', value);

  /// Whether the novel reader paginates into book-style pages instead of one
  /// continuous scroll.
  bool get novelPaginated =>
      _box.get('novelPaginated', defaultValue: false) as bool;
  Future<void> setNovelPaginated(bool value) =>
      _box.put('novelPaginated', value);

  /// Novel text direction: 'auto' | 'ltr' | 'rtl'. 'auto' detects RTL scripts
  /// (Arabic, Hebrew, ...) from the chapter text itself so Arabic novels read
  /// right-to-left without the user having to flip a setting per source.
  String get textDirection =>
      _box.get('textDirection', defaultValue: 'auto') as String;
  Future<void> setTextDirection(String value) =>
      _box.put('textDirection', value);

  // ── Regex text cleanup ──────────────────────────────────────────────────
  /// Whether ads and injected text are stripped from chapters at all.
  ///
  /// One switch for the whole built-in rule set, separate from the individual
  /// rules: a user who wants to read a chapter exactly as the source shipped it
  /// (to check a translation, or to see why a sentence vanished) should not
  /// have to switch off a dozen rules to do it.
  ///
  /// Sentences hidden from the reader are *not* covered by it — see
  /// [activeTextFilterRules]. On by default; every shipped rule is anchored to
  /// the start of a line and matched per line, so a rule can only fire on text
  /// shaped like an ad — but "on by default" is a judgement call about a filter
  /// that deletes prose, and this is where it is made.
  bool get textFiltersEnabled =>
      _box.get('textFiltersEnabled', defaultValue: true) as bool;
  Future<void> setTextFiltersEnabled(bool value) async {
    await _box.put('textFiltersEnabled', value);
    invalidateTextFilterCache();
  }

  /// The user's own rules: sentences hidden from the reader plus any pattern
  /// typed into the settings screen.
  ///
  /// Stored as one JSON string, not a Hive list of maps, so a rule that gains a
  /// field cannot leave a half-readable entry behind, and so a single bad entry
  /// costs one rule rather than the whole set.
  List<TextFilterRule> get textFilterRules =>
      decodeTextFilterRules(_box.get('textFilterRules') as String?);

  Future<void> setTextFilterRules(List<TextFilterRule> rules) async {
    await _box.put('textFilterRules', encodeTextFilterRules(rules));
    invalidateTextFilterCache();
  }

  /// Built-in rules the user has switched off.
  ///
  /// Tracked by id rather than by deleting the rule, so a later version can
  /// improve a built-in pattern and have the user inherit the fix instead of
  /// being stuck with the old one forever.
  Set<String> get disabledTextFilterIds {
    final raw = _box.get('disabledTextFilterIds') as List?;
    if (raw == null) return const {};
    return raw.map((e) => e.toString()).toSet();
  }

  Future<void> setDisabledTextFilterIds(Set<String> ids) async {
    await _box.put('disabledTextFilterIds', ids.toList());
    invalidateTextFilterCache();
  }

  /// Hides [sentence] everywhere, in every novel.
  ///
  /// Global on purpose. The sentences worth hiding are injected by the source
  /// and translator, so the same line comes back in every chapter of every book
  /// they publish — a per-book rule would mean hiding it again, by hand, for
  /// each of the hundreds of books a reader has.
  ///
  /// Returns the rule, or the one already covering it: hiding the same sentence
  /// twice used to leave two identical entries to delete.
  Future<TextFilterRule> hideTextEverywhere(String sentence) async {
    final trimmed = sentence.trim();
    if (trimmed.isEmpty) {
      return TextFilterRule.hiddenSentence(sentence, id: '');
    }
    final rules = textFilterRules;
    final existing = rules.where(
      (r) => r.pattern == TextFilterRule.hiddenSentence(trimmed, id: '').pattern,
    );
    if (existing.isNotEmpty) return existing.first;

    final rule = TextFilterRule.hiddenSentence(
      trimmed,
      id: 'hidden_${DateTime.now().microsecondsSinceEpoch}',
    );
    await setTextFilterRules([...rules, rule]);
    return rule;
  }

  /// Undoes [hideTextEverywhere].
  Future<void> removeTextFilterRule(String id) async {
    await setTextFilterRules(
      textFilterRules.where((r) => r.id != id).toList(growable: false),
    );
  }

  /// Every rule that should apply, built-ins and custom together.
  ///
  /// The master switch governs the built-ins only. The reader's own hidden
  /// sentences are not defaults: each one is something they were shown, chose,
  /// and confirmed — so it applies even with the built-ins off, or hiding a
  /// sentence would quietly do nothing for anybody who has turned the ads off
  /// (which is exactly who ends up hiding sentences one at a time).
  List<TextFilterRule> get activeTextFilterRules {
    final disabled = disabledTextFilterIds;
    final builtinsOn = textFiltersEnabled;
    return [
      for (final r in builtinTextFilterRules)
        r.copyWith(isEnabled: builtinsOn && !disabled.contains(r.id)),
      ...textFilterRules,
    ];
  }

  /// The engine for the saved rules, rebuilt only when they change.
  ///
  /// The chapter has to be cleaned in more places than the reader: the
  /// narration that rolls into the next chapter in the background is parsed
  /// with the reader widget already gone, so the rules cannot simply be handed
  /// down from there. Reading them from prefs at the point of use is the only
  /// way both paths see the same rules, and caching on the rule text keeps
  /// that to one rebuild per change rather than one per chapter.
  TextFilterEngine get textFilterEngine {
    final rules = activeTextFilterRules;
    final key = rules
        .map((r) => '${r.id}|${r.isEnabled ? 1 : 0}|${r.pattern}')
        .join('\n');
    final cached = _engine;
    if (cached != null && _engineKey == key) return cached;
    final built = TextFilterEngine(rules);
    _engine = built;
    _engineKey = key;
    return built;
  }
}

TextFilterEngine? _engine;
String? _engineKey;

/// Drops the cached engine so the next read picks the new rules up.
///
/// Every mutating method above calls this; the key check in
/// [ReaderPrefs.textFilterEngine] is the belt to these braces, not a
/// replacement for them, so that a rule added by a path that forgot to call
/// this still shows up on the next chapter.
void invalidateTextFilterCache() {
  _engine = null;
  _engineKey = null;
}
