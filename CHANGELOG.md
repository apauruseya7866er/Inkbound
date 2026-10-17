# Changelog

Every published build of Inkbound, in order, including the one that was
withdrawn. This file exists because the individual GitHub releases for the 3.0.x
line were removed when 4.0.0 shipped; this is the record of what each one did and
what went wrong.

Versions are listed oldest first. The release date is the day the signed APK was
published.

## 4.2.1 - 2026-10-17

### One mark, everywhere it appears

The app had three different identities in it, and the two that actually reach
you belonged to the project this was forked from. The launcher icon, the iOS and
tvOS icons, the TV banner and the in-app mark were each drawn separately, and
the iOS icon and the TV banner were still the upstream crescent and wordmark -
so an iPhone showed a different app from the one the About screen described, and
the TV banner was a stranger's name.

All of them are now one mark: an open book with the bookmark ribbon in its
gutter. It is the launcher icon on both slots, the iOS icon at all twenty sizes,
the tvOS icon and Top Shelf images, the TV banner, the splash, the About screen
and the Home header.

Two launcher icons ship, as before, and the picker still offers both. The
default is the book on its own. The second slot is a cat reading it, for readers
who want the less serious one. The icon ids and their aliases are unchanged -
they live in your phone's preferences and cannot be renamed once shipped - so
"crescent", which used to name a crescent and then a cat, now names the book.

### A second splash

Settings -> Interface -> Icon, splash & banner now offers two splashes:
**Wordmark** and **Bold**. Same lettering, same box, same spacing, the second
set in a heavier cut. The bold is a real Bold from the variable weight axis in
the bundled Inter, not the same cut with a stroke drawn over it.

Picking one now does something. The splash and its preview card both had the
wordmark's filename written into them by hand, so with a single option on offer
the setting looked wired up and could not have worked.

### Fixes

- **The Home header no longer overflows on a narrow phone.** On a 320dp screen
  the header's five controls and the source switcher wanted 324px of a 288px
  row, and the wordmark was squeezed to nothing width while the row still
  overflowed. The wordmark now scales down instead of disappearing, the source
  switcher ellipsizes inside whatever share it is given, and the five buttons
  keep their full tap targets.
- **The splash mark no longer disappears on a narrow phone.** Same cause, in the
  switcher's own capsule: the ecosystem tag and the drop arrow were rigid and
  could not compress past their own children, which overflowed once the capsule
  itself was given less room.

## 4.2.0 - 2026-10-10

### Clear out sources that have stopped working

Two cleanups on Profile -> Sources -> Source health, each scoped and each
carrying its own live count:

- **Remove dead sources** - blocked, timed out, or throwing.
- **Remove no-results** - answered, and the answer was nothing.

Choosing one lists **only** that category, every row ticked, so unticking the
few you want to keep is the only decision on screen. Nothing is removed until
the bottom bar, which states how many, and a confirmation stands in front of
it. A category with nothing in it disables its button rather than opening an
empty picker.

The two are kept apart on purpose. A dead source refuses to answer and is worth
nothing until the site changes. A no-results source answered and said it had
nothing, which for a niche title is often a perfectly healthy site that simply
does not carry that book - and lumping the two together quietly argues for
deleting working extensions. Sources that answer slowly, and sources still
being probed, are in neither.

The row's tick moves to the right, where it lines up with the delete control it
stands in for.

### Fixes

- **A blocked source no longer reads as "no matches."** This was the reason a
  pinned source full of a book could look like it had lost it. Two places lost
  the failure on the way to the screen: the plugin helper caught the error and
  returned null, which became an empty list, and the repository reads an empty
  list as "this site has nothing for that title". So a Cloudflare refusal was
  indistinguishable from a genuine no-results before it ever left the provider.
  The search cubit also treated only a generic error as a failure, so blocked
  and timed-out rendered as empty too. Both fixed - the screen now says
  "couldn't reach", and a source that genuinely has nothing still says "no
  matches".

### Known

- A source's language is still not shown on the novel search row; the field is
  carried through but not filled in.
- Browse rows (popular, latest) still degrade quietly to empty when a site
  refuses them, rather than reporting the refusal. Search reports it; browse has
  no way to explain itself and its callers do not catch.

## 4.1.0 - 2026-10-10

First release under the app's new name. The package id is
`com.apauruseya7866er.inkbound`; the older releases stay on the page under their
old name.

### Search every novel source at once

- **Search novels.** A new action on Home, beside the existing search, that
  queries every installed novel source for one title and groups the answers by
  where each came from - so the same book on two sites is visibly two books.
  Five sources are queried at a time, rows stream in as they answer, and a
  result that arrives after you have typed the next title is discarded rather
  than repainting the screen with the previous query.
- **Pinned sources by default.** The search asks the sources you pinned, not
  all of them, because that is what you expect to answer. "All sources"
  widens it and really does query the rest.
- **Fix: the screen said you had no novel sources when you had 150-odd.** It
  was reading the catalogue router, which with Z Mode enabled resolves to the
  metadata catalogue - one pseudo-source, which the screen then discarded. The
  sources tab was unaffected, which is why they were plainly listed there and
  invisible here. The empty state also lied in the other direction: a reader
  with sources but none pinned was told none were installed. It now says which,
  and offers to search everything.
- **Per-source arrow** opens that source, and the language a source declares is
  shown under its name.
