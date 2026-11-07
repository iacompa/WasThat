import AppKit
import SwiftUI

struct HistoryView: View {
    @Environment(EventsModel.self) private var model

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
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("WasThat")
                    .font(Comic.display(38))
                    .foregroundStyle(Comic.yellow)
                Text("Recent sound activity")
                    .font(.title3)
                    .foregroundStyle(Comic.paper)
                Spacer()
                Text("Version \(AppInfo.publicVersion)")
                    .font(.callout)
                    .foregroundStyle(Comic.paper)
            }

            RecorderStatusPanel(recorder: model.recorder)

            HStack(spacing: 16) {
                Text("History")
                    .font(Comic.display(25))
                Spacer()
                Picker("Time range", selection: $model.lookback) {
                    Text("Last hour").tag(TimeInterval(3_600))
                    Text("24 hours").tag(TimeInterval(86_400))
                    Text("7 days").tag(TimeInterval(604_800))
                }
                .pickerStyle(.segmented)
                .frame(width: 290)
                .accessibilityLabel("History time range")
                Button("Refresh", action: refresh)
                    .buttonStyle(ComicButtonStyle(fill: Comic.paper))
                    .keyboardShortcut("r", modifiers: [.command])
            }
            .foregroundStyle(Comic.paper)

            if model.storeError != nil {
                HistoryLoadNotice()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ActiveAudioSourcesView(sources: model.recorder.health?.activeSources ?? [])

                    if let latest = recent.first {
                        Text("Latest activity")
                            .font(.headline)
                            .foregroundStyle(Comic.paper)
                        SightingCard(
                            sighting: latest,
                            isOngoing: latest.evidenceIDs.contains { ongoingEvidence.contains($0) },
                            prominent: true
                        )
                    } else {
                        RecorderEmptyState(recorder: model.recorder, historyUnavailable: model.storeError != nil)
                    }

                    if !suppressed.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Suppressed notifications")
                                .font(Comic.display(24))
                            Text("These attempts were not played. They are separate from reported playback.")
                                .font(.callout)
                        }
                        .foregroundStyle(Comic.paper)
                        .padding(.top, 8)
                        ForEach(suppressed) { sighting in
                            SightingCard(sighting: sighting, isOngoing: false)
                        }
                    }

                    if recent.count > 1 {
                        Text("Earlier activity")
                            .font(Comic.display(24))
                            .foregroundStyle(Comic.paper)
                            .padding(.top, 8)
                        ForEach(recent.dropFirst()) { sighting in
                            SightingCard(
                                sighting: sighting,
                                isOngoing: sighting.evidenceIDs.contains { ongoingEvidence.contains($0) }
                            )
                        }
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 10)
            }

            HStack {
                if let updated = model.lastUpdated {
                    Text("Updated \(updated, format: .dateTime.hour().minute().second())")
                        .font(.caption)
                }
                Spacer()
                WasThatSourceLinks()
                    .font(.callout)
            }
            .foregroundStyle(Comic.paper)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 590)
        .background(HalftoneBackground())
        .preferredColorScheme(.dark)
        .navigationTitle("WasThat")
        .onAppear(perform: showHistory)
    }

    private func showHistory() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        refresh()
    }

    private func refresh() {
        model.recorder.refresh()
        model.reload()
    }
}

struct HistoryLoadNotice: View {
    var body: some View {
        Label("History could not be refreshed. Previous results may still appear. Try Refresh again.", systemImage: "exclamationmark.triangle")
            .font(.callout.weight(.medium))
            .foregroundStyle(Comic.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkPanel(fill: Comic.yellow, shadow: 2)
    }
}

struct RecorderEmptyState: View {
    let recorder: RecorderController
    var historyUnavailable = false

    private var message: (title: String, detail: String) {
        if historyUnavailable {
            return ("History is unavailable", "Refresh to try loading history again. Detection controls remain available above.")
        }
        switch recorder.state {
        case .off:
            return ("Detection is off", "Start detection to collect new activity. Saved history remains available when detection is off.")
        case .starting:
            return ("Starting detection…", "WasThat is waiting for the background detector. Activity appears when it is ready.")
        case .listening:
            if recorder.health?.history == .starting {
                return ("Checking recent activity…", "WasThat is checking recent notification activity. New app audio activity may appear while this finishes.")
            }
            return ("No recent activity", "New app audio activity appears while detection is on. Try playing a sound in another app.")
        case .needsApproval:
            return ("Approval is needed", "Use Open Login Items above to review WasThat in macOS, then return to the app.")
        case .degraded:
            return ("Detection needs attention", "Some activity sources are unavailable. Check the detection status above.")
        case .failed:
            return ("Detection could not start", "Check the detection status above. Try again, or stop detection.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message.title)
                .font(Comic.display(26))
            Text(message.detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Comic.ink)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkPanel(shadow: 3)
        .accessibilityElement(children: .combine)
    }
}
