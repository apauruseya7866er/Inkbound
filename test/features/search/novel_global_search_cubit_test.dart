import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/features/search/novel_global_search_cubit.dart';

/// Records every search it was asked for, answers per source, and can be made
/// slow or broken for one source without touching the others - which is the
/// whole point of the screen, and so the whole point of these tests.
class _FakeRepo implements CatalogueRepository {
  _FakeRepo(this.loaded);

  /// `{id: name}` for every loaded source, typed by [types].
  final List<({String id, String name})> loaded;
  final Map<String, String> languages = {};
  final Map<String, ProviderType> types = {
    'lnr:n': ProviderType.novel,
    'mihon:m': ProviderType.manga,
    'cs:a': ProviderType.anime,
    'lnr:x': ProviderType.novel,
    'lnr:y': ProviderType.novel,
  };

  /// What each source returns when searched.
  final Map<String, List<MediaItem>> answers = {};

  /// Sources that throw, standing in for a dead or blocked site.
  final Set<String> broken = {};

  /// Sources whose answer arrives only after this many turns.
  final Map<String, int> slowTurns = {};

  final List<String> searched = [];

  /// Peak simultaneous in-flight calls, to prove the concurrency cap.
  int inFlight = 0;
  int peakInFlight = 0;

  @override
  List<({String id, String name})> get loadedSources => loaded;

