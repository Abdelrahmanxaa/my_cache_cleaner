# AGENTS.md

**WQ Files** ("Worse Query Files"): an iOS 26/27 file browser, app data manager
and cache cleaner (Objective-C, UIKit). Upstream: github.com/kolbicz/WQFiles.

## Structure
- `main.m`: app entry, classic + "Prism" (new design) UIs, folder browser
  (`WQDirViewController`), settings screens, About alert, search results.
- `WQTheme.*`: themes (built-in, custom color, imported `.wqtheme`; samples in `themes/`).
- `WQUI.*`: shared UI helpers (`wq_size_text`, alerts).
- `WQAccess.*`, `WQAccessSafety.h`: filesystem access, `wq_measure_tree` (folder byte size).
- `WQApps`, `WQCache`, `WQArchive`, `WQTrash`, `WQSharing`, `WQWebServer` (Wi-Fi Sharing pages), etc.
- `WQTools.*`: Apps-screen tools: version history, IPA library, export all IPAs. `WQFolderTools.m` (declared in WQTools.h): folder tools menu (storage, duplicates, old files, compare, bulk rename), tags, backup cleanup, app info. Both files are listed in build.sh and the tests/*.sh source lists.
- `*.lproj/Localizable.strings`: 14 languages. `examples/inspectors/`: inspector samples.
- `tests/`: host regression suites (`run_all_tests.sh`; needs macOS clang). `build.sh` builds the IPA and runs them first.

## Behavior notes
- Folder sizes are always on (no setting). Measured in the background, cached 10 min.
- Settings: two screens in `main.m` (Prism `WQPrismSettingsViewController`, classic list in the home controller). Row numbers are hard-coded; change them together.

- Export IPA (WQApps.m `exportIPA:`): copies an installed app's .app into Documents/IPAs as a Payload/ ZIP. Reports encryption (cryptid) but never decrypts.
- Files tab (main.m `WQExplorerViewController`): New Design only; embeds a WQNavigationController at `/` under a shortcuts row and path bar.

## Identifiers
Bundle ID `cz.kolbi.wqfiles.5YSG8V3F7L` (Info.plist) and App Group `group.cz.kolbi.wqfiles.5YSG8V3F7L` (entitlements.plist) belong to the owner's team. Upstream used `cz.kolbi.wqfiles` / `group.cz.kolbi.wqfiles`. `examples/entitlements/app-group.plist` is an entitlements file for signers that import one.

## Repository
GitHub repo (kept PUBLIC on the owner's instruction until the work is finished; make it private only when he asks) `Abdelrahmanxaa/my_cache_cleaner` (since 2026-11-25), remote `origin`, branch `main`. Plain `git push` works (Git Credential Manager); never ask for or paste tokens. No `gh` CLI. New repos are created on github.com with Claude in Chrome. No Co-Authored-By trailers.

## Build / run
macOS only: `bash build.sh` (or `tests/run_all_tests.sh`). Not buildable on this Windows machine.