- **Two different buttons.** The two search actions had looked identical; the
  novel one is now a book.

### Read-aloud and the reader

- **Long press** no longer hits the wrong line: the hit test was reading screen
  coordinates as content coordinates, so on a scrolled or paged chapter it
  missed and logged.
- **A tap shows the controls** instead of jumping to the next sentence, on
  novels.
- **The audiobook player fills the page** rather than floating over it, with
  the transcript and the chapter controls following the chapter you are on.
  Lyrics now name the chapter.
- **A novel's Web action becomes Listen**, reusing the path that already worked
  from the reader.
- **Continue Reading picks narration back up** where it stopped, resolving the
  saved fingerprint and ignoring a stale incognito flag.
- **Playback stops** when a chapter finishes without speaking, instead of
  running on unattended.

### Extensions

- **LNReader diagnostics**, redacted, per request and per stage: enough to see
  whether an extension loaded, which plugin answered, and what it returned.

### Known

- A source's language is not yet shown on the novel search row; the field is
  carried but not filled in.
- Some extension sites refuse the app's requests and report as returning
  nothing rather than as an error.

## 4.0.0 — 2026-10-05

The current release, and the first one published on its own: the 3.0.x releases
were withdrawn once this shipped, so **v4.0.0 is the only release on the
releases page**. The tag history below is kept here instead.

Ships the whole 3.0.x line's worth of fixes plus the reader work:

- **Audiobook sheet.** Tap the empty space of the compact read-aloud progress
  bar, or the new expand button beside the settings and close controls, to open
  it. Two views behind one header: a player with cover, waveform, transport and
  quick actions, and a transcript with the spoken sentence prominent and tappable
  to seek. The transport skips chapters; the quick row steps sentences; the
  waveform and lyric tap both seek. The transcript opens on the sentence
  currently being read.
- **Read-aloud highlight.** The spoken sentence is marked with a soft lavender
  fill per text line and a dark foreground, so a sentence wrapping over several
  lines reads as one continuous highlight.
- **Text filters.** Pleas aimed at the author, creator, writer or translator;
  obfuscated `P@treon` spellings; and the other shapes a Patreon ad arrives in
  ("Enjoy more chapters on Patreon", bare `Patreon:` label lines). Ads are cut
  whole-line or sentence-wise, so a paragraph's own prose survives.
- **Reader unchanged from 3.0.4**, which is deliberate — see the 3.0.5 entry.

## 3.0.7 — 2026-10-05

- Audiobook player and lyrics view, reached from the read-aloud bar.
- The transport's skip buttons moved from sentence to **chapter**; they had been
  duplicating `-1 Sent` / `+1 Sent`. Sentence stepping stays in the quick row.
- The cover is sized from the space the sheet actually gives it, instead of from
  the window, which had capped it and left a gap above the waveform.

## 3.0.6 — 2026-10-04

**Rollback of 3.0.5.** Reverts the PR #2 merge, restoring the 3.0.4 reader
exactly. Shipped as a new version rather than a re-release of 3.0.4 so it could
be installed **over** the withdrawn build without uninstalling — Android only
accepts a higher `versionCode`, and uninstalling would have wiped the reader's
library and progress.

## 3.0.5 — 2026-10-04 → WITHDRAWN

**Shipped, then withdrawn.** Contained the novel-only Home page and a read-aloud
polish pass (PR #2). It opened **every novel chapter as a blank page**.

What is known:

- The chapter text itself loaded correctly — the app's own log recorded 141
  sentences segmented across 87 blocks, 12,414 characters.
- There was no crash and no Dart exception in logcat.
- Widget tests rendered chapter prose correctly, using realistic novel-site
  HTML, both idle and speaking — identical to the known-good build.

What was never established: the root cause. It was **not** empty content, a
plugin or index fault, the novel-only Home routing, or the reader's default font
— a build carrying only that subset still blanked. The lesson taken forward is
that green tests did not cover it: no test rendered a chapter end to end, so the
suite was structurally incapable of catching it.

4.0.0 does not contain PR #2. Its reader is 3.0.4's.

## 3.0.4 — 2026-10-04

- Fixed centred read-aloud follow: the view scrolled using the wrong viewport,
  so the spoken sentence drifted off screen. This is the reader behaviour 4.0.0
  still ships.

## 3.0.3 — 2026-10-04

- Source health shown beside each installed source's Uninstall button, so a dead
  source is visible before it fails.
- Landed the source-management unit (installer, mode policy, source kinds)
  together rather than piecemeal.

## 3.0.2 — 2026-10-04

- Fixed plugin seeding: the app seeded the upstream LNReader index instead of
  this fork's, and existing installs were migrated off the superseded URL so a
  catalogue could not appear twice.

## 3.0.1 — 2026-10-03

- Fixed a blank Profile tab: it eagerly dereferenced settings that were never
  registered with the dependency injector.
- Rebuilt with a corrected `versionCode` (13503); the first 3.0.1 had reused
  3.0.0's and could not be installed over it.

## 3.0.0 — 2026-10-03

- First public Inkbound build, forked from Zangetsu: novel-only, own source
  index, no account.
- Known bad: the Profile tab was blank, fixed in 3.0.1.

## Before 3.0.0

Releases in the `v1.x` and `v2.x` ranges belong to **upstream Zangetsu**, not to
Inkbound. They are kept in the tag history for attribution and are not Inkbound
builds.