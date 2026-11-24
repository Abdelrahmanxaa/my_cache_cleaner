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
- `WQTools.*`: Apps-screen tools: version history, IPA library, export all IPAs.
- `*.lproj/Localizable.strings`: 14 languages. `examples/inspectors/`: inspector samples.
- `tests/`: host regression suites (`run_all_tests.sh`; needs macOS clang). `build.sh` builds the IPA and runs them first.

## Behavior notes
- Folder sizes are always on (no setting). Measured in the background, cached 10 min.
- Settings: two screens in `main.m` (Prism `WQPrismSettingsViewController`, classic list in the home controller). Row numbers are hard-coded; change them together.

- Export IPA (WQApps.m `exportIPA:`): copies an installed app's .app into Documents/IPAs as a Payload/ ZIP. Reports encryption (cryptid) but never decrypts.
- Files tab (main.m `WQExplorerViewController`): New Design only; embeds a WQNavigationController at `/` under a shortcuts row and path bar.

## Repository
Private GitHub repo `Abdelrahmanxaa/my_cache_cleaner` (since 2026-11-25), remote `origin`, branch `main`. Plain `git push` works (Git Credential Manager); never ask for or paste tokens. No `gh` CLI. New repos are created on github.com with Claude in Chrome. No Co-Authored-By trailers.

## Build / run
macOS only: `bash build.sh` (or `tests/run_all_tests.sh`). Not buildable on this Windows machine.
