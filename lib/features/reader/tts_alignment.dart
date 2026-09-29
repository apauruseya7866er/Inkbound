import 'package:flutter/material.dart';
import 'package:watch_app/core/reading/tts/narration_filter.dart';
import 'package:watch_app/core/reading/tts/sentence_parser.dart';

import 'novel_html.dart';

/// Turns a chapter's rendered text into read-aloud sentences whose offsets line
/// up with what the reader draws.
///
/// Lives in `features/reader` rather than in the parser because it is the seam
/// between two representations: the parser knows about sentences, the reader
/// knows about tokens and spans, and only here do the two meet. Keeping the
/// mapping out of both is what stops a highlight from drifting onto the wrong
/// words after an unrelated change to either side.
class TtsAlignedChapter {
  const TtsAlignedChapter({
    required this.layout,
    required this.sentences,
  });

  final NovelTextLayout layout;

  /// One entry per sentence, in reading order. Each [TtsSentence]'s
  /// `startIndex`/`endIndex` are offsets into [NovelTextLayout.text].
  final List<TtsSentence> sentences;

  int get total => sentences.length;
  bool get isEmpty => sentences.isEmpty;

  TtsSentence? at(int i) =>
      (i >= 0 && i < sentences.length) ? sentences[i] : null;

  /// The half-open range of the sentence at [i], or null when out of range.
  ({int start, int end})? rangeAt(int i) {
    final s = at(i);
    return s == null ? null : (start: s.startIndex, end: s.endIndex);
  }
}

/// Segments [layout]'s text into sentences, one block at a time, skipping
/// headings.
///
/// ### Per block, not per chapter
/// Segmented a block at a time rather than over the whole chapter text. A
/// sentence that runs across a paragraph boundary is a real failure, not a
/// cosmetic one: with `<p>Chapter 2: Comparison</p><p>Funny how much…</p>` the
/// colon splits after "Chapter 2", so the next sentence began at "Comparison"
/// and ran on into the first paragraph — narration opened by reading the
/// chapter title, glued to the first line of the story.
///
/// It also makes this path agree with the speech-only path used when narration
/// rolls into the next chapter, which already segmented per block. The two
/// counting sentences differently meant the same chapter could segment two
/// different ways depending on how you arrived at it.
///
/// ### Headings and notes are not spoken
/// A chapter title is metadata, not prose. Reading "Chapter one" before every
/// chapter is the kind of thing that makes a narrator sound broken, so heading
/// blocks are dropped from the spoken list entirely rather than being spoken or
/// attached to the sentence after them. The same goes for a block that is an
/// author's note or a translator's bracket: a note runs to several sentences,
/// so it has to be judged as a block or the rest of it still gets read out.
///
/// Position comes from the *non-heading* blocks. A chapter is usually title
/// then note then story, so counting the heading as the first block would put
/// the note second and out of reach of the note rules.
TtsAlignedChapter alignChapter(NovelTextLayout layout) {
  final out = <TtsSentence>[];

  final prose = <NovelBlockRange>[];
  for (final block in layout.blocks) {
    if (!layout.isHeadingBlock(block.index)) prose.add(block);
  }

  for (var i = 0; i < prose.length; i++) {
    final block = prose[i];
    // The block's own slice, so offsets stay absolute and the highlighter keeps
    // working. The trailing newline that separates blocks is left to the block
    // before it.
    final slice = layout.text.substring(block.start, block.end);
    if (NarrationFilter.skipBlock(slice, blockIndex: i, blockCount: prose.length)) {
      continue;
    }
    for (final s in SentenceParser.parseRaw(slice)) {
      out.add(
        TtsSentence(
          text: s.text,
          // Shift into chapter coordinates: a sentence is located in the whole
          // chapter, not in the block it was found in.
          startIndex: s.startIndex + block.start,
          endIndex: s.endIndex + block.start,
          index: out.length,
          pauseAfterMs: s.pauseAfterMs,
          blockIndex: block.index,
        ),
      );
    }
  }

  return TtsAlignedChapter(layout: layout, sentences: out);
}

