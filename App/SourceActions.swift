import AppKit
import Observation

/// Destinations contain validated identities, never executable paths from recorded events.
nonisolated enum SourceDestination: Hashable, Sendable {
    case application(bundleID: String)
    case settings(SourceSettingsPane)

    var title: String {
        switch self {
        case .application: "Open app"
        case .settings(let pane): pane.title
        }
    }
}

nonisolated enum SourceSettingsPane: String, Hashable, Sendable {
    case notifications, focus, loginItems

    var title: String {
        switch self {
        case .notifications: "Notification settings"
        case .focus: "Focus settings"
        case .loginItems: "Login Items"
        }
    }

    /// Fixed pane identifiers from Apple's Mac User Guide. No event data enters this URL.
    var url: URL {
        let identifier: String
        switch self {
        case .notifications: identifier = "com.apple.Notifications-Settings.extension"
        case .focus: identifier = "com.apple.Focus-Settings.extension"
        case .loginItems: identifier = "com.apple.LoginItems-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:" + identifier)!
    }

    var guidance: String {
        switch self {
        case .notifications: "In System Settings, choose Notifications, then choose the app if it is listed."
        case .focus: "In System Settings, choose Focus to review which notifications it allows."
        case .loginItems: "In System Settings, choose General, then Login Items & Extensions to review background apps."
        }
    }
}

nonisolated struct SourceActionContext: Equatable, Sendable {
    var bundleID: String?
    var isNotification: Bool
    var isUnidentified: Bool
    var suppression: NotificationFact.Suppression?

    init(sighting: Sighting) {
        bundleID = sighting.bundleID
        isNotification = sighting.category != .appAudio
        isUnidentified = sighting.category == .unidentifiedNotificationAudio
        suppression = sighting.audibility == .suppressed ? sighting.suppression : nil
    }

    init(source: ActiveAudioSource) {
        bundleID = source.bundleID
        isNotification = source.bundleID == "com.apple.notificationcenterui"
        isUnidentified = isNotification
        suppression = nil
    }
}

nonisolated struct SourceActionPlan: Equatable, Sendable {
    var destinations: [SourceDestination]
    var note: String?
}

nonisolated enum SourceActionPolicy {
    static func validBundleID(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 255 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }),
              value.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || byte == 45 || byte == 46
              }) else { return nil }
        return value
    }

    static func systemPane(bundleID: String) -> SourceSettingsPane? {
        switch bundleID {
        case "com.apple.BTMNotificationAgent": .loginItems
        case "com.apple.notificationcenterui", "com.apple.usernoted": .notifications
        default: nil
        }
    }

    static func systemName(bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.BTMNotificationAgent": "Background item alert"
        case "com.apple.notificationcenterui", "com.apple.usernoted": "macOS notifications"
        default: nil
        }
    }

    static func plan(context: SourceActionContext, applicationAvailable: Bool) -> SourceActionPlan {
        var destinations: [SourceDestination] = []
        var note: String?
        let identifier = validBundleID(context.bundleID)
        if !context.isUnidentified, let identifier {
            if let pane = systemPane(bundleID: identifier) {
                destinations.append(.settings(pane))
            } else if applicationAvailable {
                destinations.append(.application(bundleID: identifier))
            } else {
                note = "The source app is not available to open on this Mac."
            }
        } else if !context.isNotification {
            note = "No reliable app or settings destination was identified."
        }
        if context.isNotification {
            if !destinations.contains(.settings(.notifications)) {
                destinations.append(.settings(.notifications))
            }
            if context.isUnidentified || identifier == nil {
                note = "The sender is unconfirmed. Notification settings opens the general settings page."
            }
            if context.suppression == .focus {
                destinations.append(.settings(.focus))
            } else if context.suppression == .screenSharing {
                note = "Notifications includes the option for notifications while mirroring or sharing the display."
            }
        }
        return SourceActionPlan(destinations: destinations, note: note)
    }
}

nonisolated enum SourceOpenFailure: Error, Equatable, Sendable {
    case unavailable, failed, timedOut

    var message: String {
        switch self {
        case .unavailable: "This destination is no longer available. Refresh the history and try again."
        case .failed: "macOS could not open this destination. Try opening the app or System Settings yourself."
        case .timedOut: "macOS did not confirm opening this destination. Check whether it opened before trying again."
        }
    }
}

@MainActor
protocol SourceWorkspace {
    func applicationURL(bundleID: String) -> URL?
    func openApplication(at url: URL, completion: @escaping @MainActor (Result<Void, SourceOpenFailure>) -> Void)
    func openSettings(_ pane: SourceSettingsPane, completion: @escaping @MainActor (Result<Void, SourceOpenFailure>) -> Void)
}

