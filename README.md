# WasThat

WasThat is a small native macOS app under development. Its goal is to explain which app or system event caused a recent sound.

**Version 0.1.0 is an M0 pre-alpha developer preview.** It contains a menu bar panel, a history window, and a process-audio recorder. The panel and history show raw recorded events. Notification identification, sound correlation, and mute actions are future work.

[Download WasThat.dmg](https://github.com/iacompa/WasThat/releases/download/v0.1.0/WasThat.dmg) · [Release notes](docs/release/v0.1.0-notes.md) · [Source for v0.1.0](https://github.com/iacompa/WasThat/tree/v0.1.0) · [GPLv3](https://github.com/iacompa/WasThat/blob/v0.1.0/LICENSE)

## Install and try the preview

The app targets **macOS 14.2 or later**. The download contains both Apple silicon (`arm64`) and Intel (`x86_64`) binaries. IA COMPA LLC signed the app and DMG with Developer ID. Both artifacts include stapled Apple notarization tickets.

1. Download the DMG.
2. Open the DMG.
3. Drag WasThat into Applications.
4. Open WasThat from Applications.
5. Select the question-mark bubble in the menu bar.
6. Select **Open full log** to show the history window.

**The recorder is not automatically enabled in M0.** This version has no recorder toggle and does not register its embedded login item. Opening the app alone does not collect events, so a fresh installation normally shows an empty list.

The panel can show **“Scan-only mode”** when the login item is unregistered. M0 does not scan past system logs. That label describes the current login-item status only.

For developer evaluation, start the embedded agent in a separate Terminal window:

```bash
"/Applications/WasThat.app/Contents/Library/LoginItems/WasThatAgent.app/Contents/MacOS/WasThatAgent"
```

Keep that Terminal session open while you use the preview. Press **Control-C** in that Terminal to stop the agent. This command does not register a login item. Quitting the menu bar app does not stop this separately started agent.

## What M0 does

- The agent observes process audio activity through CoreAudio property listeners.
- The agent stores `audio_start` and `audio_stop` events, with process names, bundle IDs, timestamps, and durations.
- The panel shows recent start events. The history window shows raw events from the last hour, with a maximum of 500 rows.
- The app and agent share a local SQLite database at `~/Library/Application Support/WasThat/events.sqlite`.
- The agent removes rows older than seven days when it starts. Continuous retention maintenance is future work.

The current app does not save audio samples. It has no analytics, account, or automatic update service. Event data stays on your Mac. The GitHub link opens the repository in your browser.

## Limits and future work

This preview does not yet identify notification senders, explain suppression reasons, correlate events, or identify individual browser tabs. It does not provide mute actions, settings links, replay, rarity ranking, a global hotkey, onboarding, or a recorder control.

The separate feasibility tools in `spikes/` are developer probes. They are not features of the distributed app. Two mute probes recorded peak 0 and detected no nonzero audio, and the owner's listening checks were inconclusive. Per-app muting remains unproved. The final notification probe observed suppressed playback. Audible notification playback remains unproved.

Recorder smoke checks passed on Apple silicon with macOS 27.0.1. The agent recorded start/stop pairs for test sounds and showed no measured CPU-time increase during a 60-second idle check. One shorter duration did not recur in a follow-up. Intel hardware and older supported macOS versions were not tested.

See the [M0 verification report](docs/test-reports/2026-11-m0-codex.md) for results and remaining uncertainty. [PLAN.md](PLAN.md) describes the future product and roadmap. Its planned features are not a list of shipped features.

## Download verification

Version 0.1.0, build 1, contains a **1,129,011-byte DMG** (about 1.08 MiB). The release includes identical-byte assets named `WasThat.dmg` and `WasThat-0.1.0.dmg`.

```text
SHA-256: 229cfef20e15d3a7a07d1ee01c6ab86d06c9c411e4236e2d2ddc632de33bdde9
```

To check a downloaded copy:

```bash
shasum -a 256 "$HOME/Downloads/WasThat.dmg"
```

## Build from source

The project uses Swift 6, SwiftUI, AppKit, CoreAudio, and system SQLite. It has no third-party runtime dependencies. Local verification used Xcode 27.1, Swift 6.4, and XcodeGen 2.46.0.

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if it is absent. Then run these commands from the repository:

```bash
xcodegen generate
xcodebuild -project WasThat.xcodeproj -scheme WasThat -configuration Debug -derivedDataPath build/DerivedData build
```

The generated Xcode project is not committed. [`project.yml`](project.yml) defines both targets. The project specifies Developer ID signing for IA COMPA LLC. A different developer must configure their own signing identity for signed builds.

## Repository layout

| Path | Contents |
|---|---|
| `App/` | SwiftUI menu bar panel, history window, and comic design primitives |
| `Agent/` | Embedded headless recorder |
| `Shared/` | Event model, identifiers, and SQLite store |
| `Resources/` | App icon and assets |
| `spikes/` | Separate feasibility probes and the M0 test app |
| `scripts/` | Build, signing, notarization, and DMG script |
| `docs/` | Handoffs, verification evidence, and release notes |
| `design/icon/` | Icon sources and variants |

## License

WasThat is free software under the [GNU General Public License, version 3](https://github.com/iacompa/WasThat/blob/v0.1.0/LICENSE). © 2026 IA COMPA LLC.

The [v0.1.0 source tree](https://github.com/iacompa/WasThat/tree/v0.1.0) and [source archive](https://github.com/iacompa/WasThat/archive/refs/tags/v0.1.0.tar.gz) provide the source for this release. The repository includes the build configuration and scripts. The GPL provides the license terms and warranty disclaimer.
