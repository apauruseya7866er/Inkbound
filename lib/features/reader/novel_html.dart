/// Chapter HTML → the exact styled text the novel reader renders.
///
/// Extracted from `novel_reader_screen.dart` and deliberately free of any
/// Flutter import, because it is now shared by two consumers that must agree
/// character-for-character: the paged renderer, which turns these tokens into
/// [TextSpan]s, and read-aloud, which highlights a sentence by offset into the
/// same text.
///
/// When these were one private function, a highlight landing in the wrong place
/// would have been caused by the two paths disagreeing about where a paragraph
/// ended — with no error anywhere, just a highlight on the wrong words. Sharing
/// the tokenizer makes that class of bug impossible to write.
library;

import '../../core/reading/text_filter.dart';

/// One decoded run of inline HTML: a text run with its bold/italic state, or a
/// break marker.
class NovelToken {
  const NovelToken.text(this.text, {required this.bold, required this.italic})
    : isBreak = false,
      paragraphBreak = false,
      heading = false;

  const NovelToken.brk({
    required this.paragraphBreak,
    this.heading = false,
  }) : text = '',
       bold = false,
       italic = false,
       isBreak = true;

  final String text;
  final bool bold;
  final bool italic;
  final bool isBreak;

  /// Only meaningful when [isBreak] is true: a closed `</p>` (block boundary)
  /// versus a bare `<br>` (a soft line break inside a paragraph, e.g. a poem
  /// line, which must NOT start a new block).
  final bool paragraphBreak;

  /// Only meaningful on a block-ending break: the block that ended here was
  /// inside an `<h1>`–`<h6>`, so it is a heading rather than prose.
  final bool heading;
}

