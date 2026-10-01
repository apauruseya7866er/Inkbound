/// TTS sentence segmentation.
///
/// Pure Dart, no Flutter and no platform channel, so it is fully unit-testable
/// off-device. That matters: everything else in the TTS stack is Kotlin and can
/// only be verified on a device, but the thing that decides whether speech
/// sounds human is this file, and it needs to be provable in CI.
///
/// Ported from Novery's `util/SentenceParser.kt` (GPL-3.0), which is the most
/// complete sentence splitter I could find for this problem. The behaviours
/// worth naming, because they are what stop TTS sounding broken:
///
///  * **Pause length comes from the punctuation.** A comma-ish beat and a full
///    stop get different gaps; a uniform gap between every sentence is the
///    single biggest tell that nobody tuned the audio.
///  * **Abbreviations don't end sentences.** "Mr. Smith" is one sentence, not
///    two, and "3.5" is not two either.
///  * **Colons split, except when they are a time or ratio.** "He said: hello"
///    is two; "the race was 3:30" is one.
///  * **Ellipses are ambiguous and get disambiguated.** "Wait... what?" starts a
///    new sentence; "He was... uncertain" does not.
///  * **Quotes are stripped before speaking.** Engines read quotation marks
///    aloud or mispronounce them, and the pause they imply is already encoded
///    in [pauseAfterMs].
library;

import 'narration_filter.dart';

/// Pause after a sentence, in milliseconds, chosen by its terminator.
///
/// These are the gaps a person leaves, not the gaps a machine needs to get
/// through a queue. They were 40–150ms, which is roughly the space between two
/// lines of one paragraph: the sentences ran together and the narration read
/// like something working through a list. What sounds natural is a beat you can
/// notice without calling it a pause — a few hundred milliseconds — and the
/// punctuation still legible in it. A question takes the longest of the three
/// because people leave the floor open at one.
class TtsPause {
  const TtsPause._();

  /// Comma-ish beat, and after an em/en dash.
  static const int short = 150;

  /// A plain sentence end.
  static const int normal = 340;

  /// After `!`.
  static const int exclamation = 420;

  /// After `?` — a beat longer than `!`, matching how people actually pause.
  static const int question = 520;

  /// After an em/en dash.
  static const int dash = short;

  /// After a colon that was used as a divider.
  static const int colon = 250;

  /// After a trailing ellipsis: a held breath, not a full stop.
  static const int ellipsis = 650;

  /// Added on top when the next sentence starts a new paragraph.
  ///
  /// Added rather than substituted for the punctuation's own beat, because a
  /// paragraph break does not erase it: a paragraph ending in a question is
  /// still the longest pause in the passage. It stays a modest addition rather
  /// than a fixed silence of its own, since a novel written in one-sentence
  /// paragraphs would otherwise be mostly gaps.
  static const int paragraph = 320;
}

/// One speakable sentence, with the gap that should follow it.
class TtsSentence {
  const TtsSentence({
    required this.text,
    required this.startIndex,
    required this.endIndex,
    required this.index,
    required this.pauseAfterMs,
    this.blockIndex = 0,
  });

  /// Normalised, ready to hand to the engine (quotes removed, punctuation
  /// tidied). Never blank.
  final String text;

  /// Offsets into the *source* string this sentence was cut from, kept so a
  /// highlight can be mapped back onto the original text.
  final int startIndex;
  final int endIndex;

  /// Position within its chapter, 0-based and contiguous.
  final int index;

  /// Gap to leave after this sentence before the next one.
  final int pauseAfterMs;

  /// Which paragraph of the chapter this came from. The reader needs this to
  /// know what to keep on screen.
  final int blockIndex;
}

/// A paragraph (or other block) and the sentences inside it.
class TtsBlock {
  const TtsBlock({required this.text, required this.sentences});

  final String text;
  final List<TtsSentence> sentences;
}

/// Everything TTS needs to speak one chapter.
class TtsChapterContent {
  const TtsChapterContent({
    required this.blocks,
    required this.sentences,
  });

  final List<TtsBlock> blocks;

  /// Every sentence in reading order, flattened.
  final List<TtsSentence> sentences;

