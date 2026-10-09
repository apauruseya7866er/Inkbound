import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Redacted diagnostics for the LNReader plugin runtime.
///
/// Written because "the extension does not work" is not a diagnosis. A plugin
/// that loads, parses nothing and returns empty looks identical from the UI to
/// one that was refused at the network, to one whose selectors no longer match
/// the page. This says which of those happened, in one line each.
///
/// ### What it never records
///
/// No cookies, no `Authorization`, no `Set-Cookie`, no query strings, no
/// request or response bodies, and no chapter text. A plugin's chapter body is
/// the book the reader is paying for and has no business in a shareable log
/// report. [redactUrl] drops the query for the same reason - extension
/// installations, session tokens and signed URLs all travel in it.
///
/// Everything logged is either a method name, a host, a status code, a length,
/// or a boolean. That is enough to localise a failure and useless for
/// impersonating anyone.
///
/// ### Where it goes
///
/// `debugPrint`, which `main.dart` already mirrors into [AppLogger] - so this
/// is readable from the app's own log and exportable in a bug report, the same
/// path the TTS and reader logs already use.
class LnReaderDiag {
  LnReaderDiag._();

  /// Verbose fetch logging, off by default.
  ///
  /// One line per HTTP request is fine while chasing a specific source and
  /// noise otherwise, so it is a switch rather than always-on. [stage] lines
  /// are always written: they are one per user action and name the stage.
  static bool verboseFetch = false;

  /// `https://webnovel.com/novel/x/123?token=abc` becomes
  /// `https://webnovel.com/novel/x/123`.
  ///
  /// The path is kept because for these hosts it carries the chapter
  /// identifier, and "which chapter request failed" is the question being
  /// asked. The query is dropped whole.
  static String redactUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return '<unparseable-url>';
    if (!uri.hasScheme) return '<relative-url>';
    // Replaced rather than emptied: `replace(query: '')` leaves a trailing
    // `?#`, which reads in a log like a redacted value still hiding something.
    final base = '${uri.scheme}://${uri.authority}${uri.path}';
    // A path is normally present, but `https://host` parses with an empty one
    // and logging a bare origin is the honest answer.
    return base.endsWith('/') && uri.path.isEmpty ? base.substring(0, base.length - 1) : base;
  }

  /// Header names only. Values are never recorded.
  static String headerNames(Map<String, String> headers) {
    final names = headers.keys.map((k) => k.toLowerCase()).toList()..sort();
    return names.isEmpty ? '-' : names.join(',');
  }

  /// A request leaving the host for a plugin.
  ///
  /// [label] names the plugin so two sources used in the same session do not
  /// produce indistinguishable lines.
  static void request({
    required String label,
    required String url,
    required String method,
    required Map<String, String> requestHeaders,
  }) {
    if (!verboseFetch) return;
    debugPrint(
      '[lnr-diag] $label -> $method ${redactUrl(url)} '
      'reqHeaders=[${headerNames(requestHeaders)}]',
    );
  }

  /// A response arriving back at a plugin.
  ///
  /// [bodyBytes] is a length, never the body. A challenge page and a real
  /// chapter differ by status and by content type; the length is what makes
  /// "200 but empty" distinguishable from "200 with content" without keeping
  /// the content.
  static void response({
    required String label,
    required String url,
    required int status,
    required String finalUrl,
    required int bodyBytes,
    Map<String, String> responseHeaders = const {},
    bool cloudflare = false,
    String? via,
  }) {
    if (!verboseFetch) return;
    final cf = cloudflare ? ' CF-CHALLENGE' : '';
    final redirected = finalUrl.isEmpty || finalUrl == url
        ? ''
        : ' final=${redactUrl(finalUrl)}';
    debugPrint(
      '[lnr-diag] $label <- $status$cf len=$bodyBytes$redirected'
      '${via == null ? '' : ' via=$via'}'
      ' respHeaders=[${headerNames(responseHeaders)}]'
      ' ${redactUrl(url)}',
    );
  }

  /// A plugin method returning.
  ///
  /// This is the line that answers "which stage failed". [kind] is what came
  /// back - `ok`, `empty`, `unexpected`, `threw` - and [detail] carries only
  /// counts and type names, never content.
  static void stage({
    required String label,
    required String method,
    required String kind,
    String? detail,
    Object? error,
  }) {
    final tail = detail == null || detail.isEmpty ? '' : ' $detail';
    final err = error == null ? '' : ' error=${_brief(error)}';
    debugPrint('[lnr-diag] $label.$method -> $kind$tail$err');
  }

  /// One-line form of an exception, truncated.
  ///
  /// A plugin stack can be enormous and is rarely the useful part; the message
  /// is.
  static String _brief(Object error) {
    var text = error.toString();
    if (text.length > 160) text = '${text.substring(0, 160)}...';
    return text.replaceAll('\n', ' ');
  }

  /// Describes what a plugin returned, for [stage].
  ///
  /// Returns `('empty', null)` for an empty list, which is the case worth
  /// catching: it is what a Cloudflare page, a login wall and a moved selector
  /// all look like from inside the plugin.
  static (String, String?) describe(Object? raw) {
    if (raw == null) return ('null', null);
    if (raw is List) {
      return raw.isEmpty
          ? ('empty', 'list(0)')
          : ('ok', 'list(${raw.length})');
    }
    if (raw is Map) {
      final keys = raw.keys.map((k) => k.toString()).toList()..sort();
      return (
        'ok',
        'map(${keys.take(8).join(',')}${keys.length > 8 ? ',…' : ''})',
      );
    }
    if (raw is String) {
      return raw.trim().isEmpty
          ? ('empty', 'string(0)')
          : ('ok', 'string(${raw.length})');
    }
    return ('unexpected', raw.runtimeType.toString());
  }

  /// Whether a plugin's loaded identity and the repository's index agree.
  ///
  /// Logged once per load. When these differ, storage saved under one key is
  /// read back under another, so a plugin's own setting appears to reset on
  /// every restart with nothing wrong with the setting itself.
  /// Whether a loaded plugin's own id disagrees with the index entry it was
/// installed under.
///
/// Separate from [identity] so the decision is testable without capturing
/// `debugPrint` output.
static bool identityMismatch(String indexId, String? pluginId) =>
    pluginId != null && pluginId != indexId;

static void identity({
    required String indexId,
    required String? pluginId,
    required String? pluginName,
    required String? site,
  }) {
    final mismatch = identityMismatch(indexId, pluginId) ? ' MISMATCH' : '';
    debugPrint(
      '[lnr-diag] loaded index=$indexId plugin=$pluginId '
      'name=${jsonEncode(pluginName)} site=${jsonEncode(site)}$mismatch',
    );
  }
}