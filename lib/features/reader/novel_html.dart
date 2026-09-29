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
