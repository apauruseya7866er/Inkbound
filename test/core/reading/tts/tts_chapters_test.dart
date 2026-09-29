import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tts/tts_chapters.dart';

/// Scriptable chapter source, so auto-advance and prefetch can be tested
/// without a plugin, a network, or a real book.
class FakeChapterSource implements TtsChapterSource {
  FakeChapterSource({required this.count});

  int count;
  final Map<int, String> texts = {};
  final Map<int, String> titles = {};
  int textCalls = 0;
  final Set<int> failFor = {};
  final Set<int> emptyFor = {};
  Duration delay = Duration.zero;

  @override
  Future<int> chapterCount() async => count;

  @override
  Future<String> chapterTitle(int index) async =>
      titles[index] ?? 'Chapter ${index + 1}';

  @override
  String chapterId(int index) => 'chapter-url-$index';

  @override
  Future<String> chapterText(int index) async {
    textCalls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (failFor.contains(index)) throw Exception('network died');
    if (emptyFor.contains(index)) return '';
    return texts[index] ?? '<p>Body of chapter $index. With a sentence.</p>';
  }
}

TtsAutoAdvance build(FakeChapterSource source, {int index = 0}) =>
    TtsAutoAdvance(source: source, index: index);

void main() {
  group('prefetch', () {
    test('fetches the next chapter', () async {
      final source = FakeChapterSource(count: 3);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      expect(source.textCalls, 1);
      expect(adv.hasPrefetched, isTrue);
    });

    test('does not fetch twice for the same chapter', () async {
      final source = FakeChapterSource(count: 5);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      await adv.prefetch();
      await adv.prefetch();
      // A repeated prefetch must not re-hit the network: the reader calls this
      // on every play and every sentence start.
      expect(source.textCalls, 1);
    });

    test('does nothing at the end of the book', () async {
      final source = FakeChapterSource(count: 1);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      expect(source.textCalls, 0);
      expect(adv.hasPrefetched, isFalse);
    });

    test('the last chapter prefetches nothing', () async {
      final source = FakeChapterSource(count: 3);
      final adv = build(source, index: 2);
      await adv.ensureCount();
      await adv.prefetch();
      expect(source.textCalls, 0);
    });

    test('a failed fetch does not throw', () async {
      final source = FakeChapterSource(count: 3)..failFor.add(1);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      expect(adv.hasPrefetched, isFalse);
    });

    test('an empty chapter is not cached', () async {
      final source = FakeChapterSource(count: 3)..emptyFor.add(1);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      expect(adv.hasPrefetched, isFalse);
    });

    test('a chapter count failure leaves advance disabled', () async {
      final source = _CountFails();
      final adv = TtsAutoAdvance(source: source, index: 0);
      await adv.ensureCount();
      expect(await adv.advance(), isNull);
    });
  });

  group('advance', () {
    test('uses the prefetch instead of re-fetching', () async {
      final source = FakeChapterSource(count: 4);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      final target = await adv.advance();

      expect(target, isNotNull);
      expect(target!.index, 1);
      // Prefetched, so advancing cost no extra request.
      expect(source.textCalls, 1);
    });

    test('advances without a prefetch', () async {
      final source = FakeChapterSource(count: 4);
      final adv = build(source);
      await adv.ensureCount();

      final target = await adv.advance();
      expect(target?.index, 1);
      expect(source.textCalls, 1);
    });

    test('the target carries parsed content and a title', () async {
      final source = FakeChapterSource(count: 3)
        ..texts[1] = '<p>One here. Two here.</p>'
        ..titles[1] = 'Chapter Two';
      final adv = build(source);
      await adv.ensureCount();

      final target = await adv.advance();
      expect(target!.title, 'Chapter Two');
      expect(target.content.totalSentences, 2);
      expect(target.content.sentences.first.text, 'One here.');
    });

    test('a title failure falls back to a generic one', () async {
      final source = _TitleFails();
      final adv = TtsAutoAdvance(source: source, index: 0);
      await adv.ensureCount();
      final target = await adv.advance();
      expect(target?.title, 'Chapter 2');
    });

    test('returns null at the end of the book', () async {
      final source = FakeChapterSource(count: 2);
      final adv = build(source, index: 1);
      await adv.ensureCount();
      expect(await adv.advance(), isNull);
    });

    test('returns null when the next chapter cannot be fetched', () async {
      final source = FakeChapterSource(count: 3)..failFor.add(1);
      final adv = build(source);
      await adv.ensureCount();
      expect(await adv.advance(), isNull);
    });

    test('returns null when the next chapter is empty', () async {
      final source = FakeChapterSource(count: 3)..emptyFor.add(1);
      final adv = build(source);
      await adv.ensureCount();
      expect(await adv.advance(), isNull);
    });

    test('the cache is consumed, not left behind', () async {
      final source = FakeChapterSource(count: 5);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      await adv.advance();
      // The prefetched chapter has been spoken; holding it would waste memory
      // on a long book for no benefit.
      expect(adv.hasPrefetched, isFalse);
    });

    test('index moves with each advance', () async {
      final source = FakeChapterSource(count: 5);
      final adv = build(source);
      await adv.ensureCount();

      expect((await adv.advance())?.index, 1);
      expect((await adv.advance())?.index, 2);
      expect(adv.index, 2);
    });

    test('a slow prefetch does not overwrite a newer one', () async {
      final source = FakeChapterSource(count: 5)..delay = const Duration(milliseconds: 40);
      final adv = build(source);
      await adv.ensureCount();

      // Start prefetching chapter 1, then move on so chapter 2 is the one that
      // matters. The late chapter-1 result must not become the cache entry.
      final slow = adv.prefetch();
      adv.index = 1;
      await slow;

      final target = await adv.advance();
      expect(target?.index, 2);
    });
  });

  group('chapter identity', () {
    test('the target carries the id the source reports', () async {
      final source = FakeChapterSource(count: 3);
      final adv = build(source);
      await adv.ensureCount();
      final target = await adv.advance();
      expect(target?.chapterId, 'chapter-url-1');
    });

    test('ids do not accumulate across advances', () async {
      final source = FakeChapterSource(count: 5);
      final adv = build(source);
      await adv.ensureCount();

      final first = await adv.advance();
      final second = await adv.advance();
      final third = await adv.advance();

      // Regression: ids used to be built by appending to the previous one
      // ('c1#1#2#3'), which grows without bound and names a chapter the app
      // cannot reopen — so the saved resume point became unreachable and the
      // resume offer silently never appeared.
      expect(first?.chapterId, 'chapter-url-1');
      expect(second?.chapterId, 'chapter-url-2');
      expect(third?.chapterId, 'chapter-url-3');
      for (final t in [first, second, third]) {
        expect(t!.chapterId, isNot(contains('#')));
      }
    });
  });

  group('prefetch before the count is known', () {
    test('a prefetch asked for too early is not lost', () async {
      final source = FakeChapterSource(count: 3);
      final adv = build(source);

      // Prefetch first, exactly as attaching the source does: the chapter count
      // bounds nextIndex, so without this the very first chapter of a session
      // would be the one with no prefetched successor.
      await adv.prefetch();
      expect(source.textCalls, 0);

      await adv.ensureCount();
      expect(source.textCalls, 1, reason: 'the pending prefetch was dropped');
      expect(adv.hasPrefetched, isTrue);
    });

    test('a prefetch at the end of the book is still a no-op', () async {
      final source = FakeChapterSource(count: 1);
      final adv = build(source);
      await adv.prefetch();
      await adv.ensureCount();
      expect(source.textCalls, 0);
      expect(adv.hasPrefetched, isFalse);
    });

    test('a failed count leaves prefetch disabled', () async {
      final adv = TtsAutoAdvance(source: _CountFails(), index: 0);
      await adv.ensureCount();
      expect(adv.hasPrefetched, isFalse);
    });
  });

  group('invalidate', () {
    test('drops the cached chapter', () async {
      final source = FakeChapterSource(count: 4);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      expect(adv.hasPrefetched, isTrue);
      adv.invalidate();
      expect(adv.hasPrefetched, isFalse);
    });

    test('a later advance re-fetches instead of using the stale entry', () async {
      final source = FakeChapterSource(count: 4);
      final adv = build(source);
      await adv.ensureCount();

      await adv.prefetch();
      adv.invalidate();
      final target = await adv.advance();
      expect(source.textCalls, 2);
      expect(target?.index, 1);
    });
  });
}

class _CountFails implements TtsChapterSource {
  @override
  String chapterId(int index) => 'url-$index';
  @override
  Future<int> chapterCount() async => throw Exception('no list');
  @override
  Future<String> chapterTitle(int index) async => 'x';
  @override
  Future<String> chapterText(int index) async => throw Exception('no list');
}

class _TitleFails implements TtsChapterSource {
  @override
  String chapterId(int index) => 'url-$index';
  @override
  Future<int> chapterCount() async => 3;
  @override
  Future<String> chapterTitle(int index) async => throw Exception('no title');
  @override
  Future<String> chapterText(int index) async =>
      '<p>Body here. More body.</p>';
}


