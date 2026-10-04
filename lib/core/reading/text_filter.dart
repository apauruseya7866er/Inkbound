/// Global regex text cleanup: strips the ads, donation pleas and injected
/// footers a source bolts onto a chapter, from the page *and* from read-aloud.
///
/// ### Why one engine for both
/// A rule that only suppressed a sentence in the speech queue would still leave
/// the text on screen, and a rule that only cut the page would still let the
/// narrator read "please support me on patreon" out loud. Both are the same
/// complaint, so the rules live in one place and the chapter is cleaned before
/// it becomes either a layout or a sentence list.
///
/// ### Ported from Novery, deliberately
/// `TextFilterEngine` is a straight port of Novery's
/// `util/TextFilterEngine.kt`, including its two non-obvious behaviours, because
/// both were found by looking at real injected text:
///
///  * **Rules are matched per line as well as against the whole string.** A
///    line-anchored rule like `^\s*join\s+our\s+discord.*` only means anything
///    per line — matched against the whole chapter, `^` is the start of the
///    chapter and the rule would fire on the first ad anywhere and swallow the
///    rest of the page with it.
///  * **A cut absorbs the separators around it.** Removing "ONE" from
///    "start ONE, TWO end" naively leaves "start , TWO end" with an orphaned
///    comma still in the prose. Growing each range over the whitespace and
///    punctuation beside it is what stops a rule from leaving debris.
///
/// Deliberately *not* ported: Novery replaces a cut block's styled text with
/// plain text, because it holds styling and plain text separately. We cut the
/// styled token stream itself (see `filterNovelTokens` in
/// `features/reader/novel_html.dart`), so a rule that removes one clause of a
/// bolded line leaves the rest bolded.
library;

import 'dart:convert';

/// One rule for removing text: a regular expression, or a plain literal.
class TextFilterRule {
  const TextFilterRule({
    required this.id,
    required this.pattern,
    this.isRegex = true,
    this.isEnabled = true,
    this.isBuiltin = false,
    required this.label,
  });

  /// Stable identity, so a rule can be switched off or deleted without the
  /// settings screen having to match on its pattern text.
  final String id;
  final String pattern;
  final bool isRegex;

  final bool isEnabled;
  final bool isBuiltin;
  final String label;

  /// Whether this is one of the rules that ship enabled, as opposed to a
  /// sentence the user hid or a pattern they typed.
  bool get isCustom => !isBuiltin;

  TextFilterRule copyWith({bool? isEnabled}) => TextFilterRule(
    id: id,
    pattern: pattern,
    isRegex: isRegex,
    isEnabled: isEnabled ?? this.isEnabled,
    isBuiltin: isBuiltin,
    label: label,
  );

  /// Persisted as a plain map, and the whole set as one JSON string, so a new
  /// field on a rule cannot leave a half-readable entry behind in an old
  /// install: an entry that does not parse is dropped, not half-applied.
  Map<String, dynamic> toMap() => {
    'id': id,
    'pattern': pattern,
    'isRegex': isRegex,
    'isEnabled': isEnabled,
    'label': label,
  };

  static TextFilterRule? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final pattern = (raw['pattern'] ?? '').toString().trim();
    if (pattern.isEmpty) return null;
    final id = (raw['id'] ?? '').toString();
    if (id.isEmpty) return null;
    return TextFilterRule(
      id: id,
      pattern: pattern,
      isRegex: raw['isRegex'] != false,
      isEnabled: raw['isEnabled'] != false,
      label: (raw['label'] ?? pattern).toString(),
    );
  }

  /// The rule created by hiding a sentence in the reader.
  ///
  /// Word-bounded rather than line-anchored. The long press reports the
  /// *sentence* under the finger, and a sentence is rarely the whole line —
  /// injected text routinely arrives with two of them run together on one line,
  /// and the sentence you tapped was the part in the middle. A `^…$` rule could
  /// only ever match when the line was exactly that sentence, so hiding one out
  /// of two silently did nothing: the rule was saved, the re-filter ran, and the
  /// text stayed until the next launch.
  ///
  /// The lookarounds keep it from cutting mid-word (`saw` must not match inside
  /// `sawtooth`) without including the neighbouring characters in the cut, and
  /// the sentence is escaped because it is prose: brackets, dots and everything
  /// else a regex would read as syntax.
  static TextFilterRule hiddenSentence(
    String sentence, {
    required String id,
    String? label,
  }) {
    final trimmed = sentence.trim();
    final short = trimmed.length > 28
        ? '${trimmed.substring(0, 28)}…'
        : trimmed;
    return TextFilterRule(
      id: id,
      pattern: '(?<![\\w])${RegExp.escape(trimmed)}(?![\\w])',
      isRegex: true,
      label: label ?? 'Hidden: $short',
    );
  }
}

