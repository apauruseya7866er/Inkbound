import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_provider.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';

/// [SourceRepository.home]'s "the provider has no usable home feed" path.
///
/// The bug this pins: `home()` only fell back to `popular()` when `getHome`
/// returned **null**. A provider that implements `getHome` and returns rows with
/// nothing in them took the other branch and produced an empty home. On Home
/// that silently deleted the source's row — eight pinned sources, two rows, and
/// nothing anywhere saying which six had gone or why.
class _HomeProvider extends AniyomiProvider {
  _HomeProvider(int id, {this.home})
    : super(
        info: AniyomiSourceInfo(
          id: id,
          name: 'Fake $id',
          lang: 'en',
          baseUrl: '',
          pkg: 'fake',
          nsfw: false,
        ),
      );

  /// What `getHome` reports. Null means "not implemented", which is the
  /// condition the fallback already handled.
  final List<HomeSection>? home;

  int popularCalls = 0;

  /// The value is nullable, not the Future — that is how a provider says
  /// "I have no home feed". Never calls super, so no QuickJS runtime is
  /// involved.
  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) async => home;

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) async {
    popularCalls++;
    return [
      MediaItem(
        id: 'pop-$dateRange',
        title: 'Popular $dateRange',
        url: 'https://fake.test/$dateRange',
        type: ProviderType.anime,
        sourceId: sourceId,
      ),
    ];
  }
}

SourceRepository _repoWith(AniyomiManager aniManager) => SourceRepository(
  manager: ProviderManager(dio: Dio()),
  csManager: CloudStreamManager(),
  aniManager: aniManager,
  activeSource: ActiveSourceCubit(),
  prefs: PlaybackPrefs(),
);

void main() {
  // ProviderManager eagerly spins up the QuickJS runtime in its constructor;
  // that needs the Flutter test binding initialised first.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SourceRepository.home fallbacks', () {
    test('a getHome that returns rows with nothing in them still gives a home', () async {
      final ani = AniyomiManager();
      final p = _HomeProvider(
        1,
        home: const [
          HomeSection(title: 'Popular', items: []),
          HomeSection(title: 'Latest', items: []),
        ],
      )..popularCalls = 0;
      ani.register(p);
      final repo = _repoWith(ani);

      final sections = await repo.home(sourceId: p.sourceId);

      // The whole point: this used to be empty, and an empty result is what made
      // a pinned source vanish from Home with no error anywhere.
      expect(sections, isNotEmpty);
      expect(sections.every((s) => s.items.isNotEmpty), isTrue);
      expect(p.popularCalls, greaterThan(0));
    });

    test('a getHome with real content is used as-is, without touching popular', () async {
      final ani = AniyomiManager();
      final p = _HomeProvider(
        2,
        home: const [
          HomeSection(title: 'Only Row', items: [
            MediaItem(
              id: 'a',
              title: 'Real',
              url: 'https://fake.test/a',
              type: ProviderType.anime,
              sourceId: 's',
            ),
          ]),
        ],
      );
      ani.register(p);
      final repo = _repoWith(ani);

      final sections = await repo.home(sourceId: p.sourceId);

      expect(sections.map((s) => s.title), ['Only Row']);
      expect(p.popularCalls, 0);
    });

    test('one populated row among empty ones is enough', () async {
      final ani = AniyomiManager();
      final p = _HomeProvider(
        3,
        home: const [
          HomeSection(title: 'Empty', items: []),
          HomeSection(title: 'Full', items: [
            MediaItem(
              id: 'b',
              title: 'Real',
              url: 'https://fake.test/b',
              type: ProviderType.anime,
              sourceId: 's',
            ),
          ]),
          HomeSection(title: 'Also empty', items: []),
        ],
      );
      ani.register(p);
      final repo = _repoWith(ani);

      final sections = await repo.home(sourceId: p.sourceId);

      // The empty neighbours are still dropped — this is not a licence to render
      // blank rows, only to fall through when nothing at all is usable.
      expect(sections.map((s) => s.title), ['Full']);
      expect(p.popularCalls, 0);
    });
  });
}