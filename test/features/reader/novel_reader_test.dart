import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/page_content.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/reading_provider.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/reading/read_store.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/reading/tap_zones.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';
import 'package:watch_app/features/reader/tts_audiobook_sheet.dart';
import 'package:watch_app/features/reader/novel_reader_screen.dart';

/// A fake reading-capable source that hands back canned text per chapter
/// URL — mirrors `_FakeReadingProvider` in reading_leaf_routing_test.dart,
/// with per-URL text added so a widget test can tell chapters apart.
class _FakeReadingProvider implements BaseProvider, ReadingProvider {
  _FakeReadingProvider(this.sourceId, this.textByUrl, {this.folderByUrl});

  @override
  final String sourceId;
  final Map<String, String> textByUrl;

  /// Stands in for a real downloaded chapter's on-disk folder, without any
  /// actual ChapterDownloadStore/file I/O — a widget test just needs
  /// `ChapterText.folder` to be non-null for a URL to prove the reader
  /// threads it through to `HtmlWidget.baseUrl`.
  final Map<String, String>? folderByUrl;

  @override
  String get displayName => sourceId;

  @override
  Future<ProviderInfo> getInfo() => throw UnimplementedError();

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) => throw UnimplementedError();

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) => throw UnimplementedError();

  @override
  Future<List<PageImage>> getPages(String chapterUrl) =>
      throw UnimplementedError();

  @override
  Future<ChapterText> getText(String chapterUrl) async => ChapterText(
        html: '<p>${textByUrl[chapterUrl] ?? 'missing'}</p>',
        folder: folderByUrl?[chapterUrl],
      );
}

/// The same fake, but hands the chapter HTML back verbatim instead of wrapping
/// it in a `<p>`. The long-press geometry tests need the real block structure —
/// paragraphs, a heading, and the whitespace between them — because that
/// structure is exactly what the hit test has to navigate.
class _RawHtmlReadingProvider extends _FakeReadingProvider {
  _RawHtmlReadingProvider(super.sourceId, super.textByUrl);

  @override
  Future<ChapterText> getText(String chapterUrl) async =>
      ChapterText(html: textByUrl[chapterUrl] ?? 'missing');
}

/// A reading source whose `getText` throws on the first call and succeeds on
/// every call after — for the error/retry path.
class _FlakyReadingProvider implements BaseProvider, ReadingProvider {
  _FlakyReadingProvider(this.sourceId, this.text);

  @override
  final String sourceId;
  final String text;
  int calls = 0;

  @override
  String get displayName => sourceId;

  @override
  Future<ProviderInfo> getInfo() => throw UnimplementedError();

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) => throw UnimplementedError();

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) => throw UnimplementedError();

  @override
  Future<List<PageImage>> getPages(String chapterUrl) =>
      throw UnimplementedError();

  @override
  Future<ChapterText> getText(String chapterUrl) async {
    calls++;
    if (calls == 1) throw Exception('network blip');
    return ChapterText(html: '<p>$text</p>');
  }
}

/// Counts every [ReadHistory.save] call so a test can prove the reader writes
/// once per user action (chapter change, dispose, seek commit) rather than
/// once per frame or per drag tick — without reaching into private reader state.
/// Only manga_reader_test.dart has save-count tests today; kept here so the two
/// reader suites keep identical harnesses.
class _SpyReadHistory extends ReadHistory {
  int saveCalls = 0;

  @override
  Future<void> save(ReadEntry e) {
    saveCalls++;
    return super.save(e);
  }
}

Episode chapter(String id, String url, {double? number}) =>
    Episode(id: id, title: id, url: url, number: number);

/// Records every [Tracker.scrobble] call — no network, everything else is a
/// no-op. Mirrors media_kind_test.dart's `_FakeTracker`.
class _FakeTracker extends ChangeNotifier implements Tracker {
  @override
  bool get supportsReading => true;

  int scrobbleCalls = 0;
  MediaKind? lastScrobbleKind;
  int? lastScrobbleEpisode;
  int? lastScrobbleMalId;
  bool? lastScrobbleNovel;

  @override
  String get displayName => 'Fake';
  @override
  bool get isConnected => true;
  @override
  String? get viewerName => 'someone';
  @override
  String? get viewerAvatar => null;
  @override
  bool get autoSync => true;
  @override
  set autoSync(bool value) {}

  @override
  Future<bool> connect() async => true;
  @override
  Future<void> disconnect() async {}

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    int? season,
    int? seasonEpisode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    scrobbleCalls++;
    lastScrobbleKind = kind;
    lastScrobbleEpisode = episode;
    lastScrobbleMalId = malId;
    lastScrobbleNovel = novel;
  }

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<List<TrackerListItem>> fetchList() async => const [];

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async => null;

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async => const [];

  @override
  Map<String, dynamic>? exportSession() => null;
  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}

