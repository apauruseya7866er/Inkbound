import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/search/browse_source_kinds.dart';
import 'package:watch_app/features/search/browse_sources_list.dart';
import 'package:watch_app/l10n/app_localizations_en.dart';

void main() {
  test('exposes only the novel tab in the novel-only build', () {
    expect(BrowseSourceKinds.available(), [SourceListKind.novel]);
  });

  test('maps every source-browser kind to its content mode', () {
    expect(
      BrowseSourceKinds.contentModeOf(SourceListKind.streaming),
      ContentMode.anime,
    );
    expect(
      BrowseSourceKinds.contentModeOf(SourceListKind.manga),
      ContentMode.manga,
    );
    expect(
      BrowseSourceKinds.contentModeOf(SourceListKind.novel),
      ContentMode.novel,
    );
  });

  test('labels every tab in the same order', () {
    final l10n = AppLocalizationsEn();
    expect(
      BrowseSourceKinds.tabLabels(
        l10n,
        const [ContentMode.anime, ContentMode.manga, ContentMode.novel],
      ),
      ['Streaming', 'Manga', 'Novel'],
    );
  });
}
