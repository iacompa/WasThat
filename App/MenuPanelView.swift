import AppKit
import SwiftUI

struct MenuPanelView: View {
    @Environment(EventsModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var recent: [Sighting] {
        model.sightings.filter { $0.audibility != .suppressed }
    }

    private var suppressed: [Sighting] {
        model.sightings.filter { $0.audibility == .suppressed }
    }

    private var ongoingEvidence: Set<Int64> {
        Set(model.events.filter { $0.kind == .audioActive }.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("WasThat")
                    .font(Comic.display(30))
                    .foregroundStyle(Comic.yellow)
                Spacer()
                Text("Version \(AppInfo.publicVersion)")
                    .font(.caption)
                    .foregroundStyle(Comic.paper)
            }

            RecorderStatusPanel(recorder: model.recorder, compact: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.storeError != nil {
                        HistoryLoadNotice()
                    }

                    if let latest = recent.first {
                        Text("Latest activity")
                            .font(.headline)
                            .foregroundStyle(Comic.paper)
                        SightingCard(
                            sighting: latest,
                            isOngoing: latest.evidenceIDs.contains { ongoingEvidence.contains($0) },
                            prominent: true
                        )
                        ForEach(recent.dropFirst().prefix(2)) { sighting in
                            CompactSightingRow(
                                sighting: sighting,
                                isOngoing: sighting.evidenceIDs.contains { ongoingEvidence.contains($0) }
                            )
                        }
                    } else {
                        RecorderEmptyState(recorder: model.recorder, historyUnavailable: model.storeError != nil)
                    }

                    ActiveAudioSourcesView(sources: model.recorder.health?.activeSources ?? [], compact: true)

                    if let attempt = suppressed.first {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suppressed notifications · \(suppressed.count)")
                                .font(.headline)
                            Text("These attempts were not played.")
                                .font(.caption)
                            CompactSightingRow(sighting: attempt, isOngoing: false)
                        }
                        .foregroundStyle(Comic.paper)
                    }
                }
                .padding(.trailing, 6)
                .padding(.bottom, 8)
            }
            // The menu window needs an ideal viewport height instead of a maximum alone.
            .frame(minHeight: 240, idealHeight: 340, maxHeight: 390)

            HStack {
                Button("Open history", action: showHistory)
                    .buttonStyle(ComicButtonStyle())
                    .keyboardShortcut("h", modifiers: [.command])
                Spacer()
                Button("Refresh", action: refresh)
                    .buttonStyle(ComicButtonStyle(fill: Comic.paper))
                    .help("Refresh detection status and recent activity")
            }

            HStack(spacing: 16) {
                WasThatSourceLinks()
                Spacer()
                Button(model.recorder.isEnabled ? "Quit · keep detection on" : "Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Comic.paper)
                .help(model.recorder.isEnabled ? "Detection stays enabled. Reopen WasThat to stop it." : "Quit WasThat")
            }
            .font(.caption)
        }
        .padding(18)
        .frame(width: 440)
        .frame(maxHeight: 700)
        .background(HalftoneBackground())
        .preferredColorScheme(.dark)
        .onAppear(perform: refresh)
    }

    private func showHistory() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "history")
        NSApp.activate()
    }

    private func refresh() {
        model.recorder.refresh()
        model.reload()
    }
}

struct RecorderStatusPanel: View {
    let recorder: RecorderController
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 9) {
                if recorder.isBusy || recorder.state == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Comic.ink)
                        .accessibilityLabel("Detection status is changing")
                } else {
                    Image(systemName: statusSymbol)
                        .accessibilityHidden(true)
                }
                Text(recorder.statusTitle)
                    .font(.headline)
                Spacer(minLength: 8)
                Button(recorder.isBusy ? "Please wait…" : recorder.isEnabled ? "Stop detection" : "Start detection", action: changeRecording)
                    .buttonStyle(ComicButtonStyle(fill: recorder.isEnabled ? Comic.paper : Comic.yellow))
                    .disabled(recorder.isBusy)
                    .accessibilityHint(recorder.isEnabled ? "Stops background detection, including when this window closes" : "Enables the background detector")
            }

            Text(recorder.statusDetail)
                .font(compact ? .caption : .callout)
                .fixedSize(horizontal: false, vertical: true)

            if let error = recorder.lastError, !error.isEmpty, error != recorder.statusDetail {
                Text(error)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                if recorder.state == .needsApproval {
                    Button("Open Login Items", action: recorder.openLoginItems)
                        .buttonStyle(ComicButtonStyle())
                        .help("Opens macOS Login Items. You choose whether to approve WasThat.")
                    Button("Check again", action: recorder.refresh)
                        .buttonStyle(.link)
                        .tint(Comic.ink)
                } else if recorder.state == .failed || recorder.state == .degraded {
                    Button("Try again", action: retry)
                        .buttonStyle(ComicButtonStyle())
                        .disabled(recorder.isBusy)
                }
                if !compact {
                    Text(recorder.isEnabled
                         ? "Detection stays enabled when you close or quit WasThat. Reopen the app to stop it."
                         : "Saved history stays available when detection is off.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(Comic.ink)
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkPanel(shadow: 3)
        .accessibilityElement(children: .contain)
    }

    private var statusSymbol: String {
        switch recorder.state {
        case .off: "pause.circle"
        case .starting: "hourglass"
        case .listening: "waveform.circle.fill"
        case .needsApproval: "hand.raised.circle"
        case .degraded: "exclamationmark.triangle"
        case .failed: "exclamationmark.octagon"
        }
    }

    private func changeRecording() {
        let enabled = !recorder.isEnabled
        Task { await recorder.setEnabled(enabled) }
    }

    private func retry() {
        Task { await recorder.retry() }
    }
}
