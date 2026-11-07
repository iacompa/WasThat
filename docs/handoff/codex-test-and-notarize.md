# Handoff: test WasThat M0, then notarize it

**From:** Claude (M0 author) · **To:** Codex · **Date:** 2026-11-06 · **Repo:** https://github.com/iacompa/WasThat

## Goal
1. **Test** the M0 build: build checks, the background-recorder smoke test, and the spike feasibility tests.
2. **Notarize** WasThat 0.1.0 (build 1): a stapled app plus a stapled DMG that Gatekeeper accepts.

The deliverable is a test report, a notarized DMG in `build/release/`, and any fixes on a branch. **Don't publish the DMG anywhere.**

## Read first (10 min)
- [`PLAN.md`](../../PLAN.md) §3 (architecture) and §10 (M0 findings, the baseline you're re-testing)
- [`AGENTS.md`](../../AGENTS.md) (repo rules)
- [`scripts/release.sh`](../../scripts/release.sh) (does the whole notarization)

## Where this must run
**On the owner's Mac, locally.** The signing certificate `Developer ID Application: IA COMPA LLC (L98358T6WZ)` lives in that login keychain. A cloud sandbox can't sign or notarize.

- Repo: `/Volumes/💾Mike's SSD X31/2-Apps/Wasthat`. The path contains an emoji and an apostrophe, so **always quote paths**.
- Tools (verified 2026-11-06): macOS 27.0.1, Xcode 27.1, Swift 6.4, XcodeGen 2.46 at `/opt/homebrew/bin/xcodegen`, and `gh` logged in as `iacompa`.
- **Sandbox:** this task needs network access (Apple notary and timestamp servers), keychain access, and writes to `~/Library/Application Support/WasThat`. The default workspace-write sandbox blocks those. Run with full access, or get each such command approved.
- In zsh, `log` is a shell builtin. Always call **`/usr/bin/log`**.

## Hard rules
- **Never change macOS privacy or security settings** (TCC, Gatekeeper, `tccutil`, `spctl --master-disable`), and never click permission prompts. Ask the owner.
- **Never ask for, type or store Apple ID passwords or keys.** The owner creates the notary profile (step 2.1).
- **Never commit secrets** (`.p8`, passwords, profiles) or anything from `~/Library`.
- Work on branch **`codex/test-and-notarize`**. **Don't push, merge to `main`, create a release, or upload the DMG** without the owner's OK.
- Some tests play short sounds on the speakers. That's expected.

## Owner actions you will need (stop and ask)
| When | Ask the owner to… |
|---|---|
| Before 1.3 (mute) | Open System Settings → Privacy & Security → Screen & System Audio Recording, and switch on **WasThat Spike** under "System Audio Recording Only". At M0 it was **denied**, so the mute is inert. |
| During 1.3 (mute) | Listen for about 13 s and say which phases went silent, and whether a recording indicator appeared in the menu bar. |
| Before 2.2 | Run `xcrun notarytool store-credentials WasThat-notary --apple-id <their Apple ID> --team-id L98358T6WZ` and enter an app-specific password from account.apple.com. Alternatively they can use an App Store Connect API key: `--key … --key-id … --issuer …`. |
| After 2.3 | Approve before anything is pushed or published. |

---

## Part 1: Test

### 1.1 Build checks
```bash
cd "/Volumes/💾Mike's SSD X31/2-Apps/Wasthat"
git checkout -b codex/test-and-notarize
xcodegen generate
xcodebuild -project WasThat.xcodeproj -scheme WasThat -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning:.*\.swift|BUILD"
scripts/release.sh --skip-notarize
```
**Pass when:**
- Both builds show `BUILD SUCCEEDED` with **no Swift warnings**.
- The dry run prints `ok: WasThat.app`, `ok: WasThatAgent.app`, `archs: x86_64 arm64`, and a size of about **1.2 MB**.

The dry run already checks each bundle for Developer ID, team `L98358T6WZ`, a secure timestamp, the hardened runtime and no `get-task-allow`.

### 1.2 Recorder smoke test (no login item, no permissions)
This runs the exported agent directly, plays a sound, and reads what it recorded:
```bash
A="build/release/export/WasThat.app/Contents/Library/LoginItems/WasThatAgent.app/Contents/MacOS/WasThatAgent"
"$A" & P=$!; perl -e 'select(undef,undef,undef,1.5)'
afplay /System/Library/Sounds/Tink.aiff; perl -e 'select(undef,undef,undef,1.5)'
kill $P; wait $P 2>/dev/null
sqlite3 -header -column ~/Library/Application\ Support/WasThat/events.sqlite \
  "SELECT strftime('%H:%M:%S', time, 'unixepoch', 'localtime') AS at, kind, process, detail FROM events ORDER BY id DESC LIMIT 4"
```
**Pass when:** the newest two rows are `audio_start afplay` and `audio_stop afplay`, with a `detail` duration of about 1.0–1.6 s. Baseline: `1.36`.

Context: on macOS 27, `kAudioProcessPropertyIsRunningOutput` **never fires a property listener**. `AudioWatcher` therefore also listens on `kAudioProcessPropertyIsRunning`. That bug was fixed in this handoff's commit, so if this test fails, check that first.

Extra checks:
- Play two sounds back to back. You should get two start/stop pairs.
- Leave the agent idle for 60 s. Its CPU time should stay at about 0 (`ps -o time= -p $P`).

### 1.3 Spike tests (unattended mode)
```bash
spikes/SpikeApp/build.sh
R=~/Library/Application\ Support/WasThat/spike-results.jsonl
open -W "spikes/SpikeApp/build/WasThat Spike.app" --args --auto notif   # ~8 s
open -W "spikes/SpikeApp/build/WasThat Spike.app" --args --auto mute    # ~13 s of soft beeps
tail -2 "$R"
```
Each run appends one JSON line.

**Notification test (`notification-sound`).** The spike stores fixed facts in `interestingLines`. It does not store original log payloads.

- `spike presentation: style=banner, soundRequested=true` means the synthetic spike notification requested sound.
- `spike playback: decision=notPlaying, isMuted=true` identifies an observed suppression decision for the spike.
- A spike suppression fact can identify `displayShared` or `DND`. These correspond to screen sharing or mirroring, and Focus.
- Facts labeled `suppression context` lack direct spike attribution. Record them as context, not proof of the spike's suppression reason.

An absent suppression fact does not prove playback. The log collection or parser can miss an event.
The `audioStarts` list includes unrelated processes. A nonempty list alone does not prove notification playback.
Require the spike's presentation chain and attributed notification output or owner confirmation before closing PLAN §10 row 1.
Record an explicit `spike playback: decision=playing` fact when available.
Otherwise report the result as inconclusive and preserve the pending positive case.
Copy only fixed facts and relevant process names into the report. Never copy original personal log payloads.
The owner decides whether to end Focus or screen sharing.

**Mute test (`mute-tap`).** Every `create…`/`destroy…` status should be `noErr`.
- `tapCapturedAudio: false` / `tapCapturedPeakC: 0` means phase C detected no nonzero audio. The measurement does not count callbacks or sample frames. First check tap, aggregate, IOProc, device-start statuses, and source playback. A zero peak alone does not identify the cause. The M0 baseline had denied permission. Ask the owner to check that permission when the other checks pass, then rerun.
- `tapCapturedAudio: true` means the phase C peak exceeded 0.001 in the current callback interpretation. It does not prove that phase B muted the source. Rerun **while the owner listens**:

| Phase | Time | Label | Expected |
|---|---|---|---|
| A | 0–3 s | green | audible |
| B | 3–6.5 s | orange | tap-only mute |
| C | 6.5–10 s | red | tap + running aggregate device |
| D | 10–13 s | green | audible again |

Record which phases were silent and whether any indicator appeared. Also check `/usr/bin/log show --last 5m --predicate 'process == "tccd" AND eventMessage CONTAINS "wasthat.spike"'` for a **Microphone** check (`kTCCServiceMicrophone`). We want the tap-only path (B) to work without one.

### 1.4 Report
Write **`docs/test-reports/2026-11-m0-codex.md`** with:
- Pass/fail for each check above, and the commands' key output.
- Updates for PLAN.md §10 rows 1 and 2 (edit PLAN.md too if you got new answers).
- Anything that surprised you.

Don't paste notification content or phone numbers into the report. The spike scrubs its own output, but raw `log` output does not.

---

## Part 2: Notarize

### 2.1 Check credentials
```bash
xcrun notarytool history --keychain-profile WasThat-notary
```
If it says *No Keychain password item found*, **stop** and ask the owner to run the `store-credentials` command from the owner actions table. Don't continue until it works.

### 2.2 Run the release script
```bash
scripts/release.sh
```
It archives, exports with Developer ID and verifies both bundles. Then it zips the app, notarizes it, staples it and checks it with `spctl`. Finally it builds a DMG (app + `/Applications` link), signs it with a timestamp, notarizes and staples it, and checks it with `spctl`. Logs go to `build/release/*.log`.

**If a submission is rejected:**
```bash
xcrun notarytool log <submission-id> --keychain-profile WasThat-notary
```
Typical causes are a missing timestamp, `get-task-allow`, an unsigned nested binary, or a missing hardened runtime. Fix them in `project.yml` or the script, not by hand on the bundle. If you rebuild something that was already submitted, bump `CURRENT_PROJECT_VERSION` in `project.yml`.

### 2.3 Verify like a real download
```bash
spctl -a -t exec -vv build/release/export/WasThat.app
xcrun stapler validate build/release/WasThat-0.1.0.dmg
cp build/release/WasThat-0.1.0.dmg /tmp/wt-test.dmg
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" /tmp/wt-test.dmg
spctl -a -t open --context context:primary-signature -vv /tmp/wt-test.dmg
hdiutil attach /tmp/wt-test.dmg -nobrowse -mountpoint /tmp/wt-mnt
spctl -a -t exec -vv /tmp/wt-mnt/WasThat.app
open /tmp/wt-mnt/WasThat.app; perl -e 'select(undef,undef,undef,3)'; pgrep -x WasThat
osascript -e 'quit app "WasThat"' 2>/dev/null || pkill -x WasThat
hdiutil detach /tmp/wt-mnt
```
**Pass when:**
- The app check says `accepted` with `source=Notarized Developer ID`.
- The quarantined DMG is `accepted`.
- The app launches from the DMG with no Gatekeeper dialog (`pgrep` prints a pid).

Note: the M0 app is a menu-bar-only skeleton. Launching it shows a "?" bubble icon in the menu bar and nothing else. That's expected.

### 2.4 Finish
1. Add the DMG's SHA-256 (printed by the script), its size and the notarization submission IDs to the test report.
2. Commit the report and any fixes on `codex/test-and-notarize`.
3. Tell the owner what passed, what failed and what still needs them. **Ask before pushing.**

---

## Known gaps (not bugs at M0)
- There's no UI toggle to turn the recorder on yet. `AgentManager` exists, but onboarding comes in M4. The login item is never registered at M0.
- The menu bar icon is an SF Symbol placeholder.
- The panel shows raw audio events only. Notification log parsing, the correlator and rarity come in M1–M2.
- The notification-DB schema (§10 row 5) needs Full Disk Access and is deferred to M3. Don't ask for it in this task.

## Done means
- [ ] 1.1–1.3 run, with results in `docs/test-reports/2026-11-m0-codex.md`
- [ ] PLAN.md §10 rows 1–2 updated if new answers came in
- [ ] `build/release/WasThat-0.1.0.dmg` notarized + stapled, and every check in 2.3 passes
- [ ] Fixes and the report committed on `codex/test-and-notarize`, not pushed without the owner's OK