  int get totalSentences => sentences.length;
  bool get isEmpty => sentences.isEmpty;

  TtsSentence? sentenceAt(int i) =>
      (i >= 0 && i < sentences.length) ? sentences[i] : null;
}

/// Parses chapter HTML (or plain text) into speakable sentences.
class SentenceParser {
  SentenceParser._();

  /// Honorifics and titles whose period NEVER ends a sentence.
  ///
  /// Novery gates its whole abbreviation list on "followed by a lowercase
  /// word", which means `Mr. Smith met Dr. Jones` splits into three and gets
  /// spoken as "Mister. Smith met Mister. Jones" — a name after a title is
  /// capitalised, so the gate never fires for the one case that matters most.
  ///
  /// These are split off from the list below for that reason: a stray merge
  /// ("etc. And then" staying one sentence) costs a beat, while splitting
  /// "Mr. Smith" mangles a name out loud.
  static const Set<String> _titleAbbreviations = {
    'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'rev', 'hon',
    'capt', 'col', 'gen', 'lt', 'sgt',
    'st', 'ave', 'blvd', 'rd', 'ft', 'mt', 'apt',
  };

  /// Other abbreviations — months, and Latin/legal short forms. These keep
  /// Novery's "only merge when a lowercase word follows" rule, because here the
  /// capital does carry meaning: "in Jan. He left" is two sentences, while
  /// "in Jan. he left" is one.
  static const Set<String> _abbreviations = {
    'vs', 'etc', 'inc', 'ltd', 'co', 'corp',
    'pg', 'pp', 'ch', 'pt', 'no', 'nos',
    'fig', 'figs', 'approx', 'dept', 'est', 'govt', 'misc',
    'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  };

  /// Characters that can end a sentence. A colon is here deliberately — see
  /// [_isSentenceEnd] for the time/ratio exception.
  static const String _sentenceEndings = '.!?:';

  /// Characters that may trail a terminator and still belong to it, so a
  /// quoted sentence ends at its closing quote and not before it.
  static const String _closingQuotes = '"”\'’」』)]»';

  static const String _openingQuotes = '"“\'‘「『[«';

  static final RegExp _punctuationOnly = RegExp(
    '^["\'“”‘’„‚「」『』()\\[\\]«»'
    r'.,!?…:;\-—–_\s\d]+$',
  );

  /// Any letter, any script — so a chapter in Arabic, Hindi or Thai segments
  /// rather than being discarded as "punctuation only".
  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);
  static final RegExp _upper = RegExp(r'\p{Lu}', unicode: true);
  static final RegExp _lower = RegExp(r'\p{Ll}', unicode: true);
  static final RegExp _digit = RegExp(r'[0-9]', unicode: true);

  // ── public API ────────────────────────────────────────────────────────────

  /// Splits chapter [html] into blocks of sentences.
  ///
  /// Block boundaries come from `</p>` and block-level tags, mirroring what the
  /// reader renders, so a sentence's [TtsSentence.blockIndex] means the same
  /// thing to the speech queue and to the screen.
  static TtsChapterContent parseHtml(String html) {
    final blocks = <TtsBlock>[];
    final all = <TtsSentence>[];
    final rawBlocks = _splitIntoBlocks(html);
    var blockIndex = 0;

    for (var b = 0; b < rawBlocks.length; b++) {
      final text = _preprocess(rawBlocks[b]);
      if (text.isEmpty) continue;
      final sentences = <TtsSentence>[];

      // A block that is a note rather than prose contributes no sentences, but
      // it still has to be added below: the reader numbers blocks against what
      // it drew, so dropping one here would shift every later blockIndex.
      if (!NarrationFilter.skipBlock(text, blockIndex: b, blockCount: rawBlocks.length)) {
        for (final s in _parseSentences(text)) {
          sentences.add(
            TtsSentence(
              text: s.text,
              startIndex: s.startIndex,
              endIndex: s.endIndex,
              index: all.length,
              pauseAfterMs: s.pauseAfterMs,
              blockIndex: blockIndex,
            ),
          );
          all.add(sentences.last);
        }
      }
      // A block that yielded nothing (an image, a rule) still counts as a
      // block, so blockIndex stays aligned with what the reader drew.
      blocks.add(TtsBlock(text: text, sentences: sentences));
      blockIndex++;
    }

    return TtsChapterContent(blocks: blocks, sentences: all);
  }