/// A half-open character range `[start, end)` to remove.
class TextCut {
  const TextCut(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is TextCut && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TextCut($start..$end)';
}

/// Compiled, immutable view of a rule set.
///
/// Built once per chapter and reused for every block of it: compiling a dozen
/// regexes is cheap, doing it once per sentence is not, and the rules cannot
/// change underneath a chapter that is already laid out.
class TextFilterEngine {
  TextFilterEngine(List<TextFilterRule> rules) {
    for (final rule in rules) {
      if (!rule.isEnabled) continue;
      if (rule.isRegex) {
        try {
          _regexes.add(
            // Case-insensitive throughout: injected text is inconsistent about
            // capitalisation ("Support me", "SUPPORT ME") and a rule that
            // misses half of them is worse than no rule at all.
            _Compiled(
              rule,
              // `multiLine` is what makes `^` and `$` mean "this line" instead
              // of "this chapter", and it is the whole reason the built-ins are
              // line-anchored: a footer rule matched against the chapter as one
              // string would fire on the first ad anywhere and take the rest of
              // the page with it. Dart's `allMatches(string, start)` does *not*
              // re-anchor `^` at `start`, so scanning line by line instead
              // would silently match nothing — the anchors have to be the
              // regex's own.
              RegExp(rule.pattern, caseSensitive: false, multiLine: true),
            ),
          );
        } on FormatException {
          // A rule the user typed wrong is skipped, never fatal. Losing one
          // pattern is recoverable; taking the whole filter set down with it
          // would silently bring every ad back.
        }
      } else if (rule.pattern.isNotEmpty) {
        _literals.add(_Compiled(rule, null, rule.pattern.toLowerCase()));
      }
    }
  }

  static final List<RegExp> _seps = [
    RegExp(r'[ \t\u00A0\u2007\u202F]+'),
    RegExp(r' *\n *'),
    RegExp(r'\n{2,}'),
  ];

  final List<_Compiled> _regexes = [];
  final List<_Compiled> _literals = [];

  /// Nothing to strip — the common case for a source with clean chapters, and
  /// worth checking so the chapter is handed straight back untouched.
  bool get isEmpty => _regexes.isEmpty && _literals.isEmpty;

  /// Half-open ranges of [text] covered by any rule, merged, sorted and grown
  /// over the separators beside them.
  List<TextCut> findFilteredRanges(String text) {
    if (isEmpty || text.trim().isEmpty) return const [];

    // One pass per rule over the whole text. The per-line pass this replaced is
    // what `multiLine` buys: `^`/`$` already mean "start/end of a line", and a
    // pattern with no anchors behaves the same either way.
    final cuts = <TextCut>[];
    for (final rule in _regexes) {
      for (final m in rule.regex!.allMatches(text)) {
        cuts.add(TextCut(m.start, m.end));
      }
    }
    for (final rule in _literals) {
      _collectLiteral(rule, text, cuts);
    }

    if (cuts.isEmpty) return const [];
    cuts.sort((a, b) => a.start.compareTo(b.start));
    return _mergeAndAbsorb(text, cuts);
  }

