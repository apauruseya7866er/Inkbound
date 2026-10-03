import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Persists the optional Cloudflare bypass proxy settings.
///
/// Some novel and manga sources sit behind a Cloudflare tier the in-app WebView
/// cannot clear, and handing a solved `cf_clearance` back to the app's own HTTP
/// client does not work either — the clearance is bound to the TLS fingerprint of
/// whatever solved it. For those, a proxy the user runs themselves (Solverr,
/// Byparr or FlareSolverr, all on port 8191) solves in a real browser and returns
/// the page. Off by default; the WebView solver stays the primary path.
class CloudflareBypassPrefs {
  static const String boxName = 'cloudflare_bypass_prefs';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  bool get enabled => _box.get('enabled', defaultValue: false) as bool;

  String get url => _box.get('url', defaultValue: '') as String;

  /// The proxy runs only when it is switched on AND has somewhere to go, so a
  /// blank URL typed but not enabled cannot send every challenged request to an
  /// unreachable host. Mirrors `FlareSolverrConfig.isActive` on the Kotlin side.
  bool get isActive => enabled && url.trim().isNotEmpty;

  Future<void> set({required bool enabled, required String url}) async {
    await _box.put('enabled', enabled);
    await _box.put('url', url.trim());
    await _sync();
  }

  /// Push the values into the native config the interceptors read on every
  /// request. Best-effort: on a host with no Kotlin side (tests, desktop) this
  /// is a no-op rather than an error, because the setting is still persisted and
  /// nothing here is needed to render the screen.
  Future<void> _sync() async {
    try {
      await _channel.invokeMethod<void>('set', {
        'enabled': enabled,
        'url': url,
      });
    } on MissingPluginException {
      // no native side
    } on PlatformException catch (e) {
      debugPrint('[cloudflare-bypass] native sync failed: $e');
    }
  }

  /// Push whatever is persisted. Called once at startup so a value set in a
  /// previous session applies without the user re-toggling anything.
  Future<void> syncToNative() => _sync();

  /// Runs a real solve through the proxy to check it is reachable and working.
  /// Returns null on success (carrying the proxy's User-Agent) or a message on
  /// failure — never throws, so the button can render the result directly.
  ///
  /// A solve can take up to a minute, hence the long timeout; it is off the UI
  /// thread on the native side.
  Future<String?> test(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return 'Enter a URL first';
    try {
      final res = await _channel
          .invokeMapMethod<String, dynamic>('test', {'url': trimmed})
          .timeout(const Duration(seconds: 95));
      if (res == null) return 'No response from the proxy';
      if (res['ok'] == true) return null;
      return (res['error'] as String?)?.trim().isNotEmpty == true
          ? res['error'] as String
          : 'The proxy could not solve';
    } on MissingPluginException {
      return 'Not available on this platform';
    } on PlatformException catch (e) {
      return e.message ?? 'The proxy could not be reached';
    } catch (e) {
      return 'The proxy could not be reached';
    }
  }

  static const MethodChannel _channel =
      MethodChannel('zangetsu/cloudflare_bypass');
}