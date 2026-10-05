# Changelog

Every published build of Inkbound, in order, including the one that was
withdrawn. This file exists because the individual GitHub releases for the 3.0.x
line were removed when 4.0.0 shipped; this is the record of what each one did and
what went wrong.

Versions are listed oldest first. The release date is the day the signed APK was
published.

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

## 3.0.5 — 2026-10-05 → WITHDRAWN

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