  void _collectLiteral(_Compiled rule, String text, List<TextCut> out) {
    // Lower-cased once rather than once per rule: a scan that lower-cased inside
    // the rule loop would re-allocate a copy of the chapter for every rule in
    // the set.
    final haystack = text.toLowerCase();
    final needle = rule.literal!;
    var i = haystack.indexOf(needle);
    while (i >= 0) {
      out.add(TextCut(i, i + needle.length));
      i = haystack.indexOf(needle, i + 1);
    }
  }

  /// True when any rule covers part or all of [text]. Cheap enough to call once
  /// per block, which is how a whole block is dropped rather than trimmed.
  bool isFiltered(String text) => findFilteredRanges(text).isNotEmpty;

  /// [text] with every covered span removed, or null when nothing matched.
  ///
  /// Null rather than the input unchanged, so a caller can keep the original
  /// styling for text no rule touched — that is the difference between a
  /// chapter that reads exactly as before and a whole chapter flattened to
  /// plain text because one line in it had an ad on it.
  String? stripFiltered(String text) {
    if (text.trim().isEmpty) return null;
    final cuts = findFilteredRanges(text);
    if (cuts.isEmpty) return null;

    final out = StringBuffer();
    var cursor = 0;
    var justCut = false;
    var lastKept = '';

    void keep(int from, int to) {
      if (from >= to) return;
      // Absorbing the separators around a cut is what stops "start , TWO end",
      // but it can also glue two words together. Put one space back whenever a
      // cut landed between two word characters.
      if (justCut &&
          lastKept.isNotEmpty &&
          !_isSpace(lastKept) &&
          _isWord(text[from])) {
        out.write(' ');
      }
      out.write(text.substring(from, to));
      lastKept = text[to - 1];
      justCut = false;
    }

    for (final cut in cuts) {
      final from = cut.start < cursor ? cursor : cut.start;
      final to = cut.end < from ? from : cut.end;
      keep(cursor, from);
      cursor = to;
      justCut = true;
    }
    keep(cursor, text.length);
    final tidied = _tidy(out.toString());
    // A paragraph that was nothing but an ad can be left holding the quote
    // marks and dashes that surrounded it — `""`, `---` — which is debris
    // dressed up as content. Nothing here is prose any more, so nothing stays.
    if (!_wordChar.hasMatch(tidied)) return '';
    return tidied;
  }

  /// Merge overlapping and touching ranges, then grow each one over the
  /// separator characters around it.
  static List<TextCut> _mergeAndAbsorb(String text, List<TextCut> cuts) {
    final merged = <TextCut>[];
    for (final cut in cuts) {
      final last = merged.isEmpty ? null : merged.last;
      if (last != null && cut.start <= last.end) {
        if (cut.end > last.end) {
          merged[merged.length - 1] = TextCut(last.start, cut.end);
        }
      } else {
        merged.add(cut);
      }
    }

    final grown = <TextCut>[];
    for (final cut in merged) {
      var start = cut.start;
      var end = cut.end;
      while (start > 0 && _isSeparator(text[start - 1])) {
        start--;
      }
      while (end < text.length && _isSeparator(text[end])) {
        end++;
      }
      final last = grown.isEmpty ? null : grown.last;
      if (last != null && start <= last.end) {
        grown[grown.length - 1] = TextCut(
          last.start,
          end > last.end ? end : last.end,
        );
      } else {
        grown.add(TextCut(start, end));
      }
    }
    return grown;
  }

  /// Characters a cut may absorb: the punctuation and spacing that sits
  /// between the words either side of an aside.
  ///
  /// Sentence terminators are deliberately *not* in it. Trimming one off the end
  /// of the result took the full stop off the last sentence of the chapter, and
  /// absorbing one off the front of a cut deleted the punctuation belonging to
  /// the sentence *before* the ad: "He said. Support me." came out as "He said".
  /// What is left to absorb is exactly the debris Novery's engine absorbs, and
  /// the double space a cut leaves is collapsed by [_tidy] anyway.
  ///
  /// A newline is excluded for a different reason, and that one matters most.
  /// Growing a cut across a line boundary would swallow the paragraph break
  /// with it, and one hidden ad at the top of a chapter would join the
  /// paragraph above it to the one below — the two sentences still readable, now
  /// run together as one. Absorb inside a line; stop at the edge of it.
  static bool _isSeparator(String ch) =>
      !_isNewline(ch) && (_isSpace(ch) || _edgeSeps.contains(ch));