  @override
  Map<String, String> get sourceLanguages => languages;

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) async {
    final id = sourceId ?? '';
    searched.add(id);
    inFlight++;
    peakInFlight = peakInFlight > inFlight ? peakInFlight : inFlight;
    final delay = slowTurns[id] ?? 0;
    for (var i = 0; i < delay; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    inFlight--;
    if (broken.contains(id)) {
      return (items: const <MediaItem>[], outcome: SourceOutcome.error);
    }
    final List<MediaItem> answer = answers[id] ?? const <MediaItem>[];
    return (items: answer, outcome: SourceOutcome.ok);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePrefs extends SearchSourcePrefs {
  _FakePrefs(this.notSearchable);

  final Set<String> notSearchable;

  @override
  bool isIncluded(String id) => !notSearchable.contains(id);
}

List<MediaItem> items(String source, int n, {String title = 'Novel'}) => [
      for (var i = 0; i < n; i++)
        MediaItem(
          id: '$source/$i',
          title: '$title $i',
          url: '$source/$i',
          type: ProviderType.novel,
          sourceId: source,
        ),
    ];

const _loaded = [
  (id: 'lnr:n', name: 'Novel Site'),
  (id: 'mihon:m', name: 'Manga Site'),
  (id: 'mihon:a', name: 'Manga Site 2'),
  (id: 'lnr:x', name: 'Second Novel'),
];

NovelGlobalSearchCubit _cubitFor(
  _FakeRepo repo, {
  Set<String> excluded = const {},
  bool Function(String)? pinned,
  int maxConcurrent = 5,
}) => NovelGlobalSearchCubit(
  repo: repo,
  prefs: _FakePrefs(excluded),
  languages: repo.languages,
  isPinned: pinned ?? (id) => id == 'lnr:x',
  maxConcurrent: maxConcurrent,
  debounce: Duration.zero,
);

void main() {
  test('only novel sources are searched, whatever Home was showing', () async {
    final repo = _FakeRepo(_loaded);
    for (final id in ['lnr:n', 'lnr:x']) {
      repo.answers[id] = items(id, 1);
    }
    final cubit = _cubitFor(repo);

    await cubit.search('the alpha');

    expect(repo.searched.toSet(), {'lnr:n', 'lnr:x'});
    expect(repo.searched, isNot(contains('mihon:m')));
    expect(repo.searched, isNot(contains('cs:a')));
    await cubit.close();
  });

  test('a source switched off for search is skipped', () async {
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 1);
    final cubit = _cubitFor(repo, excluded: {'lnr:x'});

    await cubit.search('the alpha');

    expect(repo.searched, ['lnr:n']);
    expect(cubit.state.groups.map((g) => g.sourceId), ['lnr:n']);
    await cubit.close();
  });

  test('every source gets its own row, and rows arrive independently', () async {
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 2);
    repo.answers['lnr:x'] = items('lnr:x', 1);
    // The second novel site takes its time, so the fast one must be on screen
    // before it - which is the difference between this and a search that waits
    // for the slowest source.
    repo.slowTurns['lnr:x'] = 6;
    final cubit = _cubitFor(repo);

    // Not awaited before the first result is checked: `search` only completes
    // once every source has, so awaiting it first would assert on the finished
    // state and prove nothing about arriving early.
    final done = cubit.search('the alpha');
    var guard = 0;
    while (!cubit.state.groups.any(
          (g) => g.status == NovelSourceStatus.hits,
        )) {
      await Future<void>.delayed(Duration.zero);
      if (++guard > 200) break;
    }

    expect(
      cubit.state.searching,
      isTrue,
      reason: 'the slow source was still running',
    );
    expect(
      cubit.state.groups.firstWhere((g) => g.sourceId == 'lnr:n').items.length,
      2,
    );
    expect(
      cubit.state.groups.firstWhere((g) => g.sourceId == 'lnr:x').status,
      NovelSourceStatus.loading,
      reason: 'and the slow one is still visibly loading',
    );

    await done;
    expect(cubit.state.searching, isFalse);
    await cubit.close();
  });

  test('one broken source does not suppress the others', () async {
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 2);
    repo.broken.add('lnr:x');
    final cubit = _cubitFor(repo);

    await cubit.search('the alpha');

    final byId = {for (final g in cubit.state.groups) g.sourceId: g};
    expect(byId['lnr:n']!.status, NovelSourceStatus.hits);
    expect(byId['lnr:n']!.items.length, 2);
    expect(byId['lnr:x']!.status, NovelSourceStatus.failed);
    // A failure is a failed row, not a failed search.
    expect(cubit.state.allEmpty, isFalse);
    await cubit.close();
  });

  test('an empty result is its own state, distinct from a failure', () async {
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 1);
    final cubit = _cubitFor(repo);

    await cubit.search('the alpha');

    final byId = {for (final g in cubit.state.groups) g.sourceId: g};
    expect(byId['lnr:x']!.status, NovelSourceStatus.empty);
    expect(byId['lnr:n']!.status, NovelSourceStatus.hits);
    await cubit.close();
  });

  test('the same title from two sources stays two separate results', () async {
    // No cross-source dedupe: these are read from different places and saved to
    // different libraries, and silently picking one would take that choice away.
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 1, title: 'The Alpha');
    repo.answers['lnr:x'] = items('lnr:x', 1, title: 'The Alpha');
    final cubit = _cubitFor(repo);

    await cubit.search('the alpha');

    final alphaRows = cubit.state.groups
        .where((g) => g.items.any((i) => i.title.startsWith('The Alpha')))
        .toList();
    expect(alphaRows.length, 2, reason: 'one row per source, both kept');
    await cubit.close();
  });

  test('each result keeps the source that produced it', () async {
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:x'] = items('lnr:x', 1);
    final cubit = _cubitFor(repo);

    await cubit.search('the alpha');

    final group = cubit.state.groups.firstWhere((g) => g.sourceId == 'lnr:x');
    expect(group.items.single.sourceId, 'lnr:x');
    expect(group.sourceName, 'Second Novel');
    await cubit.close();
  });

  test('a slow answer to an old query is discarded, not painted', () async {
    // The reader typed one title, then another. The first source is still
    // answering when the second search starts; its late answer must not
    // repaint the screen with the previous query's results.
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 1);
    repo.slowTurns['lnr:n'] = 8;
    repo.slowTurns['lnr:x'] = 1;
    final cubit = _cubitFor(repo);

    final Future<void> first = cubit.search('first title');
    await Future<void>.delayed(Duration.zero);
    final Future<void> second = cubit.search('second title');
    await Future.wait<void>([first, second]);

    expect(
      cubit.state.query,
      'second title',
      reason: 'the screen shows the query it is answering',
    );
    await cubit.close();
  });

  test('searching every source stays within the concurrency cap', () async {
    final repo = _FakeRepo([
      (id: 'lnr:a1', name: 'A1'),
      (id: 'lnr:a2', name: 'A2'),
      (id: 'lnr:a3', name: 'A3'),
      (id: 'lnr:a4', name: 'A4'),
      (id: 'lnr:a5', name: 'A5'),
      (id: 'lnr:a6', name: 'A6'),
      (id: 'lnr:a7', name: 'A7'),
    ]);
    for (final id in repo.loaded.map((s) => s.id)) {
      repo.types[id] = ProviderType.novel;
      repo.slowTurns[id] = 2;
      repo.answers[id] = items(id, 1);
    }
    final cubit = _cubitFor(repo, maxConcurrent: 3);

    await cubit.search('the alpha');

    expect(repo.searched.length, 7, reason: 'every source still searched');
    expect(
      repo.peakInFlight,
      lessThanOrEqualTo(3),
      reason: 'a phone radio cannot hold seven site requests open at once',
    );
    await cubit.close();
  });

  test('an empty query clears rather than searching', () async {
    final repo = _FakeRepo(_loaded);
    final cubit = _cubitFor(repo);

    await cubit.search('   ');

    expect(repo.searched, isEmpty);
    expect(cubit.state.groups, isEmpty);
    expect(cubit.state.query, '');
    await cubit.close();
  });

  test('no novel sources at all says so, rather than finding nothing', () async {
    final repo = _FakeRepo([
      (id: 'mihon:m', name: 'Manga Site'),
      (id: 'mihon:a', name: 'Manga Site 2'),
    ]);
    final cubit = _cubitFor(repo);

    await cubit.search('the alpha');

    expect(cubit.state.noSources, isTrue);
    expect(cubit.state.allEmpty, isFalse, reason: 'not the same as no matches');
    await cubit.close();
  });

  test('Pinned narrows to the pinned sources', () async {
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 1);
    repo.answers['lnr:x'] = items('lnr:x', 1);
    final cubit = _cubitFor(repo, pinned: (id) => id == 'lnr:x');

    await cubit.search('the alpha');
    expect(cubit.visibleGroups().length, 2);

    cubit.setPinnedOnly(true);
    expect(
      cubit.visibleGroups().map((g) => g.sourceId),
      ['lnr:x'],
      reason: 'Pinned is only meaningful with real pin state, which it has',
    );
    await cubit.close();
  });

  test('Has results hides the sources that found nothing', () async {
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 1);
    final cubit = _cubitFor(repo);

    await cubit.search('the alpha');
    expect(cubit.visibleGroups().length, 2);

    cubit.setHideEmpty(true);
    expect(
      cubit.visibleGroups().map((g) => g.sourceId),
      ['lnr:n'],
      reason: 'a source with nothing for us is noise once results exist',
    );
    await cubit.close();
  });

  test('Has results does not hide rows that are still loading', () async {
    // Hiding a pending row would make the page look finished before it is.
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:n'] = items('lnr:n', 1);
    repo.slowTurns['lnr:x'] = 8;
    final cubit = _cubitFor(repo);

    cubit.setHideEmpty(true);
    final pending = cubit.search('the alpha');
    await Future<void>.delayed(Duration.zero);

    expect(
      cubit.visibleGroups().length,
      2,
      reason: 'still searching, so every source is still on screen',
    );
    await pending;
    expect(cubit.visibleGroups().length, 1);
    await cubit.close();
  });

  test('typing schedules one search, not one per keystroke', () async {
    final repo = _FakeRepo(_loaded);
    final cubit = NovelGlobalSearchCubit(
      repo: repo,
      prefs: _FakePrefs(const {}),
      isPinned: (_) => false,
      debounce: const Duration(milliseconds: 30),
    );

    cubit.queryChanged('t');
    cubit.queryChanged('th');
    cubit.queryChanged('the alpha');
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(repo.searched.length, 2, reason: 'one search per source, once only');
    expect(cubit.state.query, 'the alpha');
    await cubit.close();
  });

  test('clearing the box cancels a pending search', () async {
    final repo = _FakeRepo(_loaded);
    final cubit = NovelGlobalSearchCubit(
      repo: repo,
      prefs: _FakePrefs(const {}),
      isPinned: (_) => false,
      debounce: const Duration(milliseconds: 30),
    );

    cubit.queryChanged('the alpha');
    cubit.queryChanged('');
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(repo.searched, isEmpty);
    await cubit.close();
  });

  test('the metadata catalogue is not one of the novel sources', () async {
    // Z Mode types as novel while browsing novels, and its display name is
    // whatever catalogue is configured - AniList, MAL, TMDB. It is a list of
    // canonical entries, not a place a novel can be read from, so putting it
    // here meant the one section a reader saw was a catalogue - and none of the
    // sources they could actually open a novel on.
    final repo = _FakeRepo([
      (id: 'zm', name: 'AniList'),
      (id: 'lnr:n', name: 'Novel Site'),
    ]);
    repo.types['zm'] = ProviderType.novel;
    repo.answers['lnr:n'] = items('lnr:n', 1);
    final cubit = _cubitFor(repo);

    await cubit.search('naruto');

    expect(repo.searched, ['lnr:n'], reason: 'only real novel sources');
    expect(
      cubit.state.groups.map((g) => g.sourceName),
      ['Novel Site'],
    );
    await cubit.close();
  });

  test('a source reports its language, so similar names can be told apart', () async {
    final repo = _FakeRepo([
      (id: 'lnr:en', name: 'NovelHub'),
      (id: 'lnr:id', name: 'NovelHub'),
    ]);
    repo.languages['lnr:en'] = 'en';
    repo.languages['lnr:id'] = 'id';
    repo.answers['lnr:en'] = items('lnr:en', 1);
    final cubit = _cubitFor(repo);

    await cubit.search('naruto');

    final byId = {for (final g in cubit.state.groups) g.sourceId: g};
    expect(byId['lnr:en']!.language, 'en');
    expect(byId['lnr:id']!.language, 'id');
    await cubit.close();
  });

  test('a source that declares no language has none, rather than an empty one', () async {
    final repo = _FakeRepo(_loaded);
    repo.answers['lnr:x'] = items('lnr:x', 1);
    final cubit = _cubitFor(repo);

    await cubit.search('the alpha');

    final group = cubit.state.groups.firstWhere((g) => g.sourceId == 'lnr:x');
    expect(group.language, isNull, reason: 'absent, so the line is left out');
    await cubit.close();
  });

  test('none installed and all switched off are told apart', () async {
    // One needs an extension, the other needs a setting flipped. A single
    // "nothing to search" cannot tell a reader which one they are looking at,
    // and guessing wrong sends them to install something they already have.
    final off = _FakeRepo(_loaded);
    final offCubit = _cubitFor(off, excluded: {'lnr:n', 'lnr:x'});
    await offCubit.search('the alpha');
    expect(offCubit.state.noSources, isTrue);
    expect(offCubit.state.excludedCount, 2, reason: 'they exist, but are off');
    await offCubit.close();

    final none = _FakeRepo([(id: 'mihon:m', name: 'Manga only')]);
    final noneCubit = _cubitFor(none);
    await noneCubit.search('the alpha');
    expect(noneCubit.state.noSources, isTrue);
    expect(
      noneCubit.state.excludedCount,
      0,
      reason: 'nothing to switch back on - they need installing',
    );
    await noneCubit.close();
  });

  test('the source count is reported, so an empty page is not a mystery', () async {
    final repo = _FakeRepo(_loaded);
    final cubit = _cubitFor(repo);
    await cubit.search('the alpha');
    expect(
      cubit.state.sourceCount,
      2,
      reason: 'two novel sources were actually queried',
    );
    await cubit.close();
  });
}
