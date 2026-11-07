import AppKit
import SwiftUI

struct AppIdentity {
    let name: String
    let icon: NSImage?

    init(bundleID: String?, processName: String?) {
        let identifier = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identifier, !identifier.isEmpty {
            if let systemName = SourceActionPolicy.systemName(bundleID: identifier) {
                name = systemName
                icon = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
                return
            }
            if let url = SystemSourceWorkspace().applicationURL(bundleID: identifier),
               let bundle = Bundle(url: url),
               let ownerID = bundle.bundleIdentifier, ownerID != identifier {
                name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                icon = NSWorkspace.shared.icon(forFile: url.path)
                return
            }
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == identifier }),
               let name = app.localizedName, !name.isEmpty {
                self.name = name
                icon = app.icon
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                let bundle = Bundle(url: url)
                name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                icon = NSWorkspace.shared.icon(forFile: url.path)
                return
            }
        }
        let process = processName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let component = process.isEmpty ? "" : URL(fileURLWithPath: process).lastPathComponent
        if !component.isEmpty && component != "/" {
            name = component
        } else if let identifier, !identifier.isEmpty {
            name = identifier
        } else {
            name = "Unidentified app"
        }
        icon = nil
    }
}

struct SightingPresentation {
    let identity: AppIdentity
    let evidence: String
    let explanation: String

    init(sighting: Sighting, isOngoing: Bool) {
        let unidentified = sighting.category == .unidentifiedNotificationAudio
        identity = unidentified
            ? AppIdentity(bundleID: nil, processName: "Notification sound")
            : AppIdentity(bundleID: sighting.bundleID, processName: sighting.processName)
        if sighting.audibility == .suppressed {
            evidence = "Not played"
            explanation = Self.suppressionExplanation(sighting.suppression)
        } else if unidentified {
            evidence = isOngoing ? "Notification audio already active" : "Sender not confirmed"
            let candidates = sighting.candidateBundleIDs
                .map { AppIdentity(bundleID: $0, processName: nil).name }
            let names = Array(Set(candidates)).sorted()
            let activity = isOngoing
                ? "Notification audio was already active when detection started."
                : "macOS notification audio activity was observed."
            explanation = names.isEmpty
                ? activity + " The sender could not be confirmed."
                : activity + " Possible apps: \(names.joined(separator: ", ")). Timing alone does not confirm the sender."
        } else {
            switch sighting.audibility {
            case .suppressed:
                evidence = "Not played"
                explanation = Self.suppressionExplanation(sighting.suppression)
            case .playbackReported:
                evidence = "Notification playback reported"
                explanation = "macOS reported notification sound playback for this app."
            case .notEstablished:
                evidence = "Playback not confirmed"
                explanation = "macOS reported notification activity for this app. Sound playback was not confirmed."
            case .activityObserved:
                evidence = isOngoing ? "Already using audio" : "Audio activity observed"
                explanation = isOngoing
                    ? "This app was already using audio when detection started. This is not a newly started sound."
                    : "The app reported audio output activity. This does not confirm that the sound was audible."
            }
        }
    }

    private static func suppressionExplanation(_ reason: NotificationFact.Suppression?) -> String {
        switch reason {
        case .focus:
            "macOS reported that Focus suppressed this notification sound."
        case .screenSharing:
            "macOS reported that screen sharing suppressed this notification sound."
        case .mutedUnspecified:
            "macOS reported that this notification sound was muted."
        case .unknown, nil:
            "macOS reported that this notification sound was suppressed. The reason was not identified."
        }
    }
}