/// The spans for one block of [layout], with an optional highlighted range.
///
/// ### Why scroll mode builds its own spans instead of using `HtmlWidget`
///
/// The scrolling reader hands its chapter straight to `HtmlWidget`, which owns
/// the text — and a widget that owns the text cannot be handed a decorated copy
/// of it. Reikai solves this by rendering the chapter in a WebView and toggling
/// a CSS class on the DOM element. That is a sound approach and much simpler
/// than a source map: it highlights whole paragraphs, because a DOM element is
/// the smallest thing a CSS class can go on.
///
/// We already hold something finer than that — a character range for the exact
/// sentence — so the alternative here was to map plain-text offsets back into
/// HTML source positions and re-inject a styled span on every sentence. That
/// map has to survive `&amp;`-style entities, and getting it subtly wrong puts
/// a highlight on the wrong words, which is worse than no highlight at all.
///
/// So this builds the block's spans from the *same* [NovelTextLayout] the
/// sentences were segmented from, and decorates with [_applyRange] — the
/// function the paged path already uses and that the offset tests already
/// cover. One token walk, one source of truth, exact sentence granularity.
List<InlineSpan> novelBlockSpans(
  NovelTextLayout layout,
  int blockIndex, {
  required TextStyle base,
  int? highlightStart,
  int? highlightEnd,
  TextStyle? highlight,
}) {
  final blocks = layout.blocks;
  if (blockIndex < 0 || blockIndex >= blocks.length) return const [];
  final block = blocks[blockIndex];

  final spans = <InlineSpan>[];
  for (var i = 0; i < layout.tokens.length; i++) {
    final tokenStart = layout.tokenStart(i);
    if (tokenStart >= block.end) break;
    final t = layout.tokens[i];
    final tokenEnd = tokenStart + layout.tokenLength(i);
    if (tokenEnd <= block.start) continue;
    if (t.isBreak) {
      // A `<br>` inside the block: a soft line break, kept as a newline.
      spans.add(const TextSpan(text: '\n'));
      continue;
    }
    // A token can straddle a block edge; clip so the block renders only its own
    // characters. That is what keeps the block's plain text equal to the block's
    // slice of the layout text, which is the invariant the offsets rest on.
    final from = block.start > tokenStart ? block.start - tokenStart : 0;
    final to =
        block.end < tokenEnd ? block.end - tokenStart : t.text.length;
    if (to <= from) continue;
    spans.add(
      TextSpan(
        text: t.text.substring(from, to),
        style: base.copyWith(
          fontWeight: t.bold ? FontWeight.bold : null,
          fontStyle: t.italic ? FontStyle.italic : null,
        ),
      ),
    );
  }

  if (highlight == null || highlightStart == null || highlightEnd == null) {
    return spans;
  }
  final from = highlightStart < block.start ? block.start : highlightStart;
  final to = highlightEnd > block.end ? block.end : highlightEnd;
  if (to <= from) return spans;

  return [
    _applyRange(
      TextSpan(style: base, children: spans),
      from - block.start,
      to - block.start,
      highlight,
      0,
    ),
  ];
}

/// The block of [layout] containing character offset [offset], or null.
int? blockIndexForOffset(NovelTextLayout layout, int offset) {
  if (offset < 0 || offset >= layout.length) return null;
  for (final b in layout.blocks) {
    if (offset >= b.start && offset < b.end) return b.index;
  }
  return null;
}

