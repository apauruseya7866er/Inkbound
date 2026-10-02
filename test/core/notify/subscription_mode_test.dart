import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/notify/subscription_store.dart';

Subscription sub({ContentMode mode = ContentMode.novel}) => Subscription(
  sourceId: 'src',
  url: 'https://x/show',
  title: 'Show',
  lastCount: 12,
  mode: mode,
);

void main() {
  group('Subscription mode', () {
    test('every stored mode decodes instead of throwing', () {
      // A box still full of pre-fork `anime`/`manga` rows keeps decoding
      // rather than blowing up — but it decodes as NOVEL, because that is the
      // only mode this build has. This matters for the alert wording, not just
      // for not crashing: a pre-fork row (Streaming was the old default) used
      // to come back with isReading == false, so the chapter sweep announced
      // "Episode" for a novel chapter. Collapsing on the MATCH (not on
      // `orElse`, which only fires for a name no longer in the enum) is what
      // fixes that.
      for (final m in ContentMode.values) {
        final decoded = Subscription.fromMap(sub(mode: m).toMap()).mode;
        expect(decoded, ContentMode.novel, reason: 'stored mode ${m.name}');
      }
      // And the novel row itself still round-trips exactly.
      final novel = sub(mode: ContentMode.novel).toMap();
      expect(Subscription.fromMap(novel).mode, ContentMode.novel);
      expect(Subscription.fromMap(novel).isReading, isTrue);
    });

    test('a subscription saved before modes existed reads as novel', () {
      // Anything already subscribed keeps working, and now says "chapter"
      // rather than loading as a null mode and blowing up — or, as before the
      // fork, announcing "episode" for a row this build can only check as a
      // novel.
      final old = sub().toMap()..remove('mode');
      expect(Subscription.fromMap(old).mode, ContentMode.novel);
      expect(Subscription.fromMap(old).isReading, isTrue);
    });

    test('an unknown mode falls back instead of throwing', () {
      // What a pre-fork row with NO recognisable mode name decodes to: the
      // one mode this build has, so it is served by the novel chapter
      // checker rather than dropped.
      final j = sub().toMap()..['mode'] = 'audiobook';
      expect(Subscription.fromMap(j).mode, ContentMode.novel);
    });

    test('reading modes pick the chapter wording', () {
      expect(sub(mode: ContentMode.manga).unit, 'Chapter');
      expect(sub(mode: ContentMode.novel).unit, 'Chapter');
      expect(sub(mode: ContentMode.anime).unit, 'Episode');
      expect(sub(mode: ContentMode.manga).isReading, isTrue);
    });

    test('copyWith keeps the mode when only the count moves', () {
      // The checker calls this after every sweep; losing the mode there would
      // silently turn chapter alerts back into episode alerts.
      final s = sub(mode: ContentMode.novel).copyWith(lastCount: 40);
      expect(s.mode, ContentMode.novel);
      expect(s.lastCount, 40);
    });
  });
}