/// The smallest thing the reader will accept as a read-aloud cubit.
///
/// The reader only asks it to adopt a chapter, attach a chapter source, play,
/// and be listened to by the panel. A real cubit needs a platform and a prefs
/// box behind it, none of which this is testing — what matters here is the
/// order: chapter segmented first, player opened second.
class _StubTtsCubit extends Cubit<TtsState> implements TtsCubit {
  _StubTtsCubit()
    : super(
        TtsState(
          status: TtsStatus.speaking,
          available: true,
          bookId: 'b1',
          chapterId: 'c1',
          totalSentences: 3,
          sentences: [
            for (var i = 0; i < 3; i++)
              TtsSentenceView(
                index: i,
                text: 'Sentence $i of the chapter goes here.',
                blockIndex: i,
                pauseAfterMs: 0,
              ),
          ],
          currentIndex: 0,
        ),
      );

  int playCalls = 0;
  final List<String> adopted = [];

  @override
  Future<void> adoptChapter({
    required String bookId,
    required String chapterId,
    required List<TtsSentenceView> views,
    bool force = false,
  }) async {
    adopted.add(chapterId);
  }

  @override
  Future<void> play({int? from}) async => playCalls++;

  /// Everything else the reader asks of a cubit - attaching the chapter source,
  /// transport, settings, lifecycle - is accepted and ignored.
  ///
  /// Throwing on the unlisted ones would fail these tests for reasons that have
  /// nothing to do with what is being tested. The two calls that matter are
  /// overridden above, so nothing that matters is silently swallowed.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  // AniyomiManager/ProviderManager construction needs the test binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('novelSpans', () {
    test('paragraphs, bold/italic, tags stripped', () {
      // NOTE: the brief's literal fixture used '<p>Next</p>' as the second
      // paragraph and then asserted `isNot(contains('x'))` for the stripped
      // script tag — but "Next" itself contains an 'x', which makes that
      // assertion fail unconditionally regardless of whether script
      // stripping works. Swapped to "Then" (same shape, no incidental 'x')
      // so the assertion tests what it says it tests.
      final spans = novelSpans(
        '<p>Hello <b>bold</b> and <i>it</i></p><p>Then</p>'
        '<script>x</script>',
        const TextStyle(),
      );
      final text = spans.map((s) => s.toPlainText()).join();
      expect(text, contains('Hello bold and it'));
      expect(text, contains('\n')); // paragraph break
      expect(text, isNot(contains('x'))); // script stripped
      expect(spans.any((s) => s.style?.fontWeight == FontWeight.bold), isTrue);
    });

    test('named and numeric entities decode', () {
      final spans = novelSpans(
        '<p>Rock &amp; Roll &mdash; it&#39;s &#x2019;90s &ndash; forever</p>',
        const TextStyle(),
      );
      final text = spans.map((s) => s.toPlainText()).join();
      expect(text, contains('Rock & Roll'));
      expect(text, contains('—')); // &mdash;
      expect(text, contains("it's")); // &#39;
      expect(text, contains('’90s')); // &#x2019;
      expect(text, contains('–')); // &ndash;
    });

    // Regression pin for the reviewer-found crash: String.fromCharCode
    // throws RangeError outside 0..0x10FFFF, and novelSpans runs
    // synchronously from build() — outside the only try/catch in the file
    // (which just guards the network fetch in _load()). A source returning
    // an out-of-range numeric reference must not crash the reader.
    test('a malformed/out-of-range numeric entity does not throw and is left '
        'as raw text', () {
      expect(
        () => novelSpans('<p>Before &#99999999; after</p>', const TextStyle()),
        returnsNormally,
      );
      final spans = novelSpans(
        '<p>Before &#99999999; after</p>',
        const TextStyle(),
      );
      final text = spans.map((s) => s.toPlainText()).join();
      expect(text, contains('Before'));
      expect(text, contains('after'));
      expect(text, contains('&#99999999;')); // left unrecognised, as-is
    });

    test('paragraphSpacing defaults to 0 (no widget gap, same as before '
        'this pref existed)', () {
      final spans = novelSpans('<p>One</p><p>Two</p>', const TextStyle());
      expect(spans.whereType<WidgetSpan>(), isEmpty);
    });

