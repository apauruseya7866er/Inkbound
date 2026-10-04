import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/mode_policy.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';

MediaItem _item({
  String sourceId = 'lnr:example',
  ProviderType type = ProviderType.novel,
  String url = 'https://example.com/novel',
}) => MediaItem(
  id: url,
  title: 'Example',
  url: url,
  type: type,
  sourceId: sourceId,
);

void main() {
  test('only the novel mode is routable in the novel-only build', () {
    expect(ModePolicy.isModeAllowed(ContentMode.novel), isTrue);
    expect(ModePolicy.isModeAllowed(ContentMode.anime), isFalse);
    expect(ModePolicy.isModeAllowed(ContentMode.manga), isFalse);
  });

  test('only novel provider types are routable in the novel-only build', () {
    expect(
      ModePolicy.isProviderTypeAllowed(ProviderType.novel),
      isTrue,
    );
    expect(ModePolicy.isProviderTypeAllowed(ProviderType.anime), isFalse);
    expect(ModePolicy.isProviderTypeAllowed(ProviderType.movie), isFalse);
    expect(ModePolicy.isProviderTypeAllowed(ProviderType.manga), isFalse);
  });

  test('extension ecosystems are classified without a registry lookup', () {
    expect(ModePolicy.isSourceRouteAllowed('lnr:example'), isTrue);
    expect(ModePolicy.isSourceRouteAllowed('cs:example'), isFalse);
    expect(ModePolicy.isSourceRouteAllowed('ani:1'), isFalse);
    expect(ModePolicy.isSourceRouteAllowed('mihon:1'), isFalse);
  });

  test('bare JS providers use their manifest type when one is known', () {
    const types = {'js:novel': 'novel', 'js:video': 'anime'};
    expect(
      ModePolicy.isSourceRouteAllowed('js:novel', manifestTypes: types),
      isTrue,
    );
    expect(
      ModePolicy.isSourceRouteAllowed('js:video', manifestTypes: types),
      isFalse,
    );
    expect(ModePolicy.isSourceRouteAllowed('js:unknown'), isTrue);
  });

  test('metadata routes are classified by canonical kind, not stale type', () {
    expect(
      ModePolicy.isMediaItemRouteAllowed(
        _item(sourceId: 'zm', url: 'zm://novel/mal:1'),
      ),
      isTrue,
    );
    expect(
      ModePolicy.isMediaItemRouteAllowed(
        _item(sourceId: 'zm', url: 'zm://anime/mal:1'),
      ),
      isFalse,
    );
    expect(
      ModePolicy.isMediaItemRouteAllowed(
        _item(sourceId: 'zm', url: 'zm://broken'),
      ),
      isFalse,
    );
  });

  test('stale notification modes normalize to novels', () {
    expect(ModePolicy.notificationType(ContentMode.anime), ProviderType.novel);
    expect(ModePolicy.notificationType(ContentMode.manga), ProviderType.novel);
    expect(ModePolicy.notificationType(ContentMode.novel), ProviderType.novel);
    expect(ModePolicy.notificationType(null), ProviderType.novel);
  });

  test('boot only retains routable source IDs', () {
    expect(
      ModePolicy.filterAllowedSourceIds(const {
        'lnr:novel',
        'js:novel',
        'cs:video',
        'ani:1',
        'mihon:1',
      }, manifestTypes: const {'js:novel': 'novel'}),
      {'lnr:novel', 'js:novel'},
    );
  });
}