@MainActor
struct SystemSourceWorkspace: SourceWorkspace {
    func applicationURL(bundleID: String) -> URL? {
        guard SourceActionPolicy.validBundleID(bundleID) != nil else { return nil }
        let runningURL = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?.bundleURL
        let registeredURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        for url in [runningURL, registeredURL].compactMap({ $0 }) {
            if let target = Self.validatedApplication(url: url, bundleID: bundleID) { return target }
        }
        return nil
    }

    /// A verified embedded helper may navigate to its actual containing app.
    /// A standalone headless bundle has no user-facing destination.
    static func validatedApplication(url: URL, bundleID: String) -> URL? {
        guard let source = validatedBundle(url: url, bundleID: bundleID) else { return nil }
        var parent = source.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension == "app" {
                guard let ownerID = Bundle(url: parent)?.bundleIdentifier,
                      let owner = validatedBundle(url: parent, bundleID: ownerID),
                      Bundle(url: owner)?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true else { return nil }
                return owner
            }
            let next = parent.deletingLastPathComponent()
            guard next != parent else { return nil }
            parent = next
        }
        guard Bundle(url: source)?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true else { return nil }
        return source
    }

    private static func validatedBundle(url: URL, bundleID: String) -> URL? {
        guard SourceActionPolicy.validBundleID(bundleID) != nil, url.isFileURL else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension == "app", let bundle = Bundle(url: resolved),
              bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL,
              executable.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                == resolved.appendingPathComponent("Contents/MacOS").resolvingSymlinksInPath().standardizedFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return resolved
    }

    func openApplication(at url: URL, completion: @escaping @MainActor (Result<Void, SourceOpenFailure>) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            let succeeded = app != nil && error == nil
            Task { @MainActor in completion(succeeded ? .success(()) : .failure(.failed)) }
        }
    }

    func openSettings(_ pane: SourceSettingsPane, completion: @escaping @MainActor (Result<Void, SourceOpenFailure>) -> Void) {
        guard let settings = applicationURL(bundleID: "com.apple.systempreferences"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: pane.url),
              Self.validatedApplication(url: handler, bundleID: "com.apple.systempreferences") == settings else {
            completion(.failure(.unavailable))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([pane.url], withApplicationAt: settings, configuration: configuration) { app, error in
            let succeeded = app != nil && error == nil
            Task { @MainActor in completion(succeeded ? .success(()) : .failure(.failed)) }
        }
    }
}

/// One click starts one bounded request. Late callbacks cannot overwrite a newer result.
@MainActor @Observable
final class SourceNavigator {
    private(set) var isOpening = false
    private(set) var message: String?
    private let workspace: any SourceWorkspace
    private let timeoutNanoseconds: UInt64
    private var requestID: UUID?
    private var timeoutTask: Task<Void, Never>?

    init(workspace: any SourceWorkspace = SystemSourceWorkspace(), timeoutNanoseconds: UInt64 = 8_000_000_000) {
        self.workspace = workspace
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func plan(for context: SourceActionContext) -> SourceActionPlan {
        let available = !context.isUnidentified
            && SourceActionPolicy.validBundleID(context.bundleID).flatMap { workspace.applicationURL(bundleID: $0) } != nil
        return SourceActionPolicy.plan(context: context, applicationAvailable: available)
    }

    func open(_ destination: SourceDestination) {
        guard !isOpening else { return }
        message = nil
        let appURL: URL?
        if case .application(let identifier) = destination {
            guard SourceActionPolicy.validBundleID(identifier) != nil,
                  SourceActionPolicy.systemPane(bundleID: identifier) == nil,
                  let resolved = workspace.applicationURL(bundleID: identifier) else {
                message = SourceOpenFailure.unavailable.message
                return
            }
            appURL = resolved
        } else {
            appURL = nil
        }
        let id = UUID()
        requestID = id
        isOpening = true
        timeoutTask = Task { [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            self?.finish(id: id, destination: destination, result: .failure(.timedOut))
        }
        let completion: @MainActor (Result<Void, SourceOpenFailure>) -> Void = { [weak self] result in
            self?.finish(id: id, destination: destination, result: result)
        }
        switch destination {
        case .application:
            guard let appURL else { finish(id: id, destination: destination, result: .failure(.unavailable)); return }
            workspace.openApplication(at: appURL, completion: completion)
        case .settings(let pane):
            workspace.openSettings(pane, completion: completion)
        }
    }

    private func finish(id: UUID, destination: SourceDestination, result: Result<Void, SourceOpenFailure>) {
        guard requestID == id, isOpening else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        requestID = nil
        isOpening = false
        switch result {
        case .success:
            if case .settings(let pane) = destination { message = pane.guidance }
        case .failure(let failure): message = failure.message
        }
    }
}