    test('paragraphSpacing > 0 adds a sized WidgetSpan gap after each '
        'paragraph close, but not after a bare <br> line break', () {
      final spans = novelSpans(
        '<p>One</p><p>Two<br>Three</p>',
        const TextStyle(),
        paragraphSpacing: 12,
      );
      final gaps = spans.whereType<WidgetSpan>().toList();
      // Two </p> closes ("One", "Three") each get a gap — the <br> between
      // "Two" and "Three" does not (it's a soft line break, not a block).
      expect(gaps, hasLength(2));
      for (final gap in gaps) {
        expect((gap.child as SizedBox).height, 12);
      }
      // No character/content is lost around the gaps.
      final text = spans.map((s) => s.toPlainText()).join();
      expect(text, contains('One'));
      expect(text, contains('Two'));
      expect(text, contains('Three'));
    });
  });

  group('novelFontFamily', () {
    test('maps inter/serif/system, defaulting unknown keys to Inter', () {
      expect(novelFontFamily('inter'), 'Inter');
      expect(novelFontFamily('serif'), 'serif');
      expect(novelFontFamily('system'), isNull);
      expect(novelFontFamily('nonsense'), 'Inter');
    });
  });

  group('NovelReaderScreen', () {
    late Directory dir;
    late _SpyReadHistory spyHistory;
    // Exposed so individual tests can swap the registered fake provider
    // in-place (AniyomiManager.register replaces by sourceId) instead of
    // building a second ProviderManager — each one spins up its own QuickJS
    // runtime with an internal periodic timer that's never disposed, and a
    // second one constructed inside a testWidgets body (FakeAsync zone)
    // trips the "pending timer" end-of-test invariant.
    late AniyomiManager ani;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('novel_reader_test');
      Hive.init(dir.path);
      IncognitoMode.notifier.value = false;

      await ReadStore.init();
      await ReadHistory.init();
      await ReaderPrefs.init();

      sl.registerSingleton<ReadStore>(ReadStore());
      spyHistory = _SpyReadHistory();
      sl.registerSingleton<ReadHistory>(spyHistory);
      sl.registerSingleton<ReaderPrefs>(ReaderPrefs());

      ani = AniyomiManager();
      ani.register(
        _FakeReadingProvider('ani:n', {
          'u1': 'chapter one text',
          'u2': 'chapter two text',
        }),
      );
      sl.registerSingleton<SourceRepository>(
        SourceRepository(
          manager: ProviderManager(dio: Dio()),
          csManager: CloudStreamManager(),
          aniManager: ani,
          activeSource: ActiveSourceCubit(),
          prefs: PlaybackPrefs(),
        ),
      );
    });

    tearDown(() async {
      await sl.reset();
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Widget harness() => MaterialApp(
      home: NovelReaderScreen(
        sourceId: 'ani:n',
        showId: 'b1',
        showTitle: 'Book',
        cover: null,
        chapters: [chapter('c1', 'u1'), chapter('c2', 'u2')],
        startIndex: 0,
      ),
    );

    /// A bounded pump, not `pumpAndSettle`.
    ///
    /// These tests press the page, and after a press the reader keeps
    /// scheduling frames — the dialog's route animation, then the gesture's
    /// own settling. `pumpAndSettle` waits for a frame that never comes and
    /// the test hangs for its full timeout instead of failing usefully. A
    /// fixed couple of pumps is both bounded and enough for a route to be in.
    Future<void> settleBriefly(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    /// The sentence the dialog is offering.
    String dialogQuote(WidgetTester tester) => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .whereType<String>()
        .first;

    Future<void> expectHideDialog(WidgetTester tester, String quoted) async {
      await settleBriefly(tester);
      expect(find.text(quoted), findsWidgets);
      expect(find.text('Hide'), findsOneWidget);
    }

    /// Takes the reader down before the test ends.
    ///
    /// Left mounted, it keeps the timers a live reader keeps — the auto-scroll
    /// resume grace among them — and the test never finishes. The existing
    /// long-press test disposes for the same reason.
    Future<void> disposeReader(WidgetTester tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    }

    testWidgets('renders chapter text and advances to next chapter', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(find.textContaining('chapter one text', findRichText: true), findsOneWidget);

      // chrome → next — the scroll body is now a lazy sliver HTML view
      // inside a CustomScrollView (was SingleChildScrollView, then a
      // ListView.builder), so the tap-to-toggle-chrome target moved again.
      await tester.tap(find.byType(CustomScrollView));
      await tester.pumpAndSettle();

      // Advancing writes a flushed ReadHistory entry, which is real Hive
      // I/O — run it under runAsync so the fire-and-forget write actually
      // resolves instead of dangling into tearDown's Hive.close().
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.skip_next_rounded));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('chapter two text', findRichText: true), findsOneWidget);

      // Explicitly dispose the reader (under runAsync, same reason as
      // above) instead of relying on the framework's between-test teardown
      // — dispose() also fire-and-forgets a flushed ReadHistory write, and
      // letting that dangle outside runAsync hangs tearDown's Hive.close().
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    });

    testWidgets(
      'a chapterText failure shows the error state (not a crash, not a '
      'stuck spinner), and Retry re-fetches successfully',
      (tester) async {
        // Swap in a source that fails once then succeeds, in place of the
        // shared setUp's always-succeeding fake — replaces the 'ani:n' entry
        // on the same AniyomiManager/SourceRepository setUp already built.
        ani.register(_FlakyReadingProvider('ani:n', 'chapter one text'));

        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        expect(find.text('Retry'), findsOneWidget);
        expect(find.textContaining('chapter one text', findRichText: true), findsNothing);

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();

        expect(find.textContaining('chapter one text', findRichText: true), findsOneWidget);
        expect(find.text('Retry'), findsNothing);

        // Dispose under runAsync — same reason as the tests above.
        await tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox());
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
      },
    );

    testWidgets('reopening a chapter restores its saved scroll permille', (
      tester,
    ) async {
      // A long chapter so it actually scrolls in the test viewport, so the
      // restore has something non-trivial to prove.
      final longText = List.generate(
        120,
        (i) => 'Paragraph number $i with enough words to take real space.',
      ).join('</p><p>');
      // Same reasoning as the error/retry test: replace the fake in-place on
      // the existing AniyomiManager rather than building a second
      // ProviderManager.
      ani.register(_FakeReadingProvider('ani:n', {'u1': longText}));
      // Pre-seed a saved position: 50% scrolled. Real Hive I/O awaited
      // directly (not fire-and-forget like the production code), so it
      // needs runAsync too — a plain await inside testWidgets' FakeAsync
      // zone never resolves a real dart:io completion.
      await tester.runAsync(
        () => sl<ReadStore>().save('ani:n', 'b1', 'c1', pos: 500, total: 1000),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderScreen(
            sourceId: 'ani:n',
            showId: 'b1',
            showTitle: 'Book',
            cover: null,
            chapters: [chapter('c1', 'u1')],
            startIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll body is a lazy sliver HTML view inside a CustomScrollView now.
      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      final controller = scrollView.controller!;

      // The restore now polls instead of landing in one post-frame jump — a
      // lazy sliver's maxScrollExtent is only an estimate until content near
      // the target has actually laid out, so it takes a couple of the
      // restore's own 50ms ticks to converge. Give it more than enough of
      // them before checking where it landed.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();

      final maxExtent = controller.position.maxScrollExtent;
      expect(maxExtent, greaterThan(0)); // sanity: the chapter actually scrolls

      final expectedOffset = 0.5 * maxExtent; // 500 / 1000 permille
      // Lazy sliver layout means the restore is percent-accurate, not
      // pixel-exact: the scroll extent keeps growing as more paragraphs lay
      // out after the jump, so allow a few percent of drift. Still tight
      // enough to fail if resume landed at the top or the wrong place.
      expect(controller.offset, closeTo(expectedOffset, maxExtent * 0.03));

      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    });

    testWidgets('reaching the end of a chapter scrobbles it exactly once, with '
        'kind: manga', (tester) async {
      final longText = List.generate(
        120,
        (i) => 'Paragraph number $i with enough words to take real space.',
      ).join('</p><p>');
      ani.register(_FakeReadingProvider('ani:n', {'u1': longText}));
      final fake = _FakeTracker();
      sl.registerSingleton<TrackerHub>(TrackerHub([fake]));

      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderScreen(
            sourceId: 'ani:n',
            showId: 'b1',
            showTitle: 'Book',
            cover: null,
            chapters: [chapter('c1', 'u1', number: 3)],
            startIndex: 0,
            malId: 777,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll body is a lazy sliver HTML view inside a CustomScrollView now.
      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      final controller = scrollView.controller!;

      await tester.runAsync(() async {
        controller.jumpTo(controller.position.maxScrollExtent);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(fake.scrobbleCalls, 1);
      expect(fake.lastScrobbleKind, MediaKind.manga);
      expect(fake.lastScrobbleEpisode, 3);
      expect(fake.lastScrobbleMalId, 777);
      // The novel reader must flag this as a novel — AniList resolves it
      // under manga+format:NOVEL, not the top plain-manga title match.
      expect(fake.lastScrobbleNovel, isTrue);

      // Dispose flushes progress again for the same (still-finished)
      // chapter — must not scrobble a second time.
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(fake.scrobbleCalls, 1);
    });

    testWidgets('paged mode renders a PageView (not the scroll view) and '
        'reaching the last page scrobbles exactly once via the same path', (
      tester,
    ) async {
      final longText = List.generate(
        200,
        (i) => 'Paragraph number $i with enough words to take real space.',
      ).join('</p><p>');
      ani.register(_FakeReadingProvider('ani:n', {'u1': longText}));
      final fake = _FakeTracker();
      sl.registerSingleton<TrackerHub>(TrackerHub([fake]));
      await tester.runAsync(() => sl<ReaderPrefs>().setNovelPaginated(true));

      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderScreen(
            sourceId: 'ani:n',
            showId: 'b1',
            showTitle: 'Book',
            cover: null,
            chapters: [chapter('c1', 'u1', number: 4)],
            startIndex: 0,
            malId: 555,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Mode really switched.
      expect(find.byType(PageView), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsNothing);

      final pageView = tester.widget<PageView>(find.byType(PageView));
      final controller = pageView.controller!;
      expect(controller.position.maxScrollExtent, greaterThan(0));

      // Jump to the last page — permille hits 1000, which is ReadStore's
      // finished threshold, so the shared _saveProgress scrobbles once.
      await tester.runAsync(() async {
        controller.jumpTo(controller.position.maxScrollExtent);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(fake.scrobbleCalls, 1);
      expect(fake.lastScrobbleKind, MediaKind.manga);
      expect(fake.lastScrobbleEpisode, 4);
      expect(fake.lastScrobbleMalId, 555);
      expect(fake.lastScrobbleNovel, isTrue);

      // Dispose re-flushes the still-finished chapter — no second scrobble.
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(fake.scrobbleCalls, 1);
    });

    testWidgets('paged mode resumes on the page matching the saved permille', (
      tester,
    ) async {
      final longText = List.generate(
        200,
        (i) => 'Paragraph number $i with enough words to take real space.',
      ).join('</p><p>');
      ani.register(_FakeReadingProvider('ani:n', {'u1': longText}));
      await tester.runAsync(() => sl<ReaderPrefs>().setNovelPaginated(true));
      // Saved at the very end → paged mode must open on the last page.
      await tester.runAsync(
        () => sl<ReadStore>().save('ani:n', 'b1', 'c1', pos: 1000, total: 1000),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderScreen(
            sourceId: 'ani:n',
            showId: 'b1',
            showTitle: 'Book',
            cover: null,
            chapters: [chapter('c1', 'u1')],
            startIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final pageView = tester.widget<PageView>(find.byType(PageView));
      final controller = pageView.controller!;
      expect(controller.position.maxScrollExtent, greaterThan(0));
      // Last page = full permille; the restore jump landed us there.
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, 1.0),
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    });

    testWidgets(
      'a chapter whose text carries a folder passes it to HtmlWidget as '
      "baseUrl, so a relative image src resolves against it — a chapter "
      'with no folder (the live/non-downloaded case) keeps baseUrl null',
      (tester) async {
        // The download → repository plumbing that actually sets
        // ChapterText.folder for a real downloaded chapter is covered
        // end-to-end in test/download/ (real ChapterDownloadStore + real
        // dart:io) — that pipeline doesn't belong in a widget test. This
        // proves the other half: the reader threading whatever folder it's
        // handed straight to HtmlWidget's baseUrl.
        ani.register(
          _FakeReadingProvider(
            'ani:n',
            {'u1': 'chapter one text', 'u2': 'chapter two text'},
            folderByUrl: {'u1': '/fake/dl/book/chapter-1'},
          ),
        );

        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        final downloaded = tester.widget<HtmlWidget>(find.byType(HtmlWidget));
        expect(downloaded.baseUrl, Uri.file('/fake/dl/book/chapter-1/'));

        // chrome → next, onto 'u2' — no folder for that url, so baseUrl
        // must go back to null rather than sticking from the last chapter.
        await tester.tap(find.byType(CustomScrollView));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.byIcon(Icons.skip_next_rounded));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();

        final live = tester.widget<HtmlWidget>(find.byType(HtmlWidget));
        expect(live.baseUrl, isNull);

        await tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox());
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
      },
      // The scroll reader builds its own spans now instead of handing the chapter
      // to HtmlWidget, so a downloaded chapter's images no longer render and
      // there is no baseUrl to thread. That is a real loss traded for
      // sentence-precise highlighting, which HtmlWidget cannot do: it owns the
      // text, so it cannot be handed a decorated copy. Skipped rather than
      // deleted so the gap stays visible in the suite output.
      skip: true, // see the note above: HtmlWidget no longer renders the chapter
    );

    // A chapter shaped like a real one: prose with a donation plea wedged
    // between two paragraphs of it. `u3` is registered per test because these
    // two need the cleanup rules in a known state.
    const adChapter =
        '<p>The first paragraph of the story.</p>'
        '<p>Please support me on Patreon!</p>'
        '<p>The second paragraph of the story.</p>';

    Widget adHarness() => MaterialApp(
      home: NovelReaderScreen(
        sourceId: 'ani:n',
        showId: 'b1',
        showTitle: 'Book',
        cover: null,
        chapters: [chapter('c1', 'u1'), chapter('c2', 'u2'), chapter('c3', 'u3')],
        startIndex: 2,
      ),
    );

    void registerAdChapter() {
      ani.register(
        _FakeReadingProvider('ani:n', {
          'u1': 'chapter one text',
          'u2': 'chapter two text',
          'u3': adChapter,
        }),
      );
    }

    testWidgets('strips an injected ad line from the chapter by default', (
      tester,
    ) async {
      registerAdChapter();
      await tester.pumpWidget(adHarness());
      await tester.pumpAndSettle();

      // The rule set is on without anyone asking for it, and the ad line is
      // simply not on the page: not greyed, not collapsed, gone.
      expect(
        find.textContaining('support me on Patreon', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('first paragraph of the story', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('second paragraph of the story', findRichText: true),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    });

    testWidgets(
      'a sentence hidden in one chapter is already gone from the next',
      (tester) async {
        registerAdChapter();
        // Hidden before this reader exists, which is the "everywhere" claim: the
        // rule is global, so a chapter opened afterwards renders clean without
        // the reader having been open when it was hidden.
        await tester.runAsync(() async {
          await sl<ReaderPrefs>()
              .hideTextEverywhere('Please support me on Patreon!');
        });

        await tester.pumpWidget(adHarness());
        await tester.pumpAndSettle();

        expect(
          find.textContaining('support me on Patreon', findRichText: true),
          findsNothing,
        );
        expect(
          find.textContaining('first paragraph of the story', findRichText: true),
          findsOneWidget,
        );
        expect(sl<ReaderPrefs>().textFilterRules, hasLength(1));

        await tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox());
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
      },
    );

    testWidgets('long press names the sentence and offers hide or cancel', (
      tester,
    ) async {
      registerAdChapter();
      // The built-ins are off for this one, so the long press is aimed at text
      // the built-in rules would otherwise have removed before it could be
      // pressed — which is also the case they cannot cover.
      await tester.runAsync(() async {
        await sl<ReaderPrefs>().setTextFiltersEnabled(false);
      });

      await tester.pumpWidget(adHarness());
      await tester.pumpAndSettle();
      expect(
        find.textContaining('support me on Patreon', findRichText: true),
        findsOneWidget,
      );

      await tester.longPress(
        find.textContaining('support me on Patreon', findRichText: true),
      );
      await tester.pumpAndSettle();

      // The dialog quotes the sentence — the page's own words, not the
      // narrator's normalised copy — and offers exactly two ways out.
      expect(
        find.text('Please support me on Patreon!'),
        findsWidgets,
      );
      expect(find.text('Hide'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.textContaining('every novel', findRichText: true),
          findsOneWidget);

      // Cancel changes nothing: no rule, no rebuild, sentence still there.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sl<ReaderPrefs>().textFilterRules, isEmpty);
      expect(
        find.textContaining('support me on Patreon', findRichText: true),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    });

    // The last step of the flow — Hide writes the rule, and the open chapter is
    // re-cleaned from it — is not asserted through the dialog. The write is real
    // Hive I/O started from inside the test's faked clock, and making it
    // observable took a runAsync/pump loop that hung the test rather than
    // testing the reader. It is covered instead by the two halves it is made
    // of: `hideTextEverywhere` persisting the rule, and the reader rendering a
    // chapter clean against a rule saved before it was ever opened.
    // What follows covers the part the tests above cannot: the *geometry*.
    // Those press a widget the finder already located, so the hit test is
    // handed the one point that is known to be right. Long-press hides nothing
    // if the coordinate maths is wrong — and that maths depends on the mode
    // (scrolling measures blocks; paginated runs a TextPainter over the page),
    // on the safe-area inset, and on the font and margins actually laid out.
    group('the Listen action', () {
      Widget playerHarness({required bool openPlayer}) =>
          MaterialApp(
            home: NovelReaderScreen(
              sourceId: 'ani:n',
              showId: 'b1',
              showTitle: 'Book',
              cover: null,
              chapters: [chapter('c1', 'u1'), chapter('c2', 'u2')],
              startIndex: 0,
              openPlayerOnLoad: openPlayer,
            ),
          );

      void registerHtmlChapter() {
        ani.register(
          _RawHtmlReadingProvider('ani:n', {
            'u1': '<p>Alpha sentence one. Alpha sentence two.</p>',
            'u2': 'second chapter',
          }),
        );
      }

      testWidgets('it opens the player once the chapter is loaded', (
        tester,
      ) async {
        final tts = _StubTtsCubit();
        sl.registerSingleton<TtsCubit>(tts);
        addTearDown(tts.close);
        registerHtmlChapter();

        await tester.pumpWidget(playerHarness(openPlayer: true));
        await settleBriefly(tester);

        // Segmenting first is the whole point: a player opened before the
        // chapter arrived would be a transcript of nothing, and this stub would
        // have adopted nothing to play.
        expect(tts.adopted, isNotEmpty);
        expect(find.byType(TtsAudiobookSheet), findsOneWidget);
        // ...and it starts reading, which is what the action asked for.
        expect(tts.playCalls, 1);
        await disposeReader(tester);
      });

      testWidgets('an ordinary open leaves the player alone', (tester) async {
        final tts = _StubTtsCubit();
        sl.registerSingleton<TtsCubit>(tts);
        addTearDown(tts.close);
        registerHtmlChapter();

        await tester.pumpWidget(playerHarness(openPlayer: false));
        await settleBriefly(tester);

        expect(find.byType(TtsAudiobookSheet), findsNothing);
        expect(tts.playCalls, 0);
        await disposeReader(tester);
      });

      testWidgets('the reader is still behind the player', (tester) async {
        final tts = _StubTtsCubit();
        sl.registerSingleton<TtsCubit>(tts);
        addTearDown(tts.close);
        registerHtmlChapter();

        await tester.pumpWidget(playerHarness(openPlayer: true));
        await settleBriefly(tester);

        // The player is a view over the reader, not a replacement for it:
        // closing it must land back on the chapter, still loaded.
        await tester.tap(find.byKey(const ValueKey('audiobook-sheet-close')));
        await settleBriefly(tester);

        expect(find.byType(TtsAudiobookSheet), findsNothing);
        expect(find.byType(NovelReaderScreen), findsOneWidget);
        expect(find.textContaining('Alpha sentence one', findRichText: true),
            findsWidgets);
        await disposeReader(tester);
      });
    });

    group('tapping the page', () {
      /// Where the reader's scroll offset is right now, without reaching into
      /// private state.
      double scrollOffset(WidgetTester tester) =>
          tester.state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels;

      /// 1.0 while the controls are showing, 0.0 while they are not. The bars
      /// are always in the tree so they have something to fade, so presence
      /// proves nothing.
      double chromeOpacity(WidgetTester tester) => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.byIcon(Icons.arrow_back_rounded),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity;

      void registerLongChapter() {
        ani.register(
          _RawHtmlReadingProvider('ani:n', {
            'u1': '<p>${'A sentence of prose to read. ' * 40}</p>',
            'u2': 'second chapter',
          }),
        );
      }

      testWidgets('a tap does not move the reading position', (tester) async {
        registerLongChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        final size = tester.view.physicalSize / tester.view.devicePixelRatio;
        final before = scrollOffset(tester);

        // The lower part of the page is where this went wrong: it used to be
        // the scrollDown zone, so the tap scrolled and the controls stayed
        // hidden — the reader was trying to get the chrome back.
        await tester.tapAt(Offset(size.width / 2, size.height * 0.9));
        await settleBriefly(tester);

        expect(scrollOffset(tester), before);
        expect(chromeOpacity(tester), 1.0);
        await disposeReader(tester);
      });

      testWidgets('a tap on the top of the page does not scroll either', (
        tester,
      ) async {
        registerLongChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        final size = tester.view.physicalSize / tester.view.devicePixelRatio;
        final before = scrollOffset(tester);

        await tester.tapAt(Offset(size.width / 2, size.height * 0.08));
        await settleBriefly(tester);

        expect(scrollOffset(tester), before);
        await disposeReader(tester);
      });

      testWidgets('a tap brings the controls back and puts them away again', (
        tester,
      ) async {
        registerLongChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();
        final size = tester.view.physicalSize / tester.view.devicePixelRatio;

        expect(chromeOpacity(tester), 0.0);
        await tester.tapAt(Offset(size.width / 2, size.height * 0.5));
        await settleBriefly(tester);
        expect(chromeOpacity(tester), 1.0);

        await tester.tapAt(Offset(size.width / 2, size.height * 0.5));
        await settleBriefly(tester);
        expect(chromeOpacity(tester), 0.0);
        await disposeReader(tester);
      });

      testWidgets('a layout the reader configured is still theirs', (
        tester,
      ) async {
        registerLongChapter();
        // Asked for explicitly: this is a saved layout, and a saved layout is
        // the reader's own choice, however it was set.
        await tester.runAsync(() async {
          await sl<ReaderPrefs>().setTapZones(
            TapZoneLayout.defaultFor(
              TapZoneLayout.webtoon,
            ).withZoneAction(2, ReaderAction.scrollDown),
          );
        });
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        final size = tester.view.physicalSize / tester.view.devicePixelRatio;
        await tester.tapAt(Offset(size.width / 2, size.height * 0.9));
        await settleBriefly(tester);

        // Configured to scroll down, so it scrolls down and stays as it was.
        expect(scrollOffset(tester), greaterThan(0));
        await disposeReader(tester);
      });

      testWidgets('paged mode still turns the page', (tester) async {
        registerLongChapter();
        await tester.runAsync(() async {
          await sl<ReaderPrefs>().setNovelPaginated(true);
        });
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        // Left and right turning the page is the long-standing convention
        // there, and it is not what moves a reader down a chapter. Untouched.
        final size = tester.view.physicalSize / tester.view.devicePixelRatio;
        await tester.tapAt(Offset(size.width * 0.85, size.height / 2));
        await settleBriefly(tester);
        await tester.pump(const Duration(milliseconds: 400));

        // The page turned, so the controls are showing: the middle zone is not
        // what fired, and the turn did not stop being a turn.
        expect(chromeOpacity(tester), 0.0);
        await disposeReader(tester);
      });
    });

    group('long press, measured on screen', () {
      // Prose, a heading, more prose: prose resolves to a sentence, the heading
      // falls back to the whole block, and the gaps between blocks resolve to
      // nothing. Long enough that the target paragraphs sit clear of the top
      // bar, which is stacked over the body and would swallow the press.
      const html =
          '<p>Alpha sentence one. Alpha sentence two.</p>'
          '<p>Beta sentence one. Beta sentence two.</p>'
          '<h3>AN: A heading read aloud skips.</h3>'
          '<p>Gamma sentence one. Gamma sentence two.</p>';

      void registerHtmlChapter() {
        ani.register(
          _RawHtmlReadingProvider('ani:n', {'u1': html, 'u2': html}),
        );
      }

      /// The built-in rules would strip the heading before it could be pressed,
      /// so every test here starts with filtering off — which is also the state
      /// a reader is in when they have chosen to manage their own rules.
      Future<void> filtersOff(WidgetTester tester) async {
        await tester.runAsync(() async {
          await sl<ReaderPrefs>().setTextFiltersEnabled(false);
        });
      }

      Future<void> prefs(
        WidgetTester tester,
        Future<void> Function() apply,
      ) async {
        await tester.runAsync(apply);
      }

      /// A point inside the block containing [needle]. Horizontal, because the
      /// paragraph is a single line and the sentence under test is decided by
      /// how far across it the finger lands.
      Offset pressInside(WidgetTester tester, String needle) {
        final box = tester.renderObject<RenderBox>(
          find.textContaining(needle, findRichText: true).first,
        );
        return box.localToGlobal(Offset.zero) + const Offset(30, 12);
      }

      Rect boxOf(WidgetTester tester, String needle) {
        final box = tester.renderObject<RenderBox>(
          find.textContaining(needle, findRichText: true).first,
        );
        return box.localToGlobal(Offset.zero) & box.size;
      }


      Future<void> expectNoHideDialog(WidgetTester tester) async {
        await settleBriefly(tester);
        expect(find.text('Hide'), findsNothing);
      }

      testWidgets('scrolling mode resolves the sentence under the finger', (
        tester,
      ) async {
        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        await tester.longPressAt(pressInside(tester, 'Beta sentence one'));
        await expectHideDialog(tester, 'Beta sentence one.');
        await disposeReader(tester);
      });

      testWidgets('a safe-area inset does not shift the lookup', (
        tester,
      ) async {
        // The whole bug: the inset used to be added where it did not belong, so
        // the lookup landed a notch low and resolved to the wrong line - or,
        // at the very top of a chapter, to nothing at all.
        tester.view.devicePixelRatio = 1.0;
        tester.view.padding = const FakeViewPadding(top: 48, bottom: 24);
        addTearDown(tester.view.reset);

        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        await tester.longPressAt(pressInside(tester, 'Beta sentence one'));
        await expectHideDialog(tester, 'Beta sentence one.');
        await disposeReader(tester);
      });

      testWidgets('a larger font and wider margins still resolve', (
        tester,
      ) async {
        await prefs(tester, () async {
          await sl<ReaderPrefs>().setFontSize(30);
          await sl<ReaderPrefs>().setMarginWidth(40);
        });
        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        await tester.longPressAt(pressInside(tester, 'Beta sentence one'));
        await expectHideDialog(tester, 'Beta sentence one.');
        await disposeReader(tester);
      });

      testWidgets('the paginated path resolves the sentence under the finger', (
        tester,
      ) async {
        // A different branch entirely: no block offsets, a TextPainter over the
        // page, and one more inset to remove (the page's own top padding).
        await prefs(tester, () => sl<ReaderPrefs>().setNovelPaginated(true));
        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        // A page is one RichText for the whole chapter, so there is no
        // per-paragraph box to aim at the way there is when scrolling. The page's
        // own text area is the anchor, and the press walks down through it.
        final page = boxOf(tester, 'Alpha sentence one');

        await tester.longPressAt(Offset(page.left + 30, page.top + 8));
        await settleBriefly(tester);
        expect(find.text('Hide'), findsOneWidget);
        expect(dialogQuote(tester), 'Alpha sentence one.');
        await tester.tap(find.text('Cancel'));
        await settleBriefly(tester);

        // Further down the page is a different sentence. Without this the first
        // assertion would pass even if every press resolved to the top.
        await tester.longPressAt(Offset(page.left + 30, page.top + 70));
        await settleBriefly(tester);
        expect(find.text('Hide'), findsOneWidget);
        expect(dialogQuote(tester), isNot('Alpha sentence one.'));
        await disposeReader(tester);
      });

      testWidgets('the paginated path follows the text down past an inset', (
        tester,
      ) async {
        // The page's text starts below both the inset and its own padding, and
        // the lookup has to take both out. Aimed by the page's own box, so this
        // fails if the inset is counted twice or not at all.
        tester.view.devicePixelRatio = 1.0;
        tester.view.padding = const FakeViewPadding(top: 48, bottom: 24);
        addTearDown(tester.view.reset);

        await prefs(tester, () => sl<ReaderPrefs>().setNovelPaginated(true));
        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        final page = boxOf(tester, 'Alpha sentence one');
        expect(page.top, greaterThan(48));

        await tester.longPressAt(Offset(page.left + 30, page.top + 8));
        await settleBriefly(tester);
        expect(find.text('Hide'), findsOneWidget);
        expect(dialogQuote(tester), 'Alpha sentence one.');
        await disposeReader(tester);
      });

testWidgets('empty space past the end of the chapter offers nothing', (
        tester,
      ) async {
        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        // A chapter this short leaves most of the page empty. A press out in it
        // is not on a sentence, so there must be no dialog — and no crash
        // hunting for one.
        final last = boxOf(tester, 'Gamma sentence one');
        expect(last.bottom, lessThan(500));
        await tester.longPressAt(Offset(last.left + 30, last.bottom + 200));
        await expectNoHideDialog(tester);
        await disposeReader(tester);
      });

      testWidgets('a press between two blocks stays with the text around it', (
        tester,
      ) async {
        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        // Whitespace between paragraphs is not a dead zone: a reader aiming
        // between two lines means one of them, so the lookup snaps to the
        // nearest sentence rather than doing nothing. What matters is that it
        // stays local — a press in the seam must not surface a sentence from
        // some other paragraph, which is exactly what a wrong coordinate
        // conversion would do.
        final alpha = boxOf(tester, 'Alpha sentence one');
        final beta = boxOf(tester, 'Beta sentence one');
        await tester.longPressAt(
          Offset(alpha.left + 30, (alpha.bottom + beta.top) / 2),
        );
        await settleBriefly(tester);
        expect(find.text('Hide'), findsOneWidget);
          final quoted = dialogQuote(tester);
        expect(
          quoted.startsWith('Alpha sentence') ||
              quoted.startsWith('Beta sentence'),
          isTrue,
          reason: 'a press in the seam quoted a distant sentence: "$quoted"',
        );
        await disposeReader(tester);
      });

      testWidgets('a heading still falls back to the whole block', (
        tester,
      ) async {
        // Read-aloud skips headings, so there is no sentence list over this
        // line; the fallback to the whole block is what makes it hideable at
        // all. Geometry work must not cost that.
        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        await tester.longPressAt(pressInside(tester, 'A heading read aloud'));
        await expectHideDialog(tester, 'AN: A heading read aloud skips.');
        await disposeReader(tester);
      });

      testWidgets('holding and then moving scrolls instead of hiding', (
        tester,
      ) async {
        await filtersOff(tester);
        registerHtmlChapter();
        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        // Scrolling is what a finger on this page is for, and the Hide dialog is
        // worse than a mis-aimed scroll. The drag has to win the gesture arena
        // before the long-press deadline, so this moves well inside it.
        final at = pressInside(tester, 'Beta sentence one');
        final gesture = await tester.startGesture(at);
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 40));
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 40));
        await gesture.up();
        await expectNoHideDialog(tester);
        await disposeReader(tester);
      });
    });
  });
}
