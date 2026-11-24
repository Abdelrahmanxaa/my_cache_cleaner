# PROJECT_LOG

**Current version:** app 0.9.20 (source.json/Info.plist untouched); working tree 0.9.20+local1.

## State
- Folder sizes always shown (native lists, search results, Wi-Fi Sharing web pages).
- Not compiled or tested here: no macOS toolchain on this machine. Build and run `tests/run_all_tests.sh` on a Mac.

## Future tasks (user deferred, details still to be given)
- Version history of installed apps (name, bundle ID, version, build, date changed) - offered, not built
- GitHub workflow: build any tag/commit via input, keep each build as a GitHub Release - offered, not built
- Theme changes
- Settings changes
- About changes

## Open work (user asked for all of this on 2026-11-24; items not yet built)
Done in local5: version history + update flag, IPA library, Export All IPAs, About credit.
Still to build: storage breakdown, duplicate finder, old-files finder, clean preview, compare folders/backups, bulk rename, tags, auto-backup retention, read-only sharing, Shortcuts/widgets, app info (entitlements) screen, Keychain/UserDefaults viewer, translations of new strings.
Already in the app before (not rebuilt): plist/SQLite/hex/text viewers, Largest Files, sharing password + QR + uploads, Recent, Log.
GitHub push, CI build and Telegram delivery: blocked until the user gives GitHub access (no `gh`, no git identity/credentials on this machine). Telegram chat id is in ~/.claude/channels/telegram/access.json.

## Repository
- GitHub (private): https://github.com/Abdelrahmanxaa/my_cache_cleaner (created and first pushed 2026-11-25, branch `main`). Push with plain `git push` (Git Credential Manager holds the login; no `gh`). Commits carry no Co-Authored-By trailer (user's rule).

## Changelog
- 2026-11-25 (0.9.20+local5): new `WQTools.m/.h`. Apps screen gets a Tools menu (wrench): Version History (reads each installed app's Info.plist, stores history in Application Support/VersionHistory.plist, changed apps listed first with "old → new"), IPA Library (Documents/IPAs: share, swipe delete with confirm), Export All IPAs (sequential, progress, cancel). About (both designs and the classic alert) shows "Modified by abdelrahmanxaa". App Group failure text now explains ESign/Feather/Sideloadly (the app can't grant itself a group; the signer's profile must contain one). WQTools.m added to build.sh and the test scripts. Not compiled.
- 2026-11-24 (0.9.20+local4): new Files tab (New Design only). `WQExplorerViewController` in main.m: shortcut chips + tappable path bar above an embedded WQNavigationController (`hidesHomeButton`) rooted at a WQDirViewController on `/`. Folder screens post `kWQDirDidAppearNotification` and expose `currentPath` (WQDir.h) so the bar follows. Tab added as the 5th (index 4), so existing tab indexes are unchanged. Classic design has no Files tab (it already lists the locations). Not compiled; whether `/` lists on every iOS build is unverified.
- 2026-11-24 (0.9.20+local3): Export IPA. New `wq_zip_write_under` (WQArchive) puts items under a `Payload/` folder; `exportIPA:` in WQApps.m (Apps tap sheet + long-press menu, only where bundle folders open) reads Info.plist and the executable's cryptid (read-only, FairPlay status shown in the confirm dialog), then zips the .app to Documents/IPAs/Name_version_bBuild.ipa with Cancel, progress and Share. Never decrypts or alters files (decryption deliberately not implemented). 4 GB ZIP limit applies. Test added in tests/WQArchiveTests.m. Not compiled; new strings fall back to English.
- 2026-11-24 (0.9.20+local2): risky deletes. After the normal Delete confirmation, deleting anything that can harm an app, WQ Files or iOS (other apps' data/settings/databases, app bundles, system paths, WQ's own data, WQ backups, container metadata plist) asks a second time with the reasons (`wq_delete_risk_text` / `wq_confirm_risky_delete` in main.m; caches and tmp are exempt). Apps → Clear Without Backup also asks twice. Unmeasured folders show "Calculating…". New strings fall back to English (not added to .lproj yet). Not compiled.
- 2026-11-24: added `.github/workflows/build-ipa.yml` (manual-trigger macOS build, uploads WQFiles.ipa; never run yet). Plan: public GitHub repo as a modified fork of kolbicz/WQFiles (GPL-3.0-or-later; keep credits and LICENSE, note the changes). Do not push `.claude-flow/`.
- 2026-11-24 (0.9.20+local1): folder sizes always on. Removed the "Show Folder Sizes" switch from both settings screens (rows renumbered); `wq_show_folder_sizes()` now returns YES. Web sharing listing measures folders with a 3 s budget; search results show file sizes and cached folder sizes. README updated. The now-unused localized strings for the old switch are left in the .strings files.