  /// Splits plain [text] into sentences. Used by tests and by any caller that
  /// already has the text without markup.
  static TtsBlock parseText(String text) {
    final cleaned = _preprocess(text);
    final sentences = _parseSentences(cleaned);
    return TtsBlock(text: cleaned, sentences: sentences);
  }

  /// Splits [text] into sentences **without** normalising whitespace first.
  ///
  /// The distinction matters for highlighting. [parseText] collapses runs of
  /// spaces and rewrites `--`, which shifts every character offset after the
  /// first change; a sentence index from that path points into a string the
  /// reader never renders, so a highlight built from it lands on the wrong
  /// words. This path segments the text as given, so
  /// `TtsSentence.startIndex`/`endIndex` are offsets into exactly what is on
  /// screen.
  ///
  /// The spoken text is still tidied — the returned `text` is the normalised
  /// form — but the indices refer to the input, not to the tidied copy.
  ///
  /// [narrationFilter] off keeps the sentences the narrator would refuse to say:
  /// the reader hit-tests a long press against this list to find the sentence
  /// under the finger, and the sentences the filter drops — donation pleas,
  /// chapter footers — are exactly the ones somebody wants to hide. Filtering
  /// them out of the list a long press searches makes "hide this sentence" come
  /// up empty on every ad in the book.
  static List<TtsSentence> parseRaw(
    String text, {
    bool narrationFilter = true,
  }) => _parseSentences(text, narrationFilter: narrationFilter);

  // ── HTML → blocks ─────────────────────────────────────────────────────────

  /// Splits raw chapter HTML into visible text, one entry per block.
  ///
  /// Deliberately not a general HTML parser: it keeps inline styling markers out
  /// of the output (TTS must not read "strong" aloud) and drops `<script>` /
  /// `<style>` bodies, which is the same set of concerns the reader's own
  /// `_tokenizeHtml` handles.
  static List<String> _splitIntoBlocks(String html) {
    final cleaned = html.replaceAll(
      RegExp(r'<(script|style)[^>]*>.*?(?:</\1>|$)',
          caseSensitive: false, dotAll: true),
      '',
    );

    final out = <String>[];
    final buffer = StringBuffer();

    void flush() {
      final t = buffer.toString();
      if (t.trim().isNotEmpty) out.add(t);
      buffer.clear();
    }

    // A block boundary is a closed paragraph, a heading, a div, a list item, a
    // blockquote or a rule. `<br>` is deliberately NOT one: it is a soft line
    // break inside a paragraph (poetry, addresses) and splitting there would
    // chop a verse into separate sentences.
    final blockEnd = RegExp(
      r'</(p|div|h[1-6]|li|blockquote|tr|section|article|figure|pre)>',
      caseSensitive: false,
    );
    final brk = RegExp(r'<br\s*/?>', caseSensitive: false);
    final tag = RegExp(r'<[^>]*>');

    var last = 0;
    for (final m in tag.allMatches(cleaned)) {
      if (m.start > last) {
        buffer.write(_unescape(cleaned.substring(last, m.start)));
      }
      final whole = cleaned.substring(m.start, m.end);
      if (brk.hasMatch(whole)) {
        buffer.write(' ');
      } else if (blockEnd.hasMatch(whole)) {
        flush();
      }
      // <img>, <b>, <i>, <span>, ...: dropped, text kept.
      last = m.end;
    }
    if (last < cleaned.length) {
      buffer.write(_unescape(cleaned.substring(last)));
    }
    flush();
    return out;
  }

  static String _unescape(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&mdash;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll('&hellip;', '…')
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      );

  // ── text → sentences ──────────────────────────────────────────────────────

