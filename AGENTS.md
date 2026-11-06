# AGENTS.md

Notes for coding agents (Codex, Claude, …) working in this repo.

## What this is
WasThat: a small native macOS app (Swift 6 / SwiftUI, macOS 14.2+) that identifies recent notifications and sounds. See [`PLAN.md`](PLAN.md) for the architecture, decisions and findings. **Current task handoffs live in [`docs/handoff/`](docs/handoff/).**

## Build
```bash
xcodegen generate     # WasThat.xcodeproj is generated from project.yml and git-ignored
xcodebuild -project WasThat.xcodeproj -scheme WasThat -configuration Debug -derivedDataPath build/DerivedData build
scripts/release.sh --skip-notarize   # archive + Developer ID export + signature checks
```
- Two targets: `WasThat` (menu bar UI) and `WasThatAgent` (headless recorder, embedded at `Contents/Library/LoginItems`). `Shared/` is compiled into both.
- Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Mark plain data/IO types `nonisolated`.
- Not sandboxed (it needs `/usr/bin/log`, Full Disk Access and audio taps), with the hardened runtime on. Never add `get-task-allow` to Release.
- Keep the app small. The budget is under 15 MB and it's about 1.2 MB today. Don't add third-party dependencies without the owner's OK (Sparkle is planned).

## Gotchas
- The repo path contains an emoji and an apostrophe, so quote every path.
- zsh's `log` builtin shadows the tool, so use `/usr/bin/log`.
- On macOS 27, `kAudioProcessPropertyIsRunningOutput` doesn't notify listeners. Also listen on `kAudioProcessPropertyIsRunning`.
- A denied System Audio Recording permission makes taps fail **silently** (`noErr`, zero samples).
- Unified log lines can contain personal data (phone numbers in URLs, etc.). Scrub before storing, printing or committing.

## Rules
- Don't change macOS privacy or security settings (TCC, Gatekeeper) or answer permission prompts. Ask the owner.
- Never handle Apple ID passwords or commit secrets. Notarization uses the owner's keychain profile `WasThat-notary`.
- Work on a branch. Don't push to `main`, tag, publish releases or upload builds without the owner's OK.
- License is GPL-3.0. Only add code and assets with compatible licenses.
