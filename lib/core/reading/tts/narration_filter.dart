/// Decides what read-aloud should skip, and tidies what it keeps.
///
/// Two levels, because the two jobs are different:
///
/// * [skipBlock] — the whole paragraph is not prose. An author's note, a
///   translator's bracket, a CJK note marker. These run to several sentences,
///   so judging them one sentence at a time would leave the rest of the note
///   being read out loud.
/// * [skipSentence] — one sentence wedged between two lines of story is junk.
///   A donation plea, a "next chapter" link, a site watermark.
///
/// ### Nothing here edits the source text
///
/// The reader finds the words to highlight by character offset into the text it
/// actually drew. Deleting a character would shift every offset after it and
/// land the highlight on the wrong words, so a skip here means *omit the
/// sentence from the spoken list* and leave the source exactly as it was.
/// [sanitise] is the one exception, and it may only change the string handed to
/// the speech engine — never an offset, never the reader's text.
///
/// That difference is also why some rules here are looser than Novery's. It
/// deletes matched spans out of the text, so it has to anchor its patterns to
/// the start of a line to avoid cutting a hole mid-sentence. A skip removes the
/// whole sentence, so "contains patreon.com" is safe here and was not safe
/// there.
///
/// ### Deliberately not filtered
///
/// Site names. Novery strips each site's own name from every chapter, which
/// also excises any novel whose prose happens to contain it — "libread"
/// disappears out of the middle of a sentence. There is no safe way to guess
/// which occurrences are junk, so it is left to an explicit user rule.
class NarrationFilter {
  NarrationFilter._();

  // ── block level ───────────────────────────────────────────────────────────

  /// A bracketed tag standing in for a whole block: `[TN: …]`, `[Ed]`,
  /// `【筆者注】`, `【重要】`.
  ///
  /// The tag body may not contain a space, which is what separates a note
  /// marker from prose in brackets — `[the door creaks open]` stays readable.
  /// A lone stage direction does match (`[sighs]`), and is skipped: read
  /// aloud, a paragraph consisting only of a bracketed cue is noise anyway.
  static final RegExp _bracketedNote = RegExp(
    r'^[\[【『(（]\s*[^\s:：\[\]【】]{1,12}\s*(?::|：|[\]】』）])',
  );

  /// An unbracketed note heading: `Author's Note:`, `TL:`, `TL Note:`, `PR:`.
  ///
  /// `author'?s?'?` rather than `authors?'?` because the two orders are both
  /// real — "Author's Note" and "Authors Note" — and the plain spelling is the
  /// common one, since our own normaliser strips the apostrophe out of the
  /// speech text but leaves it in the source.
  ///
  /// Only trusted at the two ends of a chapter, where notes actually live.
  /// A novel paragraph can legitimately open with "Note:" and a filter that
  /// cannot tell the difference would silently eat a paragraph of story.
  static final RegExp _noteHeading = RegExp(
    r"^\s*(?:"
    r"author'?s?'?\s*notes?"
    r"|editor'?s?'?\s*notes?"
    r"|translator'?s?'?\s*notes?"
    r"|proofreader'?s?'?\s*notes?"
    r"|note\s+from\s+(?:the\s+)?(?:author|translator|editor|tl|pr)"
    // Short tags, with or without a following "Note".
    r"|(?:a\s*/?\s*n|t\s*/?\s*l|tl|tn|ed|en|e\s*/?\s*n|pr|p\s*/?\s*r)\b"
    r"(?:\s*notes?)?"
    r")\s*[:：\-–—]",
    caseSensitive: false,
  );

  /// `Updated from F r e e w e b n o v e l . c o m`, spaced out letter by letter
  /// to dodge scrapers, and the plain form.
  ///
  /// Judged at block level, not per sentence: the spaced form puts a full stop
  /// in the middle of itself, so the sentence splitter cuts it in two and the
  /// rule only ever sees the first half — the trailing `c o m` then survives on
  /// its own and gets read aloud. Unambiguous enough to trust anywhere, since
  /// no prose paragraph opens this way.
  static final RegExp _siteWatermark = RegExp(
    r'^\s*\[?\s*updated\s+from\s+f\s*r\s*e\s*e\s*w\s*e\s*b\s*n\s*o\s*v\s*e\s*l\b',
    caseSensitive: false,
  );

  /// How many blocks from either end count as "at the end".
  ///
  /// Two, not zero, because the block before a note is often the chapter
  /// heading, and the note is then nominally the second block.
  static const int endWindow = 2;

  /// Whether the whole block at [blockIndex] of [blockCount] is a note or other
  /// non-prose, and so should not be narrated at all.
  static bool skipBlock(
    String text, {
    required int blockIndex,
    required int blockCount,
  }) {
    final probe = _probe(text);
    if (probe.isEmpty) return false;
    if (_bracketedNote.hasMatch(probe)) return true;
    if (_siteWatermark.hasMatch(probe)) return true;

    final nearEnd = blockIndex < endWindow ||
        blockIndex >= blockCount - endWindow;
    if (!nearEnd) return false;

    // `[Editor's Note: …]` is too long to be a tag, so retry without the
    // bracket before giving up on it.
    final unbracketed =
        probe.replaceFirst(RegExp(r'^[\[【『(（]\s*'), '');
    return _noteHeading.hasMatch(unbracketed);
  }

  // ── sentence level ────────────────────────────────────────────────────────

  /// Donation and community links. Contains rather than starts-with, which is
  /// only safe because a match drops the entire sentence.
  static final RegExp _linkLine = RegExp(
    r'patreon\.com|ko-?fi\.com|paypal\.me|cash\.app|'
    r'buymeacoffee\.com|discord\.(?:gg|com|app)\b|'
    r'power\s?stones?\.(?:com|net)',
    caseSensitive: false,
  );

