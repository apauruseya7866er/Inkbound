import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'tts_platform.dart';

/// [TtsPlatform] over the `zangetsu/tts` channel pair in `TtsBridge.kt`.
class MethodChannelTtsPlatform implements TtsPlatform {
  MethodChannelTtsPlatform({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methods = methodChannel ?? const MethodChannel('zangetsu/tts'),
       _eventChannel = eventChannel ?? const EventChannel('zangetsu/tts_events');

  final MethodChannel _methods;
  final EventChannel _eventChannel;

  final StreamController<TtsEngineEvent> _events =
      StreamController<TtsEngineEvent>.broadcast();

  StreamSubscription<dynamic>? _subscription;

  @override
  Stream<TtsEngineEvent> get events {
    _listen();
    return _events.stream;
  }

  void _listen() {
    // Idempotent: `events` is read by the cubit's constructor and again on
    // rebuilds, and a second native subscription would deliver every event
    // twice.
    _subscription ??= _eventChannel.receiveBroadcastStream().listen(
      _onRawEvent,
      onError: (Object e) => _events.addError(e),
    );
  }

  void _onRawEvent(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'];
    final index = (raw['index'] as num?)?.toInt() ?? -1;
    final event = switch (type) {
      'init' => TtsInitialised(ready: raw['ready'] == true),
      'sentenceStart' => TtsSentenceStarted(index),
      'sentenceDone' => TtsSentenceFinished(index),
      'error' => TtsUtteranceFailed(index, (raw['code'] as num?)?.toInt() ?? -1),
      'paused' => TtsPaused(index),
      'resumed' => const TtsResumed(),
      'completed' => const TtsCompleted(),
      'stopped' => const TtsStopped(),
      _ => null,
    };
    if (event != null) _events.add(event);
  }

  @override
  Future<void> init() => _invoke('init');

  @override
  Future<void> start({required List<TtsUnit> units, required int startIndex}) =>
      _invoke('start', {
        'units': units.map((u) => u.toChannel()).toList(),
        'startIndex': startIndex,
      });

  @override
  Future<void> stop() => _invoke('stop');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> resume() => _invoke('resume');

  @override
  Future<void> setVoice(String? name) => _invoke('setVoice', {'name': name});

  @override
  Future<void> setRate(double rate) => _invoke('setRate', {'rate': rate});

  @override
  Future<void> setPitch(double pitch) => _invoke('setPitch', {'pitch': pitch});

  @override
  Future<void> setPauseScale(double scale) =>
      _invoke('setPauseScale', {'scale': scale});

  @override
  Future<List<TtsVoice>> voices() async {
    final raw = await _methods.invokeListMethod<Object?>('voices');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(TtsVoice.fromChannel)
        .toList(growable: false);
  }

  @override
  Future<TtsLanguageStatus> languageStatus(String tag) async {
    final code = await _invoke<int>('languageStatus', {'tag': tag});
    return TtsLanguageStatus.fromCode(code ?? -1);
  }

  @override
  Future<String> defaultLocale() async =>
      await _invoke<String>('defaultLocale') ?? '';

  @override
  Future<void> startService({
    required String title,
    required String sentence,
  }) => _invoke('startService', {'title': title, 'sentence': sentence});

  @override
  Future<void> updateService({
    required String title,
    required String sentence,
  }) => _invoke('updateService', {'title': title, 'sentence': sentence});

  @override
  Future<void> stopService() => _invoke('stopService');

  @override
  Future<bool> serviceRunning() async =>
      await _invoke<bool>('serviceRunning') ?? false;

  /// Channel calls that fail are swallowed on purpose for the setters: a voice
  /// that no longer exists, or an engine that has not finished starting, must
  /// not surface as an unhandled platform exception in the middle of reading.
  /// The one exception is `start`, where a failure means no audio at all, so the
  /// error is allowed through for the cubit to report.
  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      if (method == 'start') rethrow;
      // Logged rather than swallowed silently: a voice that stopped applying, or
      // a rate change that does nothing, is otherwise impossible to diagnose
      // from the Dart side.
      debugPrint('[TtsPlatform] $method failed: ${e.message}');
      return null;
    } on MissingPluginException {
      // The bridge is Android-only. A missing plugin means TTS is simply not
      // available here, not that something broke.
      return null;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _events.close();
  }
}
