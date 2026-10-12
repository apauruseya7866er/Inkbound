import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart' show ProviderType;
import 'package:watch_app/core/reading/novel_migrator.dart';

/// The parts of migration that can be tested without Hive, a device or a
/// network: how candidates are ranked, and how a chapter number is resolved
/// against the destination's own chapter list.
///
/// Both exist because there is no correct-by-construction answer available. Two
/// sites carrying the same title are two different books, and two sites number
/// their chapters differently, so everything here is about ranking and narrowing
/// guesses rather than about computing a truth.

MediaItem _item({
  required String id,
  required String title,
  String sourceId = 'lnr:novelfire',
}) => MediaItem(
  id: id,
  title: title,
  url: '/novel/$id',
  type: ProviderType.novel,
  sourceId: sourceId,
);

void main() {
  group('candidate ranking', () {
    test('an exact title match outranks a partial one', () {
      final exact = NovelMigrator.score(
        'The Beginning After The End',
        _item(id: '1', title: 'The Beginning After The End'),
      );
      final partial = NovelMigrator.score(
        'The Beginning After The End',
        _item(id: '2', title: 'The Beginning After The End (Unedited)'),
      );
      expect(exact, greaterThan(partial));
    });

    test('punctuation and case differences still count as an exact match', () {
      // Novel sites are wildly inconsistent about punctuation and casing. If
      // these did not tie, every reader with a hyphen in their title would be
      // shown the wrong book first.
      final a = NovelMigrator.score(
        'Re:Zero - Starting Life',
        _item(id: '1', title: 'Re Zero Starting Life'),
      );
      final b = NovelMigrator.score(
        'Re:Zero - Starting Life',
        _item(id: '2', title: 'Re:Zero - Starting Life'),
      );
      expect(a, b);
      expect(a, 100);
    });

    test('a source that has never heard of the book ranks below one that has', () {
      final hit = NovelMigrator.score(
        'Solo Leveling',
        _item(id: '1', title: 'Solo Leveling'),
      );
      final miss = NovelMigrator.score(
        'Solo Leveling',
        _item(id: '2', title: 'Unrelated Book About Gardening'),
      );
      expect(hit, greaterThan(miss));
    });

    test('word overlap beats a pure substring hit', () {
      final words = NovelMigrator.score(
        'reincarnated',
        _item(id: '1', title: 'Reincarnated: A Sword For Hire'),
      );
      final nothing = NovelMigrator.score(
        'reincarnated',
        _item(id: '2', title: 'Something About Antelopes'),
      );
      expect(words, greaterThan(nothing));
    });
  });

  group('chapter resolution', () {
    final chapters = [
      (id: '/c/1', title: 'Chapter 1'),
      (id: '/c/2', title: 'Chapter 2'),
      (id: '/c/3', title: 'Chapter 3'),
    ];

    test('an exact number resolves to that chapter', () {
      expect(NovelMigrator.resolveChapter(chapters, 2), '/c/2');
    });

    test('a number the destination does not have lands BELOW, never above', () {
      // Overshooting puts the reader in a chapter they have not read, which is
      // worse than asking them to re-read one: they cannot tell it happened.
      expect(NovelMigrator.resolveChapter(chapters, 10), '/c/3');
    });

    test('no chapters at all carries nothing rather than guessing', () {
      expect(NovelMigrator.resolveChapter(const [], 5), isNull);
    });

    test('bare numbers and "Chapter N" titles are both understood', () {
      final mixed = [
        (id: '/bare/1', title: '1. The Fire'),
        (id: '/word/2', title: 'Chapter 2 The Ash'),
      ];
      expect(NovelMigrator.resolveChapter(mixed, 1), '/bare/1');
      expect(NovelMigrator.resolveChapter(mixed, 2), '/word/2');
    });

    test('volume/chapter titles resolve on the chapter half', () {
      // A very common shape. Reading "Vol 3 Ch 12" as 3 would silently rewind
      // the reader by nine chapters.
      final vol = [
        (id: '/v/1', title: 'Volume 1 Chapter 1'),
        (id: '/v/2', title: 'Volume 1 Chapter 2'),
      ];
      expect(NovelMigrator.resolveChapter(vol, 2), '/v/2');
    });
  });

  group('leading number parsing', () {
    test('handles the shapes novel sites actually use', () {
      expect(NovelMigrator.leadingNumber('Chapter 12'), 12);
      expect(NovelMigrator.leadingNumber('Ch. 7 - A New Day'), 7);
      expect(NovelMigrator.leadingNumber('12'), 12);
      expect(NovelMigrator.leadingNumber('12. The Title'), 12);
    });

    test('a title with no number at all reports none', () {
      expect(NovelMigrator.leadingNumber('Prologue'), -1);
      expect(NovelMigrator.leadingNumber(''), -1);
    });

    test('does not read a year inside a title as a chapter number', () {
      // "In 2019 The Author..." would otherwise resolve to chapter 2019 and skip
      // the whole book.
      expect(NovelMigrator.leadingNumber('In 2019 The Author Retired'), -1);
    });
  });
}