struct AppIdentityIcon: View {
    let identity: AppIdentity
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let icon = identity.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct SightingCard: View {
    let sighting: Sighting
    var isOngoing: Bool
    var prominent = false

    var body: some View {
        let presentation = SightingPresentation(sighting: sighting, isOngoing: isOngoing)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIdentityIcon(identity: presentation.identity, size: prominent ? 44 : 32)
                Text(presentation.identity.name)
                    .font(Comic.display(prominent ? 32 : 24))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    if !Calendar.current.isDateInToday(sighting.time) {
                        Text(sighting.time, format: .dateTime.month(.abbreviated).day())
                            .font(.caption)
                    }
                    Text(sighting.time, format: .dateTime.hour().minute().second())
                        .font(prominent ? .title3.monospacedDigit() : .callout.monospacedDigit())
                }
            }
            Text(presentation.evidence)
                .font(.callout.weight(.bold))
            Text(presentation.explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            SourceActionsView(context: SourceActionContext(sighting: sighting), identityName: presentation.identity.name)
        }
        .foregroundStyle(Comic.ink)
        .padding(prominent ? 18 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkPanel(fill: prominent ? Comic.yellow : Comic.paper, shadow: 3)
        .accessibilityElement(children: .contain)
    }
}

struct CompactSightingRow: View {
    let sighting: Sighting
    var isOngoing: Bool

    var body: some View {
        let presentation = SightingPresentation(sighting: sighting, isOngoing: isOngoing)
        HStack(alignment: .top, spacing: 10) {
            AppIdentityIcon(identity: presentation.identity, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.identity.name)
                    .font(.callout.bold())
                Text(presentation.evidence)
                    .font(.caption.weight(.semibold))
                Text(presentation.explanation)
                    .font(.caption)
                    .lineLimit(3)
                SourceActionsView(context: SourceActionContext(sighting: sighting), identityName: presentation.identity.name, compact: true)
            }
            Spacer(minLength: 8)
            Text(sighting.time, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(Comic.paper)
        .accessibilityElement(children: .contain)
        .help(presentation.explanation)
    }
}

struct ActiveAudioSourcesView: View {
    let sources: [ActiveAudioSource]
    var compact = false

    private var visibleSources: [ActiveAudioSource] {
        compact ? Array(sources.prefix(3)) : sources
    }

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Apps using audio now")
                    .font(.headline)
                ForEach(visibleSources) { source in
                    let identity = AppIdentity(bundleID: source.bundleID, processName: source.processName)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 9) {
                            AppIdentityIcon(identity: identity, size: 25)
                            Text(identity.name)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text("Active")
                                .font(.caption)
                        }
                        SourceActionsView(context: SourceActionContext(source: source), identityName: identity.name, compact: true)
                    }
                }
                if compact && sources.count > visibleSources.count {
                    Text("\(sources.count - visibleSources.count) more in History")
                        .font(.caption)
                }
                Text("An ongoing audio stream can include later sounds without creating a new event.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Comic.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkPanel(shadow: 3)
        }
    }
}


/// Buttons stay separate accessibility elements within each evidence card.
struct SourceActionsView: View {
    let context: SourceActionContext
    let identityName: String
    var compact = false
    @State private var navigator = SourceNavigator()

    var body: some View {
        let plan = navigator.plan(for: context)
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { destinationButtons(plan.destinations) }
                VStack(alignment: .leading, spacing: 6) { destinationButtons(plan.destinations) }
            }
            if let message = navigator.message ?? plan.note {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .controlSize(compact ? .mini : .small)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func destinationButtons(_ destinations: [SourceDestination]) -> some View {
        ForEach(destinations, id: \.self) { destination in
            Button(destination.title) { navigator.open(destination) }
                .buttonStyle(ComicButtonStyle(fill: Comic.paper))
                .disabled(navigator.isOpening)
                .accessibilityLabel(destination.title + " for " + identityName)
                .help(help(for: destination))
        }
    }

    private func help(for destination: SourceDestination) -> String {
        switch destination {
        case .application: "Opens this source app, or its containing app for an embedded helper. This cannot reopen a specific sound or notification."
        case .settings(let pane): pane.guidance + " WasThat does not change any settings."
        }
    }
}

struct WasThatSourceLinks: View {
    private let licenseURL = AppInfo.repoURL
        .appendingPathComponent("blob")
        .appendingPathComponent("main")
        .appendingPathComponent("LICENSE")

    var body: some View {
        HStack(spacing: 14) {
            Link("GitHub", destination: AppInfo.repoURL)
            Link("GPL v3", destination: licenseURL)
        }
        .foregroundStyle(Comic.yellow)
        .tint(Comic.yellow)
        .help("Opens your browser")
    }
}
