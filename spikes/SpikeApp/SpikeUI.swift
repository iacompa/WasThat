import AppKit
import SwiftUI

struct Card<Content: View>: View {
    let step: Int
    let title: String
    var optional = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StepBadge(n: step)
                Text(title).font(Comic.display(22)).textCase(.uppercase).foregroundStyle(Comic.ink)
                if optional { Sticker(text: "Optional", fill: Comic.common, size: 11) }
                Spacer(minLength: 0)
            }
            content
                .font(.system(size: 13))
                .foregroundStyle(Comic.ink.opacity(0.85))
                .toggleStyle(.checkbox)
                .buttonStyle(ComicButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkPanel()
        .environment(\.colorScheme, .light)
    }
}

struct ContentView: View {
    @EnvironmentObject var s: Spike
    var snapshot = false

    var body: some View {
        if snapshot {
            page.frame(width: 600).background(HalftoneBackground())
        } else {
            ScrollView { page }
                .scrollIndicators(.never)
                .background(HalftoneBackground())
                .frame(width: 600, height: 700)
        }
    }

    private var page: some View {
            VStack(alignment: .leading, spacing: 22) {
                header

                Card(step: 1, title: "Notification sound") {
                    Text("Turn **Focus / Do Not Disturb off** (Control Center → Focus) and turn your volume up. Press Run: a test notification with the “Glass” sound is posted while the app watches the system log and audio.")
                    HStack(spacing: 12) {
                        Button(s.notifRunning ? "Running…" : "Run") { s.runNotif() }.disabled(s.notifRunning)
                        Text(s.notifStatus).font(.callout).foregroundStyle(Comic.ink.opacity(0.6))
                    }
                    if s.notifDone {
                        HStack(spacing: 10) {
                            Text("Did you hear the Glass sound?").bold()
                            Button("Yes, heard it") { s.saveNotif(heard: true) }
                            Button("No") { s.saveNotif(heard: false) }.buttonStyle(ComicButtonStyle(fill: Comic.paper))
                        }
                    }
                }

                Card(step: 2, title: "Mute another app") {
                    Text("Press Run and listen: soft beeps play for about 13 s while two ways of muting them are tried. Watch the label below **and** the top-right of your menu bar for a recording dot. If macOS asks for permission, allow it, then Run again.")
                    Button(s.muteRunning ? "Running…" : "Run") { s.runMute() }.disabled(s.muteRunning)
                    Text(s.phase)
                        .font(Comic.display(19))
                        .textCase(.uppercase)
                        .foregroundStyle(Comic.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .inkPanel(fill: s.phaseColor, radius: 8, shadow: 3, line: 2.5)
                        .animation(.easeOut(duration: 0.2), value: s.phase)
                    if s.muteDone {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Phase B (tap only) was silent", isOn: $s.bSilent)
                            Toggle("Phase C (tap + running device) was silent", isOn: $s.cSilent)
                            Toggle("Phase D: beeps came back", isOn: $s.dAudible)
                            Toggle("I saw a recording / microphone dot in the menu bar", isOn: $s.sawIndicator)
                            Toggle("macOS showed a permission prompt", isOn: $s.gotPrompt)
                        }
                        Button("Save answers") { s.saveMute() }
                    }
                }

                Card(step: 3, title: "Jump to settings") {
                    Text("Each button tries to open System Settings right on **Messages'** notification page. Pick where each one landed, then Save.")
                    ForEach(Array(Spike.links.enumerated()), id: \.offset) { i, link in
                        HStack(spacing: 12) {
                            Button("Try link \(i + 1)") { s.open(link.key) }
                            Picker("", selection: Binding(get: { s.linkAnswers[link.key] ?? "" },
                                                          set: { s.linkAnswers[link.key] = $0 })) {
                                Text("Where did it land?").tag("")
                                Text("Messages' notification page").tag("messages-page")
                                Text("Notifications list (not Messages)").tag("notifications-list")
                                Text("Something else / nothing").tag("other")
                            }
                            .labelsHidden()
                            .frame(width: 260)
                        }
                    }
                    Button("Save answers") { s.saveLinks() }
                }

                Card(step: 4, title: "Notification database", optional: true) {
                    Text("Needs Full Disk Access, which is what unlocks notification text in the real app. Only the database **structure** and row counts are recorded, never message content.")
                    HStack(spacing: 12) {
                        Button("Check database") { s.checkDB() }
                        Button("Open Full Disk Access") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        .buttonStyle(ComicButtonStyle(fill: Comic.paper))
                    }
                    Text(s.dbStatus).font(.callout).foregroundStyle(Comic.ink.opacity(0.6))
                    Text("To grant it: press + on that page, add “WasThat Spike”, switch it on, quit and reopen this app, then Check again. You can remove it afterwards.")
                        .font(.caption)
                        .foregroundStyle(Comic.ink.opacity(0.55))
                }

                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("WHAT WAS THAT?!")
                    .font(Comic.display(42))
                    .foregroundStyle(Comic.yellow)
                    .shadow(color: Comic.ink, radius: 0, x: 3, y: 3)
                Sticker(text: "Field tests", fill: Comic.rust)
                    .rotationEffect(.degrees(-6))
                    .offset(y: -6)
            }
            Text("Four quick checks that need your ears and eyes. Each one saves its result for Claude. No notification content is ever recorded.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Comic.paper.opacity(0.75))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !s.saved.isEmpty { Sticker(text: s.saved, fill: Comic.uncommon) }
            Text("Results: ~/Library/Application Support/WasThat/spike-results.jsonl")
                .font(.caption)
                .foregroundStyle(Comic.paper.opacity(0.5))
        }
    }
}
