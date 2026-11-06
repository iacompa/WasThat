# WasThat: build plan

> *You hear a ding. You have no idea what it was. You open WasThat and it tells you.*

A tiny native macOS app (target: **under 15 MB**) that identifies every recent notification and sound source on your Mac. It explains each one ("Charger connected", "Slack in-app ping", "Messages, but silenced by Focus") and lets you mute it or jump straight to the right settings. It has an original vintage cel-shaded comic look with loot-rarity tiers.

Repo: https://github.com/iacompa/WasThat · License: **GPL-3.0** · Free download, Developer ID signed + notarized.

---

## 1. Decisions locked in

| Topic | Decision |
|---|---|
| Recording mode | **Background recorder on by default.** Settings can switch to **Scan-only** (nothing runs in the background; the last hour is scanned on open). |
| How it opens | **Both:** a menu bar panel with a global hotkey for quick checks, plus a full history window that shows a Dock icon only while open. |
| Muting | **Audio mute + settings link:** per-app audio mute through Apple's audio API (timed), plus a deep link to that app's Notification settings for permanent changes. |
| Art style | **Full comic + loot rarity:** ink outlines, halftone and hatching, stencil comic font, scan animation, and Common → Legendary tiers. |
| Min macOS | **14.2 Sonoma** and newer |
| License | **Free, GPL-3.0** |
| Distribution | Website download (DMG), Developer ID + notarization (account already enrolled), GitHub link inside the app |
| Notification text | **Optional unlock** through Full Disk Access. The app works fully without it. |
| Icon | Three variants in `design/icon/`. Default is **B "Perch"** unless changed. |

---

## 2. What we proved on this Mac (macOS 27.0.1, 2026-11-06)

| Question | Result | Permission needed |
|---|---|---|
| Can we see which app sent each notification, after the fact? | **Yes.** The unified log (`usernoted` / `NotificationCenter`) records `Delivering`, `Presenting … as banner/none`, and `Playing` / `Not playing sound for <app:"bundle.id">` with the reason (`isMuted`, Focus `delay delivery`). The test Mac's log held 80+ notification attempts from 7 apps in 24 h, each with its app ID, all marked silenced by Focus. | None (admin user, non-sandboxed) |
| Can we see notification **text**? | Not from the log (redacted as `<private>`). It's in `~/Library/Group Containers/group.com.apple.usernoted/db2/db`, which returns "Operation not permitted" without Full Disk Access. | Full Disk Access (optional unlock) |
| Can we catch **non-notification** sounds live? | **Yes.** CoreAudio's process object list (31 clients visible) plus `kAudioProcessPropertyIsRunningOutput` flagged `afplay` the instant it started playing. Probe: `spikes/audioprobe.swift`. | None |
| Can we catch non-notification sounds **retroactively**? | **Best-effort.** `coreaudiod` logs `releasing power assertion … on behalf of <pid> … for 1.37` (seconds of playback). The pid can be resolved to a process name from other log lines in the same window. | None |

**Takeaway:** notifications are fully recoverable from the log even when WasThat wasn't running. Other sounds (charger chime, Slack/Discord/Teams pings, browser tabs, `afplay`, alert beeps) are only reliable while the background recorder is running, which is why it's on by default.

---

## 3. Architecture

```
WasThat.app  (UI, runs only when opened, LSUIElement + on-demand Dock icon)
 ├─ Contents/MacOS/WasThat
 └─ Contents/Library/LoginItems/WasThatAgent.app   (headless recorder, SMAppService)
          │
          ▼
~/Library/Application Support/WasThat/events.sqlite   (WAL, system libsqlite3, 7-day retention)
          ▲                         ▲
   Agent writes events        UI reads + writes "mute requests" → notify_post("com.wasthat.changed")
```

### 3.1 Agent: `WasThatAgent` (headless, about 0% CPU idle, target under 10 MB RAM)
Event-driven only; it never polls.

| Source | API | What it yields |
|---|---|---|
| Audio clients | `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyProcessObjectList` and on each process's `kAudioProcessPropertyIsRunningOutput` | `audio_start` / `audio_stop`: pid, bundle ID, exec name, duration |
| Notifications (live) | `OSLogStore` streaming, or `/usr/bin/log stream --style ndjson` with a tight predicate on `usernoted` / `NotificationCenter` | `notif_delivered`, `notif_presented(style)`, `notif_sound(played/blocked + reason)`, `notif_removed` |
| Power | `IOPSNotificationCreateRunLoopSource` | `power_connected` / `power_disconnected` |
| USB / Thunderbolt | IOKit `IOServiceAddMatchingNotification` | `device_attached` / `device_detached` |
| Bluetooth | IOBluetooth connect notifications | `bt_connected` / `bt_disconnected` |
| Focus / volume | log (`com.apple.donotdisturb`), CoreAudio volume/mute listener | context for "why didn't I hear it" |
| Mutes | reads the `mutes` table and holds CoreAudio process taps | applies and expires timed mutes |

