# Contributing to Inkbound

Thanks for helping out. Contribution terms are in [CLA.md](CLA.md), and the AI usage policy applies to this codebase.

## Before you open a pull request

```bash
flutter pub get
flutter analyze   # must report zero errors and zero warnings
flutter test
```

## What CI enforces

The analyzer is gated. `analysis_options.yaml` escalates the rules that are actually dangerous, and the workflow is configured to fail on any error or warning, not merely report it. Note that `--no-fatal-infos` only excuses **info**-level lints; a single warning fails the build.

Test fakes must really override. A past cleanup removed 41 stale `@override` annotations in test fakes that were falling through to `noSuchMethod`, so those tests passed without calling what they claimed to test. The related rule is escalated so it can't come back quietly.

Signed releases come from tags. Pushing `v*` builds a signed APK on the releases page, and the release is refused if it turns out to be debug-signed.

## The JavaScript runtime is required for most of the suite

The scraper runtime is a native library, `quickjs_c_bridge`. Around 28 of the tests — everything under `test/core/lnreader/`, plus `js_engine_test.dart`, `js_reading_provider_names_test.dart` and `cf_solve_needed_test.dart` — execute real plugin JavaScript through it. They are marked `@Tags(['needs-device'])`.

If that library is not built for the current platform, those tests fail with:

```
Failed to load dynamic library 'quickjs_c_bridge.dll': The specified module could not be found.
```

That is a missing build artifact, not a broken test, and not something your change caused. Those tests are tagged `needs-device` and skipped by `dart_test.yaml`, so the Test job is a real gate again instead of a permanently red one. They are not deleted and not ignored - to run them where the library exists:

```sh
flutter test --run-skipped -d <device>
```

### Where that coverage actually runs: `integration_test/js_runtime_test.dart`

`flutter_js` is backed by **QuickJS compiled to a native library**, and `android/app/build.gradle.kts` builds it from the package's own `android/CMakeLists.txt` — Android only. On iOS the same package uses JavaScriptCore and needs no bridge. So there is no host build to install: the tests above can only ever run where Gradle has already built the `.so`, which means on a device.

`integration_test/js_runtime_test.dart` is the other half of that coverage, on the only platform where it can exist:

```sh
# android/local.properties needs includeEmulatorAbis=true first — see below
flutter test integration_test/js_runtime_test.dart -d <device>
```

It asserts the engine evaluates, that it reports errors rather than swallowing them, that the committed cheerio bundle parses HTML, and that a real LNReader CommonJS plugin loads, pushes a fetch out through the outbox bridge and hands back parsed data — plus that a failing fetch rejects instead of hanging to its 30s timeout. The fetch is injected, so nothing touches the network.

Porting a host test here is usually cheap: if it injects its own fakes rather than hitting the network or a mock channel, it moves over as-is. Reach for this when a change to the source system needs to be proven on a real engine.

## Testing on an emulator

Release builds package **arm64-v8a and armeabi-v7a only**. An x86_64 emulator cannot launch them — every native library in the APK is stripped, and the launch dies looking for `lib/x86_64/libflutter.so`. The x86_64 libraries are dead weight on real devices, so they are not shipped by default.

To opt back in for a local emulator run, add this to `android/local.properties` (git-ignored, so it cannot reach CI or another developer):

```properties
includeEmulatorAbis=true
```

> **Remove that flag before you build anything you intend to publish.** It applies to *every* build type from this checkout, release included, and a forgotten flag ships ~24 MB of unusable emulator libraries to every user.

Then `flutter run` or `flutter build apk --release` as usual.

## Changing the logo, splash or banner

Every image of the brand — both launcher icons, the adaptive and monochrome layers, the iOS AppIcon set, the tvOS brand assets, the Android TV banner, the Top Shelf images, the splash mark and the in-app picker previews — is generated from one description of the mark:

```bash
python tool/gen_brand_assets.py   # run from the repository root; needs Pillow
```

Edit the geometry in that script, not the PNGs. It is deterministic, so re-running it on an unchanged tree writes identical bytes and leaves git clean.

Do **not** use `dart run flutter_launcher_icons` as the regeneration path. That key is still in `pubspec.yaml` because the package is a dev dependency and people reach for it out of habit, but it only knows about one flat source image — it would overwrite the iOS set and the Android mipmaps and silently drop the adaptive, monochrome, second-slot and TV assets.

Two things the script's filename choices will trip you up on:

- The **brand mark is `plain`** (the book and ribbon, no cat). The cat is the alternate, reachable from Settings → Interface. That is one constant — `PRIMARY` at the top of the script — and the `SLOTS` table below it maps each frozen icon id to the artwork it currently carries.
- Icon **ids and activity-alias names are frozen**, the artwork they point at is not. The default slot's id is still `crescent` and its alias is still `MainActivityCrescent`, while the mipmap it wears is `ic_launcher_plain`. Ids are written to users' phones; resource names are internal. Which mark an id carries has already changed more than once, so `SLOTS`, `AppIconService.options` and the manifest's `android:icon` on each alias have to agree — change one and you must change all three.

Android adaptive icons use PNG layers here, not vectors as they once did, because the mark carries a soft drop shadow a flat `VectorDrawable` cannot express.

If you change the plate gradient, `ic_launcher_bg` in `android/app/src/main/res/values/colors.xml` has to move with it — it is the flat background layer behind the masked artwork.

## Novel-only flag

Anime and manga code is intentionally still compiled. Don't delete those enum cases or branches; gate behavior through `lib/core/mode/novel_only.dart`. See [FORK.md](FORK.md) for why.

## Broken sources

Fixes for a broken scraper go to the [plugins repository](https://github.com/apauruseya786er/plugins) as a pull request, not here.

## Adding tests

Cover the behaviour you changed, not the implementation. The suite's value depends on it staying honest: a test that asserts a widget renders its text is what would have caught a reader that shipped a blank chapter while every other test passed.