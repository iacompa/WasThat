# WasThat

**Heard a ding on your Mac and have no idea what it was? WasThat tells you.**

WasThat is a tiny native macOS app (about 2 MB). It identifies recent notifications *and* any other sound source, such as the charger chime, an in-app ping from Slack or Discord, or a browser tab. Then it lets you mute that source for an hour, a day or for good, or jump straight to its notification settings. It has a vintage cel-shaded comic look, and every sound is ranked like loot from Common to Legendary.

> **Status: pre-alpha.** We're in milestone M0 (feasibility spike + project skeleton). See [PLAN.md](PLAN.md) for the design, the findings so far and the roadmap.

## How it works
- **Notifications:** read from macOS's own unified log (app, time, shown or not, sound played or silenced and why). No special permission needed.
- **Every other sound:** a tiny background recorder watches CoreAudio and notes the moment any process starts playing audio. It's event-driven, so it uses about 0% CPU.
- **Optional extras:** notification text (needs Full Disk Access) and per-app audio mute (needs System Audio Recording).

Everything stays on your Mac: no analytics, no account.

## Build
Requires macOS 14.2+ and Xcode 16+.

```bash
brew install xcodegen
xcodegen generate
open WasThat.xcodeproj
```

The Xcode project is generated from [`project.yml`](project.yml) and not committed.

## Repo layout
| Path | What |
|---|---|
| `App/` | SwiftUI menu bar panel, history window, comic design system |
| `Agent/` | headless background recorder (login item) |
| `Shared/` | event model and SQLite store used by both |
| `Resources/` | app icon and assets |
| `spikes/` | feasibility probes and the M0 test app |
| `design/icon/` | icon sources and variants |

## License
[GPL-3.0](LICENSE). © 2026 IA COMPA LLC.
