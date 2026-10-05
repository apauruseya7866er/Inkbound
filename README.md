<div align="center">
<img src="assets/icon/app_icon.png" alt="Inkbound app icon" width="120" />

# Inkbound

**A novel-only reader for Android.**
Novels only. Local only. Yours.

[![Latest release](https://img.shields.io/github/v/release/apauruseya786er/Inkbound?display_name=tag&style=for-the-badge&color=FF4D57)](https://github.com/apauruseya786er/Inkbound/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-FF4D57?style=for-the-badge)](LICENSE)

### [⬇️ Download the latest APK](https://github.com/apauruseya786er/Inkbound/releases/latest)

Android **7.0 (API 24)**+ · **76.3 MB** · **arm64-v8a / armeabi-v7a**

</div>

<!-- Screenshots go here once they are captured on the emulator.
<p align="center">
  <img src="docs/screenshots/library.png" width="23%" alt="Library" />
  <img src="docs/screenshots/reader.png" width="23%" alt="Reader" />
  <img src="docs/screenshots/audiobook.png" width="23%" alt="Audiobook player" />
  <img src="docs/screenshots/lyrics.png" width="23%" alt="Lyrics view" />
</p>
-->

> Inkbound is a novel-focused fork of [Zangetsu](https://github.com/Spyou/Zangetsu) by Krishna Vishwakarma. The reader, source system, downloads, trackers and read-aloud engine are his work, carried over intact. If you use Inkbound, please [star the original](https://github.com/Spyou/Zangetsu).

---

## Features

- **Many sources, one library.** Add source plugins and each gets its own row on the home page, pinned and ordered by you. Search and browse across all of them.
- **A reader built for long chapters.** Continuous scroll or page-by-page, with font, size, line height, letter and word spacing, alignment, and reading themes that stay dark when the system flips to dark.
- **Read-aloud that sounds like a person.** Full-sentence highlighting, voice, speed, pitch, a sleep timer, and a sentence-gap control so narration sounds like speech rather than a machine enumerating clauses. It keeps going with the screen off, resumes from the sentence you left (not the chapter), and stops when you swipe the app away.
- **An audiobook player, and a transcript you can read along to.** Tap the read-aloud bar to open it: cover, a waveform that maps the chapter, transport that skips chapters, a sleep timer and speed presets. Switch to the transcript and the sentence being read sits centre stage, bright against the rest — tap any line to send the voice there.
- **Reading progress that survives Android.** The position is written to disk *before* the app can be killed, per book. Close it, swipe it away, come back tomorrow: it reopens on the line you left.
- **Text cleanup that follows through.** Built-in rules strip donation pleas, Discord/Patreon links, chapter footers, translator notes and decorative rules — including the obfuscated `P@treon` spellings and pleas aimed at the author rather than the reader. Long-press any sentence to hide it everywhere. The same rules apply to narration, so the narrator never reads an ad aloud.
- **Downloads and offline reading.** Pull chapters down and read without a connection.
- **History on the dock**, not buried in a menu.
- **Local-first.** No account, no cloud, no telemetry. Backups go to any folder you choose, as a plain JSON file you can read without this app.

---

## Install

1. Download the APK from the [releases page](https://github.com/apauruseya786er/Inkbound/releases/latest).
2. Open it on your phone and allow installs from your browser or file manager if Android asks.
3. On first launch, the app seeds a source index so you have a catalogue immediately.

**Verify the download (optional).** Releases are signed. The signing certificate's SHA-256 fingerprint is:

```
831ef2fefd7021f36f1be3e2d767aa0dcb960c1b9519346bc04413c3e564c0c8
```

> **Signing gotcha.** If you install a release build and later build from source without `android/key.properties`, you get a *debug-signed* APK, and Android will refuse to upgrade across that boundary. Uninstall before switching.

---

## Sources

Inkbound ships **no content and no sources of its own.** It loads community scrapers from the [LNReader](https://github.com/LNReader/lnreader-sources) ecosystem, served through [apauruseya786er/plugins](https://github.com/apauruseya786er/plugins) (`plugins/v3.0.0`), a fork that tracks upstream and publishes this project's scraper fixes.

- The first launch seeds that index (about 290 sources today).
- The Sources screen can add further repositories by URL.
- A broken scraper is fixed with a pull request against the plugins repository.

---

## Privacy and network activity

There is no account to create and no server that learns what you read. Your library, history and progress stay on the device unless you export them.

The app does make network requests, and only these:

- **Source sites** you browse or download from, through the plugins you installed.
- **The plugin index** on GitHub, and any extra repositories you add.
- **Update checks** and **fonts**, from infrastructure this repository controls. <!-- TODO: confirm exact hosts -->
- **An external solver**, only if you configure one (see below). Off by default.

---

## Cloudflare-protected sources

Inkbound tries four steps, each running only if the previous one failed:

1. **Native TLS stack.** Fetches use Android's HTTP stack for a browser-like TLS fingerprint.
2. **One shared cookie jar** for the reader, source system and solver, so a clearance can't be shadowed by a stale copy.
3. **Automatic solve** in a hidden WebView, using the same User-Agent the replay will send. If it needs a human, the app offers a visible solve.
4. **Optional external solver:** point the app at a self-hosted [Solverr](https://github.com/unseensnick/Solverr), Byparr or FlareSolverr.

Sites on Cloudflare's strictest tier can't be solved by any in-app trick; step 4 exists for those.

---

## FAQ

**A source shows an empty list.**
It is probably behind Cloudflare or the scraper is out of date. Try the visible solve, check for an updated source, or open an issue on the [plugins repo](https://github.com/apauruseya786er/plugins).

**The app won't update over my existing install.**
See the signing note under [Install](#install).

**Where did the older versions go?**
The 3.0.x releases were withdrawn when 4.0.0 shipped so the releases page would carry one clear entry. Nothing was lost: every version, including one that was withdrawn for shipping a blank reader, is written up in **[CHANGELOG.md](CHANGELOG.md)**.

**Is Inkbound different from Zangetsu?**
Yes. Anime, manga, accounts, cloud sync and the second-screen remote are removed, and the app has its own source index and Cloudflare handling. See [FORK.md](FORK.md) for the full list.

---

## Build from source

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart 3.11.5 or later) and an Android toolchain.

```bash
git clone https://github.com/apauruseya786er/Inkbound.git
cd Inkbound

flutter pub get
flutter run                  # debug build on a connected device
flutter build apk --release  # → build/app/outputs/flutter-apk/
```

Signing config lives in `android/key.properties`, which is deliberately not in the repository. `android/key.properties.example` shows the expected shape.

Release builds package **arm64-v8a and armeabi-v7a only**. An x86_64 emulator cannot run them; see *Testing on an emulator* in [CONTRIBUTING.md](CONTRIBUTING.md) for the opt-in that adds the emulator ABIs.

**Stack:** Flutter and Dart, [Hive](https://pub.dev/packages/hive) for local storage, Kotlin `MethodChannel`s for the TTS engine, the JavaScript source runtime, and storage access.

See [CONTRIBUTING.md](CONTRIBUTING.md) for CI, tests and how to send a pull request.

---

## Credits

Inkbound would not exist without **[Zangetsu](https://github.com/Spyou/Zangetsu)** by [Krishna Vishwakarma](https://github.com/Spyou). Most of the commit history and most of the ideas are his. Source plugins come from the [LNReader](https://github.com/LNReader/lnreader-sources) ecosystem. Contributors are listed in [CONTRIBUTORS.md](CONTRIBUTORS.md) and third-party notices in [NOTICE.md](NOTICE.md).

## Disclaimer

**Inkbound is a reading tool only.** It does not host, provide, distribute or maintain any content or source extension. You are solely responsible for how you use the app and for any third-party source you install, including compliance with applicable law and copyright. The maintainers disclaim all liability for misuse or legal issues arising from the app or any third-party service. This project is not affiliated with or endorsed by the authors of any source extension, or by the Zangetsu project beyond the fork relationship described above.

## License

[GNU GPL-3.0](LICENSE). Copyright © 2026 Krishna Vishwakarma (original Zangetsu project). Modifications and the novel-only reworking © 2026 apauruseya786er. Attribution requirements are in [NOTICE.md](NOTICE.md), contribution terms in [CLA.md](CLA.md), and the [AI usage policy](AI_POLICY.md) applies to this codebase.

<div align="center">

[🐛 Report an issue](https://github.com/apauruseya786er/Inkbound/issues) · [📦 Releases](https://github.com/apauruseya786er/Inkbound/releases) · [🔌 Plugin index](https://github.com/apauruseya786er/plugins) · [⭐ Star Zangetsu](https://github.com/Spyou/Zangetsu)

</div>