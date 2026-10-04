import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/features/detail/detail_screen.dart';

MediaItem _item({
  required String sourceId,
  required ProviderType type,
}) => MediaItem(
  id: 'route-guard',
  title: 'Route guard',
  url: 'https://example.com/route-guard',
  type: type,
  sourceId: sourceId,
);

void main() {
  test('novel titles keep the Detail transition', () {
    final route = DetailScreen.route(
      _item(sourceId: 'lnr:example', type: ProviderType.novel),
    );

    expect(route, isA<PageRouteBuilder<void>>());
  });

  test('non-novel titles are rerouted before Detail builds', () {
    final route = DetailScreen.route(
      _item(sourceId: 'cs:example', type: ProviderType.anime),
    );

    expect(route, isA<MaterialPageRoute<void>>());
  });
}
