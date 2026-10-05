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

The scraper runtime is a native library, `quickjs_c_bridge`. Around 28 of the tests — everything under `test/core/lnreader/`, plus `js_engine_test.dart`, `js_reading_provider_names_test.dart` and `cf_solve_needed_test.dart` — execute real plugin JavaScript through it.

If that library is not built for the current platform, those tests fail with:

```
Failed to load dynamic library 'quickjs_c_bridge.dll': The specified module could not be found.
```

That is a missing build artifact, not a broken test, and not something your change caused. **CI does not currently build this library**, so the Test job is red on `main` for this reason and will stay red until it does. Judge your change by whether it adds failures beyond that known set.

## Testing on an emulator

Release builds package **arm64-v8a and armeabi-v7a only**. An x86_64 emulator cannot launch them — every native library in the APK is stripped, and the launch dies looking for `lib/x86_64/libflutter.so`. The x86_64 libraries are dead weight on real devices, so they are not shipped by default.

To opt back in for a local emulator run, add this to `android/local.properties` (git-ignored, so it cannot reach CI or another developer):

```properties
includeEmulatorAbis=true
```

> **Remove that flag before you build anything you intend to publish.** It applies to *every* build type from this checkout, release included, and a forgotten flag ships ~24 MB of unusable emulator libraries to every user.

Then `flutter run` or `flutter build apk --release` as usual.

## Novel-only flag

Anime and manga code is intentionally still compiled. Don't delete those enum cases or branches; gate behavior through `lib/core/mode/novel_only.dart`. See [FORK.md](FORK.md) for why.

## Broken sources

Fixes for a broken scraper go to the [plugins repository](https://github.com/apauruseya786er/plugins) as a pull request, not here.

## Adding tests

Cover the behaviour you changed, not the implementation. The suite's value depends on it staying honest: a test that asserts a widget renders its text is what would have caught a reader that shipped a blank chapter while every other test passed.