### 3.2 Correlator: turns raw events into "WHAT WAS THAT" cards
Events that start within ±1.5 s of each other merge into one **Sighting**:

| Pattern | Card title |
|---|---|
| `NotificationCenter` audio_start + `notif_sound(played, app X)` | **Notification from X** |
| `PowerChime` audio_start + `power_connected` | **Charger connected chime** |
| audio_start by Slack/Discord/Teams/browser, no notif record | **In-app sound from X** (not a system notification) |
| `notif_sound(blocked)` | **X tried to ping you** (silenced by Focus or mute), shown dimmed |
| audio from a process with no UI or no bundle | **Hidden process X** (Epic tier) |
| unknown | **Unidentified: report it** (opens a prefilled GitHub issue with the process name only) |

There's a bundled `known-sounds.json` catalog (PowerChime, screenshot, alert beeps, AirDrop, Find My, FaceTime and so on) with friendly names, the sound file path for **Replay**, and any off-switch recipe.

### 3.3 Scan-only mode (setting)
The agent is unregistered. When the UI opens it runs `log show --last 1h` on the same predicates, plus the `coreaudiod` power-assertion lines (best-effort audio), and feeds the same correlator. A banner says: *"Scan-only: in-app sounds may be missed."*

### 3.4 Muting (honest scope)
- **Per-app audio mute (timed):** `CATapDescription` with `muteBehavior = .muted` on that app's process object(s). The agent holds the tap until the timer ends and re-applies it by bundle ID if the app relaunches. Needs a one-time **System Audio Recording** permission (`NSAudioCaptureUsageDescription`).
- **Notification sounds are played by `NotificationCenter`, not by the sending app.** So:
  - **Permanent, per app:** deep link `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<bundleID>`.
  - **Timed:** "Silence *all* notification sounds for 1h / 1d / custom" mutes the `NotificationCenter` process.
  - A per-app *timed* notification mute is **not possible** without the experimental auto-flip we skipped. It can be revisited later.
- **Known system sounds:** catalog recipes, e.g. `defaults write com.apple.PowerChime ChimeOnNoBattery -bool true; killall PowerChime`, run only after the user confirms.

### 3.5 "Still up" (persistent notifications)
- Without Full Disk Access: per-app counts of notifications still in Notification Center, tracked from delivered/removed log events.
- With Full Disk Access: the full list with title and body from the usernoted DB, read-only. Actions: open settings, or switch that app from Alerts to Banners (deep link).

---

## 4. UI spec (original cel-shaded comic, no game IP)

**Design system**
- **Ink:** 3–4 pt near-black outlines on every card and button, with a slight offset "print misregistration" shadow.
- **Texture:** halftone dots and cross-hatching drawn **procedurally** (SwiftUI `Canvas` / Metal `layerEffect` shader), so it costs almost nothing in app size.
- **Type:** one open-license display font, e.g. *Bangers* (OFL) or *Black Ops One* (OFL), under 200 KB, plus SF for body text.
- **Palette:** dusty wasteland base (sand `#E9D8A6`, rust `#C8553D`, ink `#14110F`) with **rarity colors**: Common `#C9C9C9`, Uncommon `#5FD35F`, Rare `#3EA6FF`, Epic `#A35BFF`, Legendary `#FF9F1C`.
- **Motion:** about 600 ms radar "SCANNING…" sweep on open, layered *over* data that has already loaded (it never delays the answer). Loot-drop bounce on the newest card. Respects Reduce Motion.
- **UI sounds:** off by default. An app about mystery sounds shouldn't make any.
- Dark "night raid" theme by default, plus a light "paper" theme.

**Rarity tiers (how mysterious it is)**
Common = an app you hear from daily · Uncommon = known app, occasional · Rare = system event (charger, USB, Bluetooth) · Epic = hidden or background process · Legendary = first time ever seen.

**Menu bar panel** (about 380×540, opened by click or global hotkey ⌃⌥⌘W, configurable)
```
╔══════════════════════════════════╗
║ ▚▚ WHAT WAS THAT?! ▚▚   (( SCAN ))║
╠══════════════════════════════════╣
║ ★ LEGENDARY ··········· 2 MIN AGO║
║ ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓ ║
║ ┃  POWER CHIME          [▶ REPLAY]║
║ ┃  "Charger connected" sound    ┃ ║
║ ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛ ║
║ [MUTE 1H] [MUTE 1D] [∞] [CUSTOM] [⚙]║
║ ─ COMMON · Messages ····· 9 min  ║
║ ─ RARE   · USB drive ···· 14 min ║
║ ─ (dim) Codex · silenced by Focus║
║ [ OPEN FULL LOG ]        github ↗║
╚══════════════════════════════════╝
```

