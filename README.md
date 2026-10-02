<div align="center">

<img width="100%" src="https://capsule-render.vercel.app/api?type=waving&color=0:FF4D57,100:1a1a2e&height=220&section=header&text=Inkbound&fontSize=75&fontColor=ffffff&animation=fadeIn&fontAlignY=38&desc=Read.%20Listen.%20Read%20offline.&descAlignY=58&descSize=20" />

<img src="assets/icon/app_icon.png" width="120" alt="Inkbound" />

### A novel reader for Android — inspired by [Zangetsu](https://github.com/Spyou/Zangetsu)

[![License](https://img.shields.io/github/license/apauruseya7866er/Inkbound?style=for-the-badge&color=FF4D57)](LICENSE)
[![Issues](https://img.shields.io/github/issues/apauruseya7866er/Inkbound?style=for-the-badge&color=FF4D57&logo=github)](https://github.com/apauruseya7866er/Inkbound/issues)

![Platform](https://img.shields.io/badge/Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Built%20with-Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white)

<br/>

<p align="center">
  <a href="#-what-it-does"><b>What it does</b></a> ·
  <a href="#-inspiration--credits"><b>Inspiration &amp; credits</b></a> ·
  <a href="#-build-it-yourself"><b>Build it yourself</b></a> ·
  <a href="#%EF%B8%8F-disclaimer"><b>Disclaimer</b></a> ·
  <a href="#-license"><b>License</b></a>
</p>

<img width="100%" src="https://capsule-render.vercel.app/api?type=rect&color=0:FF4D57,100:1a1a2e&height=4" />

</div>

## 📖 What it does

Inkbound is a novel reader for Android. One app for browsing many novel
sources, reading them comfortably, listening when you'd rather not read, and
keeping them for offline.

**Many sources, one library.** Add source plugins and each one gets its own row
on the home page, pinned and ordered by you. Search and browse across all of
them.

**A reader built for long chapters.** Continuous scrolling or page-by-page, with
font, size, line height, letter and word spacing, alignment and themes — plus
dark reading themes that stay dark when the system flips.

**Read-aloud that doesn't sound robotic.** Full-sentence highlighting that
follows along, a voice picker, speed and pitch, a sleep timer, and a
**sentence-gap control** so the pause between sentences sounds like a person
rather than a machine. Narration keeps going with the screen off, resumes from
the sentence you left, and stops when you swipe the app away.

**Text cleanup.** Built-in rules strip the injected junk real sources ship —
donation pleas, Discord and Patreon links, chapter footers, translator credits,
and decorative separator lines. Long-press any sentence to hide it everywhere,
not just in the book you hid it in. The same rules apply to the page *and* to
read-aloud, so the narrator never reads an ad.

**Reading progress that sticks.** Your position is saved as you read and written
to disk before the app can be killed — close it, swipe it away, come back
tomorrow, and it reopens on the line you left, not the top of the chapter.

**Offline.** Download chapters and read them without a connection.

**Local-first, on purpose.** There is no account to make and nothing to sign in
to. Your library, history and progress live on your device. Want a backup? Point
the app at any folder you choose — including a synced one — and it writes a
plain JSON file you can read yourself.

### What this build deliberately doesn't do

Being honest about the edges matters more than a longer feature list:

- **Novels only.** The anime, movie and TV code paths are compiled in but gated
  off, so the app ships as a novel reader. See
  [`lib/core/mode/novel_only.dart`](lib/core/mode/novel_only.dart) — one constant
  flips it back.
- **No cloud, no account, no sync.** Everything stays on the device. There is
  nothing to sign in to and nothing leaves the phone unless you export it.
- **No second-screen pairing.** Casting and remote-control features were removed.
- **No releases yet.** This repository has no published APKs. Build it yourself
  below.

> **Note:** the app currently still installs under the launcher name
> `Zangetsu`, inherited from the original project. The repository is Inkbound.

---

## 🙏 Inspiration & credits

**Inkbound would not exist without [Zangetsu](https://github.com/Spyou/Zangetsu)
by Krishna Vishwakarma.** It is a novel-focused fork of that project, and it
carries the reader, the source system, downloads, trackers, the read-aloud
engine and most of everything else you see here. If you like this app, please
consider starring the original — it's the larger project, and this one stands on
it.

The source plugins come from the
[LNReader](https://github.com/LNReader/lnreader-sources) ecosystem, which is a
large part of why multi-source works as well as it does.

Thanks also to everyone who has contributed to Zangetsu over the years. That
project's history, and the 2,300+ commits behind this fork, are the work of many
people.

---

## 🛠 Build it yourself

No prebuilt APKs — this is the source. You'll need the
[Flutter SDK](https://docs.flutter.dev/get-started/install) with Dart `^3.11.5`
and an Android toolchain.

```bash
git clone https://github.com/apauruseya7866er/Inkbound.git
cd Inkbound

flutter pub get
flutter run                 # debug build on a connected device
flutter build apk --release # release APK → build/app/outputs/flutter-apk/
```

Signing config lives in `android/key.properties`, which is deliberately not in
this repository. `android/key.properties.example` shows the expected shape.

**Tech stack:** Flutter and Dart, [Hive](https://pub.dev/packages/hive) for
local storage, Kotlin `MethodChannel`s for the TTS engine, the JavaScript source
runtime and storage access framework.

---

## ⚠️ Disclaimer

> [!IMPORTANT]
> **Inkbound is a reading tool only.** It does not host, provide, distribute or
> maintain any content or source extensions.

- **User responsibility** — you are solely responsible for how you use the app
  and for any third-party source you choose to install, and must comply with all
  applicable law and with copyright and intellectual-property rights.
- **No liability** — the maintainers of Inkbound disclaim all liability for
  misuse or legal issues arising from your use of the app or of any third-party
  service. Concerns about a third-party source belong with whoever made it.
- **No affiliation** — this project is not affiliated with or endorsed by the
  authors of any source extension it can load.

---

## 📜 License

Inkbound is licensed under the **[GNU GPL-3.0](LICENSE)**.

Copyright © 2026 **Krishna Vishwakarma** (original Zangetsu project).
Modifications and the novel-only reworking © 2026 **apauruseya7866er**.

The full GPL-3.0 text is in [`LICENSE`](LICENSE); attribution requirements in
[`NOTICE.md`](NOTICE.md) and the upstream contribution terms in
[`CLA.md`](CLA.md) still apply to this codebase.

<div align="center">

<br/>

<img src="assets/icon/app_icon.png" width="70" alt="Inkbound"/>

### Inkbound
*A novel reader, forked from Zangetsu.*

<br/>

[🐛 Report an issue](https://github.com/apauruseya7866er/Inkbound/issues)
&nbsp;&nbsp;•&nbsp;&nbsp;
[⭐ Star the original](https://github.com/Spyou/Zangetsu)

<br/>

<img width="100%" src="https://capsule-render.vercel.app/api?type=waving&color=0:1a1a2e,100:FF4D57&height=120&section=footer" />

</div>