/// Walks HTML into a flat list of [NovelToken]s.
///
/// `<p>`/`<br>` become breaks, `<b>`/`<strong>` and `<i>`/`<em>` become styled
/// runs, and everything else — including `<script>`/`<style>` and their
/// contents — is stripped.
List<NovelToken> tokenizeNovelHtml(String html) {
  // `(?:</\1>|$)` rather than just `</\1>` so an unclosed <script>/<style> still
  // has its raw content stripped through to end-of-string instead of leaking
  // into the rendered chapter.
  final cleaned = html.replaceAll(
    RegExp(
      r'<(script|style)[^>]*>.*?(?:</\1>|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    '',
  );

  final tokens = <NovelToken>[];
  final buffer = StringBuffer();
  var bold = false;
  var italic = false;
  // Set by `<h1>`-`<h6>`, consumed by the next block-ending break. Most sources
  // emit a chapter title as a bare paragraph instead, which
  // [NovelTextLayout.isHeadingBlock] also catches; this covers the ones that do
  // use real heading tags.
  var inHeading = false;

  void flush() {
    if (buffer.isEmpty) return;
    tokens.add(NovelToken.text(buffer.toString(), bold: bold, italic: italic));
    buffer.clear();
  }

  final tagRe = RegExp(r'<[^>]*>');
  final headingOpen = RegExp(r'^<h[1-6][\s/>]');
  final headingClose = RegExp(r'^</h[1-6]');
  var last = 0;
  for (final m in tagRe.allMatches(cleaned)) {
    if (m.start > last) {
      buffer.write(unescapeNovelHtml(cleaned.substring(last, m.start)));
    }
    final tag = cleaned.substring(m.start, m.end).toLowerCase();
    if (headingOpen.hasMatch(tag)) {
      inHeading = true;
      // A heading is its own block. Without this it runs straight into the
      // following paragraph, so it can never be recognised as a heading — and
      // narration reads the title glued to the first line of the story.
      if (buffer.isNotEmpty) flush();
    } else if (tag.startsWith('</p') ||
        tag.startsWith('<br') ||
        headingClose.hasMatch(tag)) {
      final heading = inHeading;
      if (heading || headingClose.hasMatch(tag)) inHeading = false;
      flush();
      tokens.add(
        NovelToken.brk(
          paragraphBreak: !tag.startsWith('<br'),
          heading: heading,
        ),
      );
    } else if (tag.startsWith('<b') || tag.startsWith('<strong')) {
      flush();
      bold = true;
    } else if (tag.startsWith('</b') || tag.startsWith('</strong')) {
      flush();
      bold = false;
    } else if (tag.startsWith('<i') || tag.startsWith('<em')) {
      flush();
      italic = true;
    } else if (tag.startsWith('</i') || tag.startsWith('</em')) {
      flush();
      italic = false;
    }
    // Everything else (<p>, <div>, <span>, ...): stripped, no-op.
    last = m.end;
  }
  if (last < cleaned.length) {
    buffer.write(unescapeNovelHtml(cleaned.substring(last)));
  }
  flush();
  return tokens;
}

/// [tokens] back into HTML.
///
/// ### Why this exists
/// The chapter has to be cleaned in more places than the reader: read-aloud
/// rolls into the next chapter in the background, with the reader widget
/// already gone, and the *only* handle on that text is its HTML. Handing that
/// path a different representation — a sentence list, or a set of offsets —
/// would mean two implementations of "what does this chapter read like", and
/// the day they disagree the narrator and the page stop telling the same story.
///
/// So the cleaned text is turned back into HTML once, here, and everything
/// downstream tokenizes the same string. The markup is rebuilt rather than
/// patched, which is safe precisely because [tokenizeNovelHtml] already throws
/// away everything the reader cannot draw: what survives the round trip is the
/// text and its bold/italic state, the paragraph boundaries, the soft line
/// breaks, and whether a block was a heading.
///
/// A heading has to survive as a real `<h1>`: without one, a chapter titled
/// with a tag rather than as a bare first line is no longer recognisable as a
/// title, and narration reads the title out loud as the opening sentence of the
/// story.
String serializeNovelTokens(List<NovelToken> tokens) {
  final out = StringBuffer();
  final block = StringBuffer();
  var bold = false;
  var italic = false;

  void closeRuns() {
    if (italic) {
      block.write('</i>');
      italic = false;
    }
    if (bold) {
      block.write('</b>');
      bold = false;
    }
  }

  void applyRuns(NovelToken t) {
    if (bold == t.bold && italic == t.italic) return;
    // Closed and reopened wholesale rather than individually: a run that loses
    // bold but keeps italic sits *inside* the bold tag, and closing the outer
    // one while the inner stays open is not well-formed markup.
    closeRuns();
    if (t.bold) {
      block.write('<b>');
      bold = true;
    }
    if (t.italic) {
      block.write('<i>');
      italic = true;
    }
  }

  void flushBlock({required bool heading}) {
    closeRuns();
    if (block.isEmpty) return;
    out.write(heading ? '<h1>' : '<p>');
    out.write(block.toString());
    out.write(heading ? '</h1>' : '</p>');
    block.clear();
  }

  for (final t in tokens) {
    if (t.isBreak) {
      if (t.paragraphBreak) {
        flushBlock(heading: t.heading);
      } else {
        block.write('<br/>');
      }
      continue;
    }
    if (t.text.isEmpty) continue;
    applyRuns(t);
    // The token text is already entity-decoded, so it has to be re-escaped:
    // writing a raw `<` would be read as a tag by the next pass, and a chapter
    // with "<3" in it would lose the lot.
    block.write(
      t.text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;'),
    );
  }
  flushBlock(heading: false);
  return out.toString();
}

/// [html] with every span [engine] covers removed, as HTML.
///
/// The one entry point for cleaning a chapter: the reader, and the read-aloud
/// path that fetches the next chapter in the background, both go through it, so
/// there is exactly one answer to "what does this chapter say".
String filterNovelHtml(String html, TextFilterEngine engine) {
  if (engine.isEmpty) return html;
  return serializeNovelTokens(
    filterNovelTokens(tokenizeNovelHtml(html), engine),
  );
}

/// Cuts every span [engine] covers out of [tokens].
///
/// ### Why the tokens and not the text
/// The alternative is to strip the text and throw the styling away for anything
/// a rule touched, which is what Novery does because it keeps styled text and
/// plain text as two separate strings. Here the styled runs *are* the text, so a
/// rule that removes one clause out of a bolded line leaves the rest bolded, and
/// a rule that only ever touches a whole paragraph never costs the chapter its
/// italics. A token may be split into up to three sub-tokens, so this stays
/// exact: the concatenation of what comes out is character-for-character the
/// text the rules left behind, which is the invariant every offset in the
/// reader rests on.
///
/// ### Removed paragraphs leave nothing behind
/// A line the rules cover whole still has a paragraph break either side of it,
/// and keeping both turns one hidden ad into a visible gap in the page. A block
/// with nothing left in it takes its break with it, which is also why the
/// surviving paragraphs stay separate blocks rather than merging: the break
/// that *closed* the previous paragraph is what opens the next one.
///
/// ### An over-broad rule must not blank a chapter
/// If the rules would leave nothing at all, the original tokens are returned
/// unchanged. A filter that deletes prose is one typo away from deleting a
/// chapter, and an empty reader tells the user nothing about why, whereas the
/// unfiltered text — with a rule that turned out to be wrong — can be diagnosed.
List<NovelToken> filterNovelTokens(
  List<NovelToken> tokens,
  TextFilterEngine engine,
) {
  if (engine.isEmpty || tokens.isEmpty) return tokens;

  // The layout's own text, so the ranges the rules report are ranges into
  // exactly what [NovelTextLayout] would have built without this.
  final buffer = StringBuffer();
  final starts = <int>[];
  final lengths = <int>[];
  for (final t in tokens) {
    starts.add(buffer.length);
    if (t.isBreak) {
      buffer.write('\n');
      lengths.add(1);
    } else {
      buffer.write(t.text);
      lengths.add(t.text.length);
    }
  }
  final text = buffer.toString();
  final cuts = engine.findFilteredRanges(text);
  if (cuts.isEmpty) return tokens;

  // Which blocks are left with nothing, so they can take their break with them.
  final blockStart = <int>[];
  final blockEnd = <int>[];
  var blockFrom = 0;
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (!t.isBreak || !t.paragraphBreak) continue;
    if (starts[i] > blockFrom) {
      blockStart.add(blockFrom);
      blockEnd.add(starts[i]);
    }
    blockFrom = starts[i] + 1;
  }
  if (text.length > blockFrom) {
    blockStart.add(blockFrom);
    blockEnd.add(text.length);
  }
  final dead = <bool>[
    for (var b = 0; b < blockStart.length; b++)
      !_blockSurvives(text, blockStart[b], blockEnd[b], cuts),
  ];

  final out = <NovelToken>[];
  var block = 0;
  var cutIndex = 0;
  var justCut = false;
  var lastKept = '';

  /// Emits `[from, to)` of [t], both of which are offsets into the *chapter*
  /// text — the same space the cuts are reported in.
  ///
  /// Which is why [tokenStart] is passed in rather than assumed: a token's own
  /// text starts wherever the chapter does not, and slicing it with a chapter
  /// offset cuts the wrong words out of every token after the first.
  void emit(NovelToken t, int tokenStart, int from, int to) {
    if (to <= from) return;
    final start = from - tokenStart;
    final end = to - tokenStart;
    if (end <= start) return;
    final part = (start == 0 && end == t.text.length)
        ? t.text
        : t.text.substring(start, end);
    // Absorbing the separators beside a cut is what stops "start , TWO end",
    // but it can also glue two words together, so put one space back when the
    // cut landed between two word characters.
    if (justCut &&
        lastKept.isNotEmpty &&
        !_isSpaceChar(lastKept) &&
        _isWordChar(part[0])) {
      out.add(NovelToken.text(' $part', bold: t.bold, italic: t.italic));
    } else {
      out.add(NovelToken.text(part, bold: t.bold, italic: t.italic));
    }
    lastKept = part[part.length - 1];
    justCut = false;
  }

  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.isBreak) {
      if (t.paragraphBreak) {
        if (block < dead.length && !dead[block]) out.add(t);
        block++;
      } else if (block >= dead.length || !dead[block]) {
        // A `<br>` belongs to the block it sits inside, so it goes when that
        // block does, or the removed paragraph's soft line breaks survive as
        // blank lines at the top of the next one.
        out.add(t);
      }
      lastKept = '';
      justCut = false;
      continue;
    }
    if (block < dead.length && dead[block]) continue;

    final tokenStart = starts[i];
    final tokenEnd = tokenStart + lengths[i];
    // Cuts that ended before this token still cut: this token starts after
    // removed text, so the re-space rule has to know about it.
    while (cutIndex < cuts.length && cuts[cutIndex].end <= tokenStart) {
      cutIndex++;
      justCut = true;
    }
    var from = tokenStart;
    while (cutIndex < cuts.length && cuts[cutIndex].start < tokenEnd) {
      final cut = cuts[cutIndex];
      emit(t, tokenStart, from, cut.start < from ? from : cut.start);
      from = cut.end < from ? from : cut.end;
      cutIndex++;
      justCut = true;
    }
    emit(t, tokenStart, from, tokenEnd);
  }

  // Nothing survived: hand the chapter back untouched rather than showing a
  // blank page. See the note on the function.
  var kept = 0;
  for (final t in out) {
    if (!t.isBreak && t.text.trim().isNotEmpty) kept += t.text.length;
  }
  if (kept == 0) return tokens;
  return out;
}

/// Whether any non-whitespace character of `text[start, end)` survives [cuts].
bool _blockSurvives(String text, int start, int end, List<TextCut> cuts) {
  var pos = start;
  for (final cut in cuts) {
    if (cut.end <= pos) continue;
    if (cut.start >= end) break;
    if (cut.start > pos && text.substring(pos, cut.start).trim().isNotEmpty) {
      return true;
    }
    pos = cut.end > pos ? cut.end : pos;
  }
  return pos < end && text.substring(pos, end).trim().isNotEmpty;
}

final RegExp _wordCharRe = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWordChar(String ch) => _wordCharRe.hasMatch(ch);

bool _isSpaceChar(String ch) => ch.trim().isEmpty;

/// A half-open character range inside a token's text: `[start, end)`.
class NovelTextRange {
  const NovelTextRange(this.token, this.start, this.end);

  /// Index into [NovelTextLayout.tokens].
  final int token;

  /// Offset within that token's text.
  final int start;
  final int end;

  int get length => end - start;

  @override
  String toString() => 'NovelTextRange(token: $token, $start..$end)';
}

/// A paragraph of the rendered chapter: a half-open range in [NovelTextLayout.text].
class NovelBlockRange {
  const NovelBlockRange({
    required this.index,
    required this.start,
    required this.end,
    required this.taggedHeading,
  });