  static List<TtsSentence> _parseSentences(
    String text, {
    bool narrationFilter = true,
  }) {
    if (text.trim().isEmpty) return const [];

    final out = <TtsSentence>[];
    var sentenceStart = 0;
    var i = 0;
    var index = 0;
    // Loop guard. Every branch below advances `i`; if one ever stopped doing so
    // this would spin forever on a real chapter, so it is enforced rather than
    // assumed.
    var lastI = -1;

    while (i < text.length) {
      if (i == lastI) {
        i++;
        continue;
      }
      lastI = i;

      final c = text[i];

      // Ellipsis first: "..." and "…" are handled before the plain-terminator
      // path, because the dots would otherwise each look like a sentence end.
      if (c == '.' || c == '…') {
        final ellEnd = _findEllipsisEnd(text, i);
        if (ellEnd > i) {
          if (_shouldBreakAtEllipsis(text, ellEnd)) {
            var end = _skipClosingQuotes(text, ellEnd);
            final raw = text.substring(sentenceStart, end).trim();
            final normalised = _normalise(raw);
            if (_isValid(normalised) &&
                !(narrationFilter && NarrationFilter.skipSentence(raw))) {
              out.add(TtsSentence(
                text: normalised,
                startIndex: sentenceStart,
                endIndex: end,
                index: index++,
                pauseAfterMs: TtsPause.ellipsis,
              ));
            }
            sentenceStart = _skipWhitespace(text, end);
            i = sentenceStart;
            continue;
          }
          i = ellEnd;
          continue;
        }
      }

      if (_sentenceEndings.contains(c)) {
        if (_isSentenceEnd(text, i)) {
          var end = i + 1;
          // Swallow a run of terminators, but never swallow a colon that
          // follows other punctuation — "Hello!:" is not a thing.
          while (end < text.length &&
              _sentenceEndings.contains(text[end]) &&
              text[end] != ':') {
            end++;
          }
          end = _skipClosingQuotes(text, end);

          final raw = text.substring(sentenceStart, end).trim();
          final normalised = _normalise(raw);
          if (_isValid(normalised) &&
                !(narrationFilter && NarrationFilter.skipSentence(raw))) {
            out.add(TtsSentence(
              text: normalised,
              startIndex: sentenceStart,
              endIndex: end,
              index: index++,
              pauseAfterMs: _pauseFor(raw),
            ));
          }
          sentenceStart = _skipWhitespace(text, end);
          i = sentenceStart;
          continue;
        }
      }

      i++;
    }

    // Trailing text with no terminator.
    if (sentenceStart < text.length) {
      final raw = text.substring(sentenceStart).trim();
      final normalised = _normalise(raw);
      if (_isValid(normalised) &&
                !(narrationFilter && NarrationFilter.skipSentence(raw))) {
        out.add(TtsSentence(
          text: normalised,
          startIndex: sentenceStart,
          endIndex: text.length,
          index: index,
          pauseAfterMs: _pauseFor(raw),
        ));
      }
    }

    // Nothing segmented but there IS text (a wall of punctuation, or a script
    // with no sentence terminators). Speak it as one block rather than staying
    // silent — a source that renders is a source the user chose.
    //
    // The filter check is load-bearing, not a formality: a paragraph that is
    // one donation plea segments fine but is skipped, and without this the
    // fallback would hand the very sentence the filter just rejected straight
    // back to the engine.
    if (out.isEmpty &&
        _hasLetter(text) &&
        !(narrationFilter && NarrationFilter.skipSentence(text))) {

      final normalised = _normalise(text);
      if (normalised.isNotEmpty) {
        out.add(TtsSentence(
          text: normalised,
          startIndex: 0,
          endIndex: text.length,
          index: 0,
          pauseAfterMs: TtsPause.normal,
        ));
      }
    }

    return out;
  }

  // ── terminator classification ─────────────────────────────────────────────

