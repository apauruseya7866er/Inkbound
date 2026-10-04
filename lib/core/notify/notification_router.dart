import 'package:flutter/material.dart';

import '../../features/detail/detail_screen.dart';
import '../../features/reader/novel_reader_screen.dart';
import '../di/injector.dart';
import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../mode/mode_policy.dart';
import '../reading/read_history.dart';
import '../reading/tts/tts_prefs.dart';
import '../ui/global_messenger.dart';
import 'subscription_store.dart';

/// Open the Detail screen for the show a new-episode/chapter alert points to.
/// [payload] is "sourceId|url" (split on the FIRST '|' — a url may contain one).
/// The full cover / headers / title come from the stored subscription so Detail
/// renders immediately; it then re-fetches by sourceId+url anyway.
Future<void> openShowFromNotification(String? payload) async {
  if (payload == null) return;
  final i = payload.indexOf('|');
  if (i < 0) return;
  final sourceId = payload.substring(0, i);
  final url = payload.substring(i + 1);
  if (sourceId.isEmpty || url.isEmpty) return;

  Subscription? sub;
  if (sl.isRegistered<SubscriptionStore>()) {
    for (final s in sl<SubscriptionStore>().all()) {
      if (s.sourceId == sourceId && s.url == url) {
        sub = s;
        break;
      }
    }
  }

  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  await nav.push(
    DetailScreen.route(
      MediaItem(
        id: url,
        title: sub?.title ?? '',
        url: url,
        // Was hardcoded to anime, which opened a subscribed manga as a video
        // show. The subscription knows what it is.
        //
        // Novel-only build: a notification stored by a pre-fork build carries
        // Streaming/Manga here, and the old fallback was anime. Both now open
        // as a novel — the Detail screen normalises the same way, so a stale
        // notification can't reach a video or page-image surface.
        type: ModePolicy.notificationType(sub?.mode),
        sourceId: sourceId,
        cover: sub?.cover,
        coverHeaders: sub?.coverHeaders,
      ),
    ),
  );
}

/// Restore the chapter and sentence saved by read-aloud when its notification
/// launches the app after the reader route has been discarded.
Future<void> openTtsReaderFromNotification() async {
  final activeReader = NovelReaderScreen.ttsNotificationHandler;
  if (activeReader != null) {
    if (await activeReader()) return;
  }

  final nav = rootNavigatorKey.currentState;
  if (nav == null || !sl.isRegistered<TtsPrefs>()) return;
  final prefs = sl<TtsPrefs>();
  final bookId = prefs.lastBookId;
  if (bookId == null || bookId.isEmpty) return;
  final point = prefs.savedPosition(bookId);
  if (point == null) return;
  final history = sl<ReadHistory>().all();
  ReadEntry? entry;
  for (final candidate in history) {
    if (candidate.showId == bookId && candidate.type == ProviderType.novel) {
      entry = candidate;
      break;
    }
  }
  if (entry == null) return;
  final selectedEntry = entry;

  final chapter = Episode(
    id: point.chapterId,
    title: selectedEntry.chapterUrl == point.chapterId
        ? (selectedEntry.chapterNumber == null
              ? 'Chapter'
              : 'Chapter ${selectedEntry.chapterNumber!.toInt()}')
        : 'Chapter',
    number: selectedEntry.chapterUrl == point.chapterId
        ? selectedEntry.chapterNumber
        : null,
    url: point.chapterId,
  );
  await nav.push(
    MaterialPageRoute<void>(
      builder: (_) => NovelReaderScreen(
        sourceId: selectedEntry.sourceId,
        showId: selectedEntry.showId,
        showTitle: selectedEntry.title,
        cover: selectedEntry.cover,
        chapters: [chapter],
        startIndex: 0,
        resolveChapters: true,
        restoreTtsPosition: true,
      ),
    ),
  );
}