  final int index;
  final int start;
  final int end;

  /// The block was inside an `<h1>`–`<h6>`.
  final bool taggedHeading;

  /// The block's own text, trimmed.
  String textOf(NovelTextLayout layout) =>
      layout.text.substring(start, end).trim();
}

/// The rendered chapter text plus the mapping from character offsets back to the
/// tokens they came from.
///
/// [plain] is exactly what the paged reader lays out, so an offset in it can be
/// turned into a highlighted run with [rangesFor].
class NovelTextLayout {
  NovelTextLayout(this.tokens)
    : plain = StringBuffer() {
    for (final t in tokens) {
      if (t.isBreak) {
        // Matches what the renderer emits for a break, so offsets agree with
        // the paginated text.
        _tokenStart.add(_length);
        _length += 1;
        plain.write('\n');
      } else {
        _tokenStart.add(_length);
        _length += t.text.length;
        plain.write(t.text);
      }
    }
  }

  /// Convenience constructor for the common case of going straight from HTML.
  factory NovelTextLayout.fromHtml(String html) =>
      NovelTextLayout(tokenizeNovelHtml(html));

  final List<NovelToken> tokens;

  /// The rendered text. Character offsets in here are what read-aloud speaks
  /// and what the highlighter decorates.
  final StringBuffer plain;

  /// Total characters written so far, and the start offset of each token.
  ///
  /// Not `late`: the constructor body accumulates into it as it walks the
  /// tokens, so it has to start at zero rather than await first assignment.
  int _length = 0;
  final List<int> _tokenStart = [];

  String get text => plain.toString();

  /// Every paragraph, as a range in [text].
  ///
  /// Split on `</p>` boundaries only, so a `<br>` line break stays inside its
  /// paragraph — a poem or an address is one block, and cutting there would
  /// shred a verse into separate sentences.
  late final List<NovelBlockRange> blocks = _buildBlocks();