  /// Whether the punctuation at [index] really ends a sentence.
  static bool _isSentenceEnd(String text, int index) {
    final c = text[index];

    if (c == ':') {
      // A URL scheme separator. "https://example.com" is one thing to read,
      // and splitting it left the engine saying "https" and then reciting
      // "//example dot com" as a second sentence.
      if (index + 2 < text.length &&
          text[index + 1] == '/' &&
          text[index + 2] == '/') {
        return false;
      }
      // A colon between digits is a time or a ratio ("3:30", "2:1").
      if (index > 0 &&
          index < text.length - 1 &&
          _isDigit(text[index - 1]) &&
          _isDigit(text[index + 1])) {
        return false;
      }
      // Everything else splits, full stop.
      //
      // Novery also requires a capitalised word to follow, which defeats the
      // feature: the whole reason a colon is a terminator here is prose like
      // "He said: it begins here" and "Note: this matters", where a lowercase
      // word after the colon is normal. Gating on case made the rule fire
      // almost never.
      return true;
    }

    if (c == '.') {
      // Part of an ellipsis — handled by the caller, but be safe.
      if (index + 2 < text.length &&
          text[index + 1] == '.' &&
          text[index + 2] == '.') {
        return false;
      }

      // Known abbreviation. A title never splits; the rest only merge when a
      // lowercase word follows (see the two sets for why they differ).
      final wordStart = _findWordStart(text, index);
      if (wordStart < index) {
        final word = text.substring(wordStart, index).toLowerCase();
        if (_titleAbbreviations.contains(word)) return false;
        if (_abbreviations.contains(word)) {
          final next = _skipWhitespace(text, index + 1);
          if (next < text.length && _isLower(text[next])) return false;
        }
      }

      // Decimal: "3.5".
      if (index > 0 &&
          index < text.length - 1 &&
          _isDigit(text[index - 1]) &&
          _isDigit(text[index + 1])) {
        return false;
      }

      // Initial: "J. R. R. Tolkien".
      if (_isInitial(text, index)) return false;
    }

    var next = index + 1;
    while (next < text.length && text[next] == c) {
      next++;
    }
    next = _skipClosingQuotes(text, next);
    next = _skipWhitespace(text, next);

    if (next >= text.length) return true;

    final nextChar = text[next];

    // Capital or opening quote after the terminator: a new sentence.
    if (_isUpper(nextChar) || _openingQuotes.contains(nextChar)) return true;

    // "!" and "?" always split, whatever follows.
    if (c == '!' || c == '?') return true;

    // A period followed by whitespace is a strong signal.
    if (c == '.' && index + 1 < text.length && _isWhitespace(text[index + 1])) {
      return true;
    }

    return false;
  }

  /// "J. R." — a single capital, optionally followed by another capitalised
  /// word, and never preceded by a letter.
  static bool _isInitial(String text, int periodIndex) {
    if (periodIndex < 1) return false;
    final before = text[periodIndex - 1];
    if (!_isUpper(before)) return false;
    // Part of a longer word, so not an initial ("Prof").
    if (periodIndex >= 2 && _isLetter(text[periodIndex - 2])) return false;

    final next = _skipWhitespace(text, periodIndex + 1);
    if (next >= text.length) return false;
    if (_isUpper(text[next])) {
      final after = next + 1;
      if (after < text.length && (text[after] == '.' || _isLower(text[after]))) {
        return true;
      }
    }
    return false;
  }

  /// End of an ellipsis starting at [index], or [index] if it isn't one.
  static int _findEllipsisEnd(String text, int index) {
    if (text[index] == '…') return index + 1;
    if (text[index] == '.' &&
        index + 2 < text.length &&
        text[index + 1] == '.' &&
        text[index + 2] == '.') {
      var end = index + 3;
      while (end < text.length && text[end] == '.') {
        end++;
      }
      return end;
    }
    return index;
  }

  /// Whether an ellipsis is a sentence break or a mid-sentence trailing off.
  ///
  /// "Wait... what?" breaks (capital after whitespace). "He was... uncertain"
  /// does not (lowercase). "1...2" does not (digit, no whitespace).
  static bool _shouldBreakAtEllipsis(String text, int afterEllipsis) {
    var i = _skipClosingQuotes(text, afterEllipsis);
    final hadWhitespace = i < text.length && _isWhitespace(text[i]);
    i = _skipWhitespace(text, i);

    if (i >= text.length) return true;

    final next = text[i];
    if (_isUpper(next) && hadWhitespace) return true;
    if (_openingQuotes.contains(next) && hadWhitespace) return true;
    if (_isLower(next)) return false;
    if (_isDigit(next) && !hadWhitespace) return false;
    return hadWhitespace;
  }

  // ── normalisation ──────────────────────────────────────────────────────────