  static bool _isNewline(String ch) => ch == '\n' || ch == '\r';

  static const String _edgeSeps = ' \t,;:–—|/·-';

  static bool _isSpace(String ch) => _spaceCodes.contains(ch.codeUnitAt(0));

  static const Set<int> _spaceCodes = {
    0x20,
    0x09,
    0x0A,
    0x0D,
    0x00A0,
    0x2007,
    0x202F,
    0x200B,
    0x3000,
  };

  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  static bool _isWord(String ch) => _wordChar.hasMatch(ch);

  /// Tidies the seams left by a cut: collapsed whitespace, no orphaned
  /// separator at either edge, and a dangling quote dropped when unbalanced.
  static String _tidy(String input) {
    var s = input.replaceAll(_seps[0], ' ');
    s = s.replaceAll(_seps[1], '\n');
    s = s.replaceAll(_seps[2], '\n');
    s = _dropEmptyQuotes(s);
    s = _trimEdges(s);

    var changed = true;
    while (changed && s.isNotEmpty) {
      changed = false;
      final before = s;
      s = _dropEmptyQuotes(_trimEdges(s));

      final lead = s[0];
      if (_quotes.contains(lead) && _count(s, lead).isOdd) {
        s = _trimEdges(s.substring(1));
      }
      if (s.isNotEmpty) {
        final tail = s[s.length - 1];
        if (_quotes.contains(tail) && _count(s, tail).isOdd) {
          s = _trimEdges(s.substring(0, s.length - 1));
        }
      }
      if (s != before) changed = true;
    }
    return s;
  }

  /// Removes quote marks with nothing between them.
  ///
  /// `""` is what is left when a cut took out everything a pair of quotes was
  /// holding — and unlike a single stray quote it is *balanced*, so the
  /// unbalanced-quote pass below walks straight past it. It is punctuation
  /// pretending to be a sentence, and the page should not show it.
  static const List<String> _emptyQuotePairs = [
    '""',
    "''",
    '“”',
    '‘’',
    '「」',
    '『』',
    '《》',
  ];

  static String _dropEmptyQuotes(String s) {
    var out = s;
    var changed = true;
    while (changed) {
      changed = false;
      for (final pair in _emptyQuotePairs) {
        if (out.contains(pair)) {
          out = out.replaceAll(pair, '');
          changed = true;
        }
      }
    }
    return out;
  }

  static const String _quotes = '"\'”’「『《〈';

  static String _trimEdges(String s) {
    var out = s;
    while (out.isNotEmpty &&
        (_edgeSeps.contains(out[0]) || _isNewline(out[0]))) {
      out = out.substring(1);
    }
    while (out.isNotEmpty &&
        (_edgeSeps.contains(out[out.length - 1]) ||
            _isNewline(out[out.length - 1]))) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static int _count(String s, String ch) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == ch) n++;
    }
    return n;
  }
}

class _Compiled {
  const _Compiled(this.rule, this.regex, [this.literal]);

  final TextFilterRule rule;
  final RegExp? regex;
  final String? literal;
}