  List<NovelBlockRange> _buildBlocks() {
    final out = <NovelBlockRange>[];
    var start = 0;
    var lastHeading = false;
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (!t.isBreak || !t.paragraphBreak) continue;
      // The break token's own newline is not part of the block it closes.
      final end = _tokenStart[i];
      if (end > start) {
        out.add(
          NovelBlockRange(
            index: out.length,
            start: start,
            end: end,
            // The flag describes the block this break CLOSES. Reading it as
            // "whatever the previous break said" shifted every heading flag on
            // to the following block, so an <h1> title was not recognised and
            // the paragraph after it was.
            taggedHeading: t.heading,
          ),
        );
      }
      start = _tokenStart[i] + 1;
      lastHeading = t.heading;
    }
    if (_length > start) {
      out.add(
        NovelBlockRange(
          index: out.length,
          start: start,
          end: _length,
          taggedHeading: lastHeading,
        ),
      );
    }
    return out;
  }

  /// Longest a block can be and still be treated as a title rather than prose.
  static const int _headingMaxChars = 80;

  /// Whether block [index] is a chapter title rather than story text.
  ///
  /// Two signals, because neither is sufficient alone. An `<h1>`-`<h6>` tag is
  /// exact but most sources emit the title as a plain paragraph, and a
  /// length-and-punctuation heuristic catches those — but only for the *first*
  /// block, because a short unpunctuated line in the middle of a chapter is
  /// ordinary prose (a "Not now." aside, a section divider) and must still be
  /// read aloud.
  ///
  /// Two further guards, each closing a real false positive. A first block
  /// containing a `<br>` is a poem or an address, not a title — dropping it
  /// would silently delete the opening lines of the chapter. That guard is also
  /// what lets a chapter whose *only* block is a short unpunctuated line be
  /// treated as a title, which is the common bare "Chapter 1" case.
  bool isHeadingBlock(int index) {
    if (index < 0 || index >= blocks.length) return false;
    final b = blocks[index];
    if (b.taggedHeading) return true;
    if (index != 0) return false;
    if (text.substring(b.start, b.end).contains('\n')) return false;
    final body = b.textOf(this);
    if (body.isEmpty || body.length > _headingMaxChars) return false;
    // Prose ends sentences. A title that does not is a title.
    return !RegExp(r'[.!?]').hasMatch(body);
  }

  /// Which block (paragraph) the character at [offset] falls in.
  ///
  /// Counts `</p>` breaks, so block 0 is the text before the first paragraph
  /// boundary. Needed to decide what to keep on screen while narrating.
  int blockAt(int offset) {
    var block = 0;
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (!t.isBreak) continue;
      if (!t.paragraphBreak) continue;
      if (offset >= _tokenStart[i]) block++;
    }
    return block;
  }

  /// Splits `[start, end)` of [text] into the token ranges that cover it.
  ///
  /// A sentence routinely spans several tokens — `<b>He said</b> loudly.` is two
  /// — and can also straddle a styled run's edge, so this returns a list rather
  /// than a single range. Out-of-range and inverted input yields an empty list
  /// instead of throwing: a highlight is decoration, and decoration must never
  /// be the thing that crashes a reader mid-chapter.
  List<NovelTextRange> rangesFor(int start, int end) {
    final out = <NovelTextRange>[];
    if (end <= start) return out;
    final lo = start < 0 ? 0 : start;
    final hi = end > _length ? _length : end;

    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      final tokenStart = _tokenStart[i];
      final tokenEnd = t.isBreak ? tokenStart + 1 : tokenStart + t.text.length;
      if (tokenEnd <= lo) continue;
      if (tokenStart >= hi) break;

      final from = lo > tokenStart ? lo : tokenStart;
      final to = hi < tokenEnd ? hi : tokenEnd;
      if (to > from) out.add(NovelTextRange(i, from - tokenStart, to - tokenStart));
    }
    return out;
  }

  /// Total rendered length.
  int get length => _length;

  /// Start offset of token [index] in [text].
  ///
  /// Exposed so a renderer that builds its own spans cannot invent a different
  /// idea of where a token begins. The scroll reader builds one `Text.rich` per
  /// block and has to know which tokens belong to it; deriving that from the
  /// block's own range and its own token walk is exactly the kind of second
  /// implementation that drifts from this one and puts a highlight on the wrong
  /// words.
  int tokenStart(int index) => _tokenStart[index];

  /// Plain-text length token [index] contributes: its text, or one character
  /// for a break.
  int tokenLength(int index) {
    final t = tokens[index];
    return t.isBreak ? 1 : t.text.length;
  }
}

const Map<String, String> _htmlEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
};

/// Numeric and named entity decoding, including decimal and hex references
/// (`&#233;` / `&#xe9;`) which a source emits often enough to matter.
///
/// Anything unrecognised — an unknown name, or a numeric code outside the
/// valid Unicode range — is left exactly as it was written, delimiters and all,
/// so a malformed entity shows up as the source's own text rather than silently
/// losing a character.
String unescapeNovelHtml(String input) => input.replaceAllMapped(
  RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);'),
  (m) {
    final ref = m.group(1)!;
    // The full match, not `ref`: a fallback must reproduce the original
    // `&#99999999;` and not a headless `#99999999`.
    final raw = m.group(0)!;
    if (ref.startsWith('#x') || ref.startsWith('#X')) {
      return _charOrRaw(int.tryParse(ref.substring(2), radix: 16), raw);
    }
    if (ref.startsWith('#')) {
      return _charOrRaw(int.tryParse(ref.substring(1)), raw);
    }
    return _htmlEntities[ref] ?? raw;
  },
);

String _charOrRaw(int? code, String raw) {
  if (code == null || code < 0 || code > 0x10FFFF) return raw;
  return String.fromCharCode(code);
}