**Full window** (tabs down the side)
1. **SOUNDS:** a timeline strip (spikes for each sound) above a feed; filters 1h / 24h / 7d, app, and tier.
2. **STILL UP:** notifications sitting in Notification Center.
3. **MUTES:** active mutes with countdowns and an Unmute button.
4. **LOADOUT (Settings):** Recorder vs Scan-only, retention (1 / 7 / 30 days), hotkey, theme, launch at login, updates.
5. **ABOUT:** version, GitHub link, "Report an unidentified sound", GPL notice.

**Onboarding:** a "loadout" screen with three permission upgrades. Each can be skipped and is explained in plain words.
1. Background Recorder (login item), on by default
2. Audio Mute (System Audio Recording), asked the first time you mute
3. Message Text (Full Disk Access), optional unlock

**Menu bar icon:** a monochrome *template* version of the chosen app icon (18 pt). Still to make.

---

## 5. Size budget (universal binary)

| Piece | Est. |
|---|---|
| UI app (Swift/SwiftUI, system frameworks not bundled) | 2–4 MB |
| Agent | ~0.5 MB |
| Sparkle 2 (auto-update) | ~3 MB |
| Font | <0.2 MB |
| App icon (.icns, measured) | 0.7 MB |
| Textures | ~0 (procedural) |
| **Total** | **~6–8 MB** ✅ |

---

## 6. Privacy
Everything stays on the Mac: no analytics and no account. The only network call is Sparkle's update check, which can be turned off. Notification text is read only after the user unlocks it, and is never stored longer than the retention window.

---

## 7. Release pipeline
1. Xcode project generated by **XcodeGen** (`project.yml`), so the diffs stay clean. Two targets: `WasThat` and `WasThatAgent`, both with Hardened Runtime and **not sandboxed** (required for log, FDA and taps, which also rules out the Mac App Store).
2. Sign inside-out with **Developer ID Application**, then `xcrun notarytool submit --wait` and `xcrun stapler staple`.
3. Build a comic-styled DMG with `hdiutil` (no extra dependencies), then sign, notarize and staple it.
4. **GitHub Actions** on a `v*` tag: build, sign (certificate from repo secrets), notarize, attach the DMG to a GitHub Release, and regenerate the Sparkle appcast (EdDSA) on GitHub Pages.
5. The website Download button links to `https://github.com/iacompa/WasThat/releases/latest/download/WasThat.dmg`, a URL that never changes.

---

## 8. Repo layout
```
WasThat/
├─ project.yml              XcodeGen spec
├─ App/                     SwiftUI + AppKit UI (menu bar panel, window, design system)
├─ Agent/                   headless recorder + mute holder
├─ Shared/                  models, SQLite store, correlator, known-sounds catalog
├─ Resources/               font, AppIcon, known-sounds.json
├─ design/icon/             icon variants (A/B/C), make_icns.sh
├─ spikes/                  feasibility probes
├─ scripts/                 build, sign, notarize, dmg
├─ .github/workflows/       release.yml
├─ LICENSE                  GPL-3.0
└─ README.md
```

---

## 9. Milestones
- **M0, Spike (verify unknowns, below)** plus the project skeleton, git init, first push
- **M1, Recorder:** agent, SQLite store, live log + CoreAudio + power/USB sources, correlator, and a plain debug list
- **M2, Comic UI:** design system, menu bar panel, full window, rarity, scan animation, hotkey
- **M3, Actions:** settings deep links, timed audio mutes, Replay, known-sound recipes, Full Disk Access "Still up"
- **M4, Polish:** onboarding loadout, settings (incl. Scan-only), About/GitHub, light theme, accessibility
- **M5, Ship:** signing, notarization, DMG, Sparkle, CI, website link

## 10. Unknowns to settle in M0
1. The exact *positive* log line when a notification sound **does** play (only `Not playing sound…` was seen, because Focus was on), and which process outputs that audio.
2. Whether a tap with `.muted` silences output on its own, or needs a running aggregate device/IOProc. Also whether macOS 27 shows a recording indicator while a mute is held.
3. Whether the `?id=<bundleID>` Notifications deep link still lands on the per-app page on macOS 14.2 → 27.
4. `OSLogStore.local()` in-process vs spawning `/usr/bin/log`: permissions and CPU cost.
5. The schema of the usernoted DB on macOS 14 → 27 (for the Full Disk Access unlock).
6. Hardened-runtime entitlements needed for process taps.
7. How long the unified log keeps `usernoted` lines (retro-scan depth in Scan-only mode).