  /// Tidy one sentence for speaking: drop quotes the engine would read aloud,
  /// settle ellipsis, trim punctuation the split already accounted for.
  static String _normalise(String input) {
    // First, so a URL or an address is gone before anything looks at the
    // letters, and an emptied sentence fails the validity check below.
    var s = NarrationFilter.sanitise(input.trim());

    // Engines mispronounce or vocalise quotation marks, and the beat they imply
    // is already encoded as a pause.
    s = s.replaceAll(RegExp('["\'“”‘’「」『』«»]'), '');

    s = s.replaceAll('…', '...');
    s = s.replaceAll(RegExp(r'\.{4,}'), '...');
    s = s.replaceAll(RegExp(r'^\.{3}\s*'), '');
    s = s.replaceAll(RegExp(r'\s*\.{3}$'), '');
    // Mid-sentence ellipsis becomes a comma — same hitch, no odd pause.
    s = s.replaceAll(RegExp(r'\s*\.{3}\s*(?=[A-Za-z])'), ', ');
    // We split on colons, so there is no reason to speak one.
    s = s.replaceAll(RegExp(r':\s*$'), '');
    s = s.replaceAll(RegExp(r'^\s*:'), '');

    s = s.replaceAll(RegExp(r'^[,;:\s]+'), '');
    s = s.replaceAll(RegExp(r'[,;:\s]+$'), '');
    s = s.replaceAll(RegExp(r',\s*,'), ',');
    s = s.replaceAll(RegExp(r' {2,}'), ' ');

    return s.trim();
  }

  /// Flattens newlines and runs of spaces, and settles dash styles so
  /// `_pauseFor` sees one character.
  static String _preprocess(String input) {
    var s = input.replaceAll(RegExp(r'[ \t]*\n[ \t]*'), ' ');
    s = s.replaceAll(RegExp(r' {2,}'), ' ');
    s = s.replaceAll('---', '—').replaceAll('--', '—');
    return s.trim();
  }

  /// The pause that follows [raw], chosen by how it actually ends.
  static int _pauseFor(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return TtsPause.normal;

    if (t.endsWith('…') || t.endsWith('...')) return TtsPause.ellipsis;

    // Look through any trailing closing quotes to the real terminator.
    var effective = t[t.length - 1];
    var look = t.length - 2;
    while (_closingQuotes.contains(effective) && look >= 0) {
      effective = t[look];
      look--;
    }

    if (effective == ':') return TtsPause.colon;
    if (effective == '?') return TtsPause.question;
    if (effective == '!') return TtsPause.exclamation;
    if (effective == '—' || effective == '–') return TtsPause.dash;
    if (effective == '…') return TtsPause.ellipsis;
    return TtsPause.normal;
  }

  // ── predicates & helpers ──────────────────────────────────────────────────

  static bool _isValid(String s) =>
      s.isNotEmpty && !_punctuationOnly.hasMatch(s) && _hasLetter(s);

  static bool _hasLetter(String s) => _letter.hasMatch(s);

  static int _findWordStart(String text, int endIndex) {
    var start = endIndex - 1;
    while (start >= 0 && _isLetter(text[start])) {
      start--;
    }
    return start + 1;
  }

  static int _skipWhitespace(String text, int from) {
    var i = from;
    while (i < text.length && _isWhitespace(text[i])) {
      i++;
    }
    return i;
  }

  static int _skipClosingQuotes(String text, int from) {
    var i = from;
    while (i < text.length && _closingQuotes.contains(text[i])) {
      i++;
    }
    return i;
  }

  // Dart has no `Char.isUpperCase()`, and its ASCII-only `isUpperCase` on
  // String misses accented and non-Latin letters — which matters because a
  // chapter in French or Russian must segment too. These go through Unicode
  // property escapes instead.
  static bool _isUpper(String c) => c.length == 1 && _upper.hasMatch(c);
  static bool _isLower(String c) => c.length == 1 && _lower.hasMatch(c);
  static bool _isLetter(String c) => c.length == 1 && _letter.hasMatch(c);
  static bool _isDigit(String c) => c.length == 1 && _digit.hasMatch(c);
  static bool _isWhitespace(String c) =>
      c.length == 1 && RegExp(r'\s').hasMatch(c);
}