/// The page holding the start of the chapter range `[start, end)`, or null when
/// the range falls outside the page list.
///
/// This is what makes read-aloud usable in paged mode without the user touching
/// anything: a spoken sentence that has moved onto the next page is invisible
/// until the page turns, so the highlight is happening somewhere the reader
/// cannot see. Turning to the sentence keeps reading along with the voice.
///
/// Returns null rather than clamping, so the caller can tell "this sentence is
/// not on any page" (misaligned input, empty pagination) apart from "it is on
/// the page we are already showing", and leave the reader alone in both cases.
int? pageIndexForRange(List<TextSpan> pages, int start, int end) {
  if (end <= start) return null;
  var pageStart = 0;
  for (var i = 0; i < pages.length; i++) {
    final pageEnd = pageStart + pages[i].toPlainText().length;
    if (start >= pageStart && start < pageEnd) {
      // A sentence running past the page edge still belongs to the page it
      // *starts* on: turning to where it began is the least jarring, and the
      // next sentence will move the page again.
      return i;
    }
    if (start < pageStart) return null; // gap: offset precedes these pages
    pageStart = pageEnd;
  }
  return null;
}

/// Repaints `[start, end)` (offsets into the chapter's text) across the page
/// spans produced by `paginateSpans`.
///
/// ### Why this does not re-paginate
/// Pages are laid out once and cached; measuring a whole chapter again on every
/// sentence — several times a minute — would stutter the very page the user is
/// trying to read along with. A background colour changes no metrics, so the
/// existing page boundaries stay valid and the highlight is applied as a
/// decoration when the page is built for display.
///
/// ### Page offsets
/// `paginateSpans` returns contiguous, non-overlapping slices, so page *n*'s
/// global range starts exactly where page *n-1* ended. That is what lets a
/// chapter-level offset be resolved to a page without the paginator having to
/// report anything new.
List<TextSpan> highlightPages(
  List<TextSpan> pages,
  int chapterStart,
  int chapterEnd, {
  required TextStyle highlight,
}) {
  if (chapterEnd <= chapterStart) return pages;

  final out = <TextSpan>[];
  var pageStart = 0;
  for (final page in pages) {
    final length = page.toPlainText().length;
    final pageEnd = pageStart + length;
    final from = chapterStart > pageStart ? chapterStart : pageStart;
    final to = chapterEnd < pageEnd ? chapterEnd : pageEnd;

    out.add(
      to > from
          ? _applyRange(page, from - pageStart, to - pageStart, highlight, 0)
          : page,
    );
    pageStart = pageEnd;
  }
  return out;
}

/// Splits the span tree so `[start, end)` — page-relative — carries
/// [highlight].
///
/// Recursive rather than a flat re-slice because a page span is a tree of styled
/// runs: a bold run inside the highlighted range must stay bold *and* gain the
/// background, which merging styles top-down does. [pageOffset] is how much text
/// precedes this subtree within the page, so each descendant can work in
/// absolute terms.
TextSpan _applyRange(
  TextSpan span,
  int start,
  int end,
  TextStyle highlight,
  int pageOffset,
) {
  final children = span.children;
  final text = span.text;

  if (text != null && text.isNotEmpty) {
    final from = (start - pageOffset).clamp(0, text.length);
    final to = (end - pageOffset).clamp(0, text.length);
    if (to <= from) return span;
    final base = span.style;
    return TextSpan(
      style: base,
      children: [
        if (from > 0) TextSpan(text: text.substring(0, from), style: base),
        TextSpan(
          text: text.substring(from, to),
          style: base == null ? highlight : base.merge(highlight),
        ),
        if (to < text.length)
          TextSpan(text: text.substring(to), style: base),
      ],
    );
  }

  if (children == null || children.isEmpty) return span;

  final out = <InlineSpan>[];
  var consumed = pageOffset;
  for (final child in children) {
    // A non-TextSpan (a WidgetSpan from paragraph spacing) carries no offsets;
    // it is passed through untouched, and the text accounting simply skips it.
    if (child is! TextSpan) {
      out.add(child);
      continue;
    }
    out.add(_applyRange(child, start, end, highlight, consumed));
    consumed += child.toPlainText().length;
  }
  return TextSpan(style: span.style, children: out);
}