  /// Whole-sentence patterns, matched against the probe. Each is anchored
  /// because the phrase has to be the point of the sentence, not a remark
  /// inside it.
  static final List<RegExp> _sentenceRules = <RegExp>[
    // "Please support me on Patreon", "Support us, it costs nothing".
    RegExp(
      r"^\s*(?:please\s+)?(?:support|donate|tip)\s+(?:me|us)\b",
      caseSensitive: false,
    ),
    // "Join my Discord server", "join us on discord".
    RegExp(
      r'^\s*join\s+(?:us\s+)?(?:on\s+)?(?:my\s+|our\s+|the\s+)?'
      r'(?:discord|server|community|telegram|group|channel)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*check\s+out\s+(?:my\s+|our\s+|the\s+)?'
      r'(?:discord|community|telegram|group)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*(?:thank\s*you|thanks)\s+for\s+(?:reading|the\s+support)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*(?:please\s+)?(?:vote|rate|review)\s+(?:for|this|my|our|us)\b',
      caseSensitive: false,
    ),
    // "Previous chapter" / "Next chapter" links left in the body by a scraper.
    RegExp(r'^\s*(?:previous|prev|last)\s+chapter\.?$', caseSensitive: false),
    RegExp(r'^\s*next\s+chapter\.?$', caseSensitive: false),
    // The watermark is caught at block level; repeated here so a block that is
    // not alone still loses its opening.
    _siteWatermark,
  ];

  static final RegExp _clickHere = RegExp(
    r'^\s*(?:click|tap)\s+(?:here|below)\s+to\s+(?:read|continue|view|go)\b',
    caseSensitive: false,
  );

  static final RegExp _errorReport = RegExp(
    r'^\s*if\s+you\s+(?:find|found|notice|discovered?)\b.*\berrors?\b',
    caseSensitive: false,
  );

  /// Second condition for [_errorReport], so a character in a story who talks
  /// about finding errors in some code does not get their line deleted.
  static final RegExp _errorReportEvidence = RegExp(
    r'broken\s+links?|report|let\s+us\s+know|fix\s+(?:it|them|this)',
    caseSensitive: false,
  );

  /// A boilerplate line is short. "Click here to read on" in a paragraph of
  /// narration is a character quoting a website; the same words alone on a line
  /// are a link.
  static const int shortBoilerplateMax = 90;

  /// Whether [raw] is a sentence read-aloud should pass over.
  ///
  /// Takes the *raw* text, not the normalised form: normalisation strips the
  /// URLs and apostrophes the patterns here look for.
  static bool skipSentence(String raw) {
    final probe = _probe(raw);
    if (probe.isEmpty) return true;

    // A sentence that was mostly a link is a link, not prose. Sanitising it
    // alone is not enough: "mail me at someone@example.com" becomes "mail me
    // at", which is worse than silence, and the leftover is a real sentence
    // that passes every other check.
    if (_url.hasMatch(raw) || _email.hasMatch(raw)) {
      if (sanitise(raw).length * 2 < probe.length) return true;
    }

    for (final rule in _sentenceRules) {
      if (rule.hasMatch(probe)) return true;
    }
    if (_linkLine.hasMatch(probe)) return true;
    if (probe.length <= shortBoilerplateMax && _clickHere.hasMatch(probe)) {
      return true;
    }
    if (_errorReport.hasMatch(probe) &&
        _errorReportEvidence.hasMatch(probe)) {
      return true;
    }
    return false;
  }

  // ── what survives ─────────────────────────────────────────────────────────

  static final RegExp _url = RegExp(
    r'(?:https?://|ftp://|www\.)\S+',
    caseSensitive: false,
  );
  static final RegExp _email =
      RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+\b');
  static final RegExp _markup = RegExp(r'[*`|~]');

  /// Tidy the string handed to the speech engine.
  ///
  /// A URL left in is not merely ugly — the engine spells it out, so
  /// `patreon.com/author/x` arrives at the listener as "patreon dot com slash
  /// author slash x". Stripping it can empty the sentence, in which case the
  /// caller drops it; a link on a line of its own is a link, not prose.
  ///
  /// Only ever changes the spoken text. Offsets and the reader's own text are
  /// untouched, so a highlight is unaffected by anything removed here.
  static String sanitise(String text) {
    if (text.isEmpty) return text;
    var s = text;
    if (_url.hasMatch(s)) s = s.replaceAll(_url, ' ');
    if (_email.hasMatch(s)) s = s.replaceAll(_email, ' ');
    if (_markup.hasMatch(s)) s = s.replaceAll(_markup, '');
    if (s.contains('  ')) s = s.replaceAll(RegExp(r'\s{2,}'), ' ');
    return s.trim();
  }

  // ── shared ────────────────────────────────────────────────────────────────

  /// Trims, collapses whitespace and drops trailing terminators, so one pattern
  /// matches a sentence however the splitter happened to cut it.
  static String _probe(String text) {
    var s = text.trim().replaceAll(RegExp(r'\s{2,}'), ' ');
    while (s.isNotEmpty && _trailing.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1).trimRight();
    }
    return s;
  }

  /// Characters a splitter may have left on the end of a piece, stripped before
  /// a pattern is matched so one rule covers every way of cutting the same
  /// sentence. Straight and curly quotes are in here because our own
  /// normaliser removes them, which is why the rules allow for their absence.
  static const String _trailing = '.!?…:;\'"”’」』)]';
}
