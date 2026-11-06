import AppKit
import SwiftUI

/// The drop-down panel. M0 placeholder: shows raw recorder events; the real
/// sighting cards, rarity and actions arrive in M2–M3.
struct MenuPanelView: View {
    @Environment(EventsModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHAT WAS THAT?!")
                .font(Comic.display(30))
                .foregroundStyle(Comic.yellow)
                .shadow(color: Comic.ink, radius: 0, x: 2, y: 2)

            if let latest = model.sounds.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Sticker(text: "Latest", fill: Comic.legendary, size: 11)
                        Spacer()
                        Text(latest.time, format: .relative(presentation: .named))
                            .font(.caption.bold())
                    }
                    Text(latest.processName)
                        .font(Comic.display(26))
                        .textCase(.uppercase)
                    Text(latest.bundleID.isEmpty ? "no bundle ID" : latest.bundleID)
                        .font(.caption.monospaced())
                        .opacity(0.7)
                }
                .foregroundStyle(Comic.ink)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .inkPanel()
            } else {
                Text("Nothing heard in the last hour.")
                    .font(.callout)
                    .foregroundStyle(Comic.paper.opacity(0.75))
            }

            ForEach(model.sounds.dropFirst().prefix(5)) { event in
                HStack {
                    Text(event.processName).bold()
                    Spacer()
                    Text(event.time, format: .relative(presentation: .named))
                }
                .font(.callout)
                .foregroundStyle(Comic.paper.opacity(0.85))
            }

            HStack(spacing: 10) {
                Button("Open full log") {
                    openWindow(id: "history")
                    NSApp.activate()
                }
                .buttonStyle(ComicButtonStyle())
                Spacer()
                Link("GitHub ↗", destination: AppInfo.repoURL)
                    .font(.callout.bold())
                    .foregroundStyle(Comic.yellow)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(ComicButtonStyle(fill: Comic.paper))
            }

            Text(AgentManager.statusText)
                .font(.caption)
                .foregroundStyle(Comic.paper.opacity(0.5))
        }
        .padding(18)
        .frame(width: 380)
        .background(HalftoneBackground())
    }
}