/// The rules that ship enabled.
///
/// Ported from Novery's `TextFilterManager.DEFAULT_BUILTIN_RULES` and extended
/// with the injected-text forms Zangetsu's sources actually emit. All of them
/// are anchored to the start of a line wherever the phrase could plausibly
/// appear inside ordinary narration, so "he said to support me" is not an ad
/// and a rule that removed it would be deleting a sentence of the story.
const List<TextFilterRule> builtinTextFilterRules = [
  TextFilterRule(
    id: 'builtin_discord',
    pattern:
        r'\bdiscord\.(?:gg|com|app|me|io)\S*|^\s*join\s+(?:us\s+)?(?:on\s+)?(?:my\s+|our\s+|the\s+)?discord\b.*',
    label: 'Discord invites / links',
  ),
  TextFilterRule(
    id: 'builtin_patreon',
    pattern:
        r'\bp(?:a|@)treon\.com\S*|^\s*my\s+p(?:a|@)treon\b.*'
        // The one call-to-action strong enough to match anywhere in a line
        // rather than at the start of it. Sources append it to the end of a
        // real paragraph often enough ("He smiled. Please support me on
        // Patreon!"), and this phrase is not something a novel says.
        r'|\b(?:please\s+)?support\s+(?:me|us|the\s+(?:author|writer|creator|translator))'
        r'\s+(?:on|via|through)\s+p(?:a|@)treon\b.*'
        r'|^\s*(?:please\s+)?(?:support|donate|tip)\s+(?:to\s+)?(?:my|our)\s+p(?:a|@)treon\b.*'
        r'|^\s*an\s*[:：-]\s*(?:check\s+out\s+)?(?:my|our)\s+p(?:a|@)treon\b.*',
    label: 'Patreon mentions',
  ),
  TextFilterRule(
    id: 'builtin_powerstones',
    pattern:
        r'\bpower\s?stones?\.(?:com|net)\S*|^\s*(?:please\s+)?(?:support|vote|help)\s+(?:me\s+)?(?:on\s+)?power\s?stones?\b.*',
    label: 'Powerstone mentions',
  ),
  TextFilterRule(
    id: 'builtin_support_me',
    pattern:
        r'^\s*(?:please\s+)?(?:support|donate|tip)\s+(?:me|us|the\s+(?:author|writer|creator|translator)|my\s+(?:work|writing|novel))\b.*'
        r'|^\s*(?:ko-?fi|paypal\.me|cash\.app|buymeacoffee|ko-fi)\S*',
    label: 'Donation / support pleas',
  ),
  TextFilterRule(
    id: 'builtin_join_community',
    pattern:
        r'^\s*join\s+(?:my|our)\s+(?:discord|server|community|telegram|group|channel)\b.*',
    label: 'Community join requests',
  ),
  TextFilterRule(
    id: 'builtin_thanks_reading',
    pattern: r'^\s*(?:thank you|thanks)\s+for\s+(?:reading|the support)\b.*',
    label: 'Thank you notes',
  ),
  TextFilterRule(
    id: 'builtin_urls',
    pattern: r'^\s*https?://\S+\s*$|^\s*www\.\S+\s*$',
    label: 'URL-only lines',
  ),
  TextFilterRule(
    id: 'builtin_voting',
    pattern:
        r'^\s*(?:please\s+)?(?:vote|rate|review)\s+(?:for|on)\s+(?:this|my|the|our)?\s*(?:novel|story|us|book)\b.*',
    label: 'Voting / rating requests',
  ),
  // "Read the next chapter at www.novelfull.com", "Read N° 12 on our discord",
  // "Previous chapter / Next chapter", "Chapter 4 of 480", "Click here to read
  // the next chapter" — the navigation and cross-link footers sources bolt on
  // the end of every chapter. Line-anchored because "read the next chapter" is
  // also a perfectly ordinary thing for a character to say.
  TextFilterRule(
    id: 'builtin_chapter_footer',
    pattern:
        r'^\s*(?:please\s+)?(?:read|continue)\s+(?:the\s+|next\s+|n[°o]\.?\s*[\d]*\s*)?(?:next\s+)?chapter\b.*'
        r'|^\s*read\s+n[°o]\.?\s*\d+.*'
        r'|^\s*(?:previous|prev|last|next)\s+chapter\s*[:/·|-]?\s*(?:previous|prev|last|next)?\s*(?:chapter)?\b.*'
        r'|^\s*chapter\s+\d+\s+(?:of|/)\s+\d+\s*$'
        r'|^\s*(?:click|tap)\s+(?:here|below)\s+to\s+(?:read|continue|view|go)\b.*',
    label: 'Chapter navigation footers',
  ),
  // "Translation by X", "Translator: X", "T/N: X", "TL - X", "Editor: X". The
  // first one on this list was missed until a real chapter turned up with
  // "Translator: BornToBe" sitting at the top of it, still on the page: the rule
  // shipped with "translation" and "translated" and not the noun the sources
  // actually use.
  TextFilterRule(
    id: 'builtin_translation_credits',
    pattern:
        r'^\s*(?:translation|translator(?:s)?|translated|editor|editing|edited|edit(?:or|ors)|'
        r'proofread(?:er|ers|ing)?|proof(?:reader)?|typeset(?:ter|ting)?|'
        // "by" needs its own word boundary; `:` and `-` cannot have one, since a
        // boundary sits between a word and a non-word character and both sides
        // of them here are non-word. Written as one alternation with the
        // boundary on the branch that needs it.
        r'illustrat(?:or|ors|ion|ions)|raws?|t\s*/?\s*n|t\s*/?\s*l|ed)\s*(?:by\b\s*|:|-).*$',
    label: 'Translation credits',
  ),
  TextFilterRule(
    id: 'builtin_novel_promo',
    pattern:
        r'^\s*(?:check out|read|visit|support)\s+(?:my|our)\s+(?:other\s+)?(?:novels?|stor(?:y|ies)|books?|series|websites?|shops?|stores?|twitch|channel)\b.*'
        r'|^\s*if\s+you\s+(?:enjoy(?:ed)?|liked|like|love[sd]?|finished|read|completed)\s+(?:this|my|our)\s+(?:novels?|stor(?:y|ies)|books?)\b.*'
        r'|^\s*(?:follow|subscribe)\s+(?:me|us)\s+on\b.*',
    label: 'Novel promotion',
  ),
  // A line that is nothing but a domain is a watermark or a link, never
  // prose. The TLD list is deliberately short: the rule has to survive a
  // one-word line of dialogue.
  TextFilterRule(
    id: 'builtin_bare_link',
    pattern:
        r'^\s*(?:www\.)?[a-z0-9][a-z0-9\-]*(?:\.[a-z0-9\-]+)*\.(?:com|net|org|io|gg|me|ru|xyz|top|shop|info|co|cc|tv|link|site|online|mobi|ink|pro|vip)\b\S*\s*$',
    label: 'Bare links / watermarks',
  ),
  // A line made of nothing but rule characters - "--------", "________",
  // "========", "******" - is a scene break or the rule above an ad, and it is
  // almost always one of the two. They arrive attached to injected text, so
  // removing the ad and leaving its underline reads as a half-cleaned chapter.
  //
  // Whole-line anchored, so "He stopped --- and said nothing" is untouched: the
  // rule only takes a line that is *entirely* separator characters. Three is the
  // floor because two is a dialogue dash, which is real punctuation. Dots are
  // deliberately absent: a line of them is an ellipsis, which is prose.
  TextFilterRule(
    id: 'builtin_separator_line',
    pattern: r'^\s*[-_=*~#•·—–+]{3,}\s*$',
    label: 'Separator / rule lines',
  ),
  TextFilterRule(
    id: 'builtin_email',
    pattern: r'^\s*[\w.+-]+@[\w-]+(?:\.[\w-]+)+\s*$',
    label: 'Email-only lines',
  ),
];

/// The rule list as one JSON string, for storage and for the cached engine's
/// key.
String encodeTextFilterRules(List<TextFilterRule> rules) =>
    jsonEncode(rules.map((r) => r.toMap()).toList());

/// Parses [encodeTextFilterRules]'s output, dropping any entry that does not
/// parse rather than failing the whole list — one bad rule must not take every
/// other one with it.
List<TextFilterRule> decodeTextFilterRules(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  final out = <TextFilterRule>[];
  for (final entry in decoded) {
    final rule = TextFilterRule.fromMap(entry);
    if (rule != null) out.add(rule);
  }
  return out;
}
