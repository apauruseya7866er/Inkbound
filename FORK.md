# How Inkbound differs from Zangetsu

Inkbound is a novel-only fork of [Zangetsu](https://github.com/Spyou/Zangetsu). The reader, source system, downloads, trackers and read-aloud engine are Krishna Vishwakarma's work, carried over intact. This page lists what this fork changes and where to look in the tree.

| | Zangetsu | Inkbound |
|---|---|---|
| Media | Anime · Manga · Novels | Novels only |
| Account | Sign-in, cloud sync, Watch Together | None |
| Data leaves the device | Only if you sign in | Never, unless you export it yourself |
| Second screen | Cast + remote control | Removed |
| Source index | Upstream LNReader | Its own: upstream tracked, fixes published |
| Cloudflare handling | WebView solver | Layered: native TLS, automatic solve, optional external proxy |

## 1. Novel-only, behind one flag

Every gate in the app reads a single flag in [`lib/core/mode/novel_only.dart`](lib/core/mode/novel_only.dart). The anime and manga code is still compiled, not deleted, so it stays type-checked and can be revived by flipping that flag. A real delete isn't possible: `ContentMode`, `ProviderType`, `ZKind` and `MediaKind` are matched exhaustively across hundreds of `switch` expressions, so removing a case breaks compilation everywhere.

## 2. No account, no cloud, no sync

The account layer is removed, not hidden. There is no Supabase reference left in dependency injection. Backups write a plain JSON file to any folder you choose.

## 3. Its own source index

Sources are served from [apauruseya786er/plugins](https://github.com/apauruseya786er/plugins), a fork of the LNReader plugin ecosystem. It tracks upstream and is where this project's scraper fixes are published.

## 4. Upstream ties cut

Links to the original author's donation pages, Discord, website and community prompts are removed, About shows only this project's GitHub, and the updater and font CDNs point at infrastructure this repository controls. `zangetsu.online` is kept only for a share-link redirect that has to resolve for old links.

## 5. Contributors graph

GitHub's contributors graph lists everyone whose commits are reachable from `main`, including the upstream Zangetsu history this fork was built from. Those names are inherited authorship. 59 of the 2,347 commits are this fork's own work. History is not rewritten, because that would break GPL-3.0 attribution and orphan existing forks and pull requests. A [`.mailmap`](.mailmap) merges people who appear under more than one email.

## 6. Version history

The published releases for the 3.0.x line were withdrawn when 4.0.0 shipped, so the releases page carries a single entry. What each earlier version did — including the one that was withdrawn for opening every chapter blank — is written up in [CHANGELOG.md](CHANGELOG.md).