import AppKit
import Foundation

@MainActor
private final class FakeSourceWorkspace: SourceWorkspace {
    var available: [String: URL] = [:]
    var openedApps: [URL] = []
    var openedPanes: [SourceSettingsPane] = []
    var callbacks: [@MainActor (Result<Void, SourceOpenFailure>) -> Void] = []
    var immediateResult: Result<Void, SourceOpenFailure>?

    func applicationURL(bundleID: String) -> URL? { available[bundleID] }
    func openApplication(at url: URL, completion: @escaping @MainActor (Result<Void, SourceOpenFailure>) -> Void) {
        openedApps.append(url)
        callbacks.append(completion)
        if let immediateResult { completion(immediateResult) }
    }
    func openSettings(_ pane: SourceSettingsPane, completion: @escaping @MainActor (Result<Void, SourceOpenFailure>) -> Void) {
        openedPanes.append(pane)
        callbacks.append(completion)
        if let immediateResult { completion(immediateResult) }
    }
}

@main @MainActor
struct SourceActionTests {
    private static var checks = 0

    static func expect(_ condition: Bool, _ description: String) {
        checks += 1
        guard condition else { fatalError("FAIL: " + description) }
        print("PASS: " + description)
    }

    static func sighting(bundleID: String? = "com.example.Audio", category: Sighting.Category = .appAudio,
                         audibility: Sighting.Audibility = .activityObserved,
                         suppression: NotificationFact.Suppression? = nil) -> Sighting {
        Sighting(id: "test", time: Date(timeIntervalSince1970: 0), category: category,
                 bundleID: bundleID, processName: "/tmp/not-an-app", audibility: audibility,
                 suppression: suppression, candidateBundleIDs: ["com.example.Guess"])
    }

    static func main() async throws {
        expect(SourceActionPolicy.validBundleID("com.example.Audio") != nil, "valid bundle identity")
        for value in ["", "Audio", "com..Audio", "com.Audio.", "/Applications/Audio.app", "com.Audio?x=1", " com.Audio", "com.Áudio", String(repeating: "x", count: 256) + ".app"] {
            expect(SourceActionPolicy.validBundleID(value) == nil, "reject unsafe bundle identity")
        }
        let ordinary = SourceActionContext(sighting: sighting())
        let installed = SourceActionPolicy.plan(context: ordinary, applicationAvailable: true)
        expect(installed.destinations == [.application(bundleID: "com.example.Audio")], "installed audio app opens only that app")
        expect(installed.note == nil, "ordinary available app adds no extra explanatory copy")
        let absent = SourceActionPolicy.plan(context: ordinary, applicationAvailable: false)
        expect(absent.destinations.isEmpty && absent.note != nil, "absent app has explicit unavailable destination")
        let invalid = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(bundleID: "/tmp/Audio")), applicationAvailable: true)
        expect(invalid.destinations.isEmpty && invalid.note != nil, "invalid identity cannot authorize executable launch")
        let processOnly = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(bundleID: nil)), applicationAvailable: true)
        expect(processOnly.destinations.isEmpty, "process basename cannot authorize app launch")
        let unknown = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(bundleID: "com.example.Guess", category: .unidentifiedNotificationAudio)), applicationAvailable: true)
        expect(unknown.destinations == [.settings(.notifications)], "ambiguous sender opens general notifications without guessing")
        expect(unknown.note?.contains("unconfirmed") == true, "ambiguous sender remains explicit")
        let notification = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(category: .notification, audibility: .playbackReported)), applicationAvailable: true)
        expect(notification.destinations == [.application(bundleID: "com.example.Audio"), .settings(.notifications)], "identified notification offers app and general notification settings")
        let missingNotification = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(category: .notification)), applicationAvailable: false)
        expect(missingNotification.destinations == [.settings(.notifications)] && missingNotification.note != nil, "notification settings remains available when app was removed")
        let focus = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(category: .notification, audibility: .suppressed, suppression: .focus)), applicationAvailable: true)
        expect(focus.destinations.contains(.settings(.focus)), "explicit Focus suppression offers Focus settings")
        let noSuppression = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(category: .notification, suppression: .focus)), applicationAvailable: true)
        expect(!noSuppression.destinations.contains(.settings(.focus)), "non-suppressed evidence does not infer Focus destination")
        let sharing = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(category: .notification, audibility: .suppressed, suppression: .screenSharing)), applicationAvailable: true)
        expect(sharing.destinations.contains(.settings(.notifications)) && sharing.note?.contains("sharing") == true, "screen-sharing suppression points to actual notification option")
        let background = SourceActionPolicy.plan(context: SourceActionContext(sighting: sighting(bundleID: "com.apple.BTMNotificationAgent", category: .notification)), applicationAvailable: true)
        expect(background.destinations == [.settings(.loginItems), .settings(.notifications)], "known system background alert maps to settings without launching agent")
        let nc = SourceActionPolicy.plan(context: SourceActionContext(source: ActiveAudioSource(pid: 1, bundleID: "com.apple.notificationcenterui", processName: "NotificationCenter")), applicationAvailable: true)
        expect(nc.destinations == [.settings(.notifications)], "active NotificationCenter cannot identify a sender")
        let active = SourceActionPolicy.plan(context: SourceActionContext(source: ActiveAudioSource(pid: 2, bundleID: "com.example.Audio", processName: "Audio")), applicationAvailable: true)
        expect(active.destinations == [.application(bundleID: "com.example.Audio")], "active identified audio offers app navigation")
        for pane in [SourceSettingsPane.notifications, .focus, .loginItems] {
            expect(pane.url.scheme == "x-apple.systempreferences" && pane.url.query == nil, "settings destination is fixed and excludes event input")
        }

        let workspace = FakeSourceWorkspace()
        let fixtureURL = URL(fileURLWithPath: "/not-used/Audio.app")
        workspace.available["com.example.Audio"] = fixtureURL
        let navigator = SourceNavigator(workspace: workspace, timeoutNanoseconds: 20_000_000)
        expect(navigator.plan(for: ordinary).destinations == installed.destinations, "navigator resolves installed app for display")
        workspace.available.removeAll()
        navigator.open(.application(bundleID: "com.example.Audio"))
        expect(workspace.openedApps.isEmpty && navigator.message != nil && !navigator.isOpening, "click revalidates app removed since display")
        workspace.available["com.example.Audio"] = fixtureURL
        navigator.open(.application(bundleID: "com.example.Audio"))
        expect(navigator.isOpening && workspace.openedApps == [fixtureURL], "app launch becomes busy")
        navigator.open(.settings(.focus))
        expect(workspace.openedPanes.isEmpty, "repeated clicks do not start another launch")
        workspace.callbacks[0](.failure(.failed))
        expect(!navigator.isOpening && navigator.message == SourceOpenFailure.failed.message, "launch failure becomes visible and unlocks retry")
        navigator.open(.settings(.notifications))
        workspace.callbacks[1](.success(()))
        expect(navigator.message == SourceSettingsPane.notifications.guidance, "settings success provides navigation guidance")
        navigator.open(.settings(.focus))
        try await Task.sleep(nanoseconds: 50_000_000)
        expect(!navigator.isOpening && navigator.message == SourceOpenFailure.timedOut.message, "missing callback times out and unlocks controls")
        navigator.open(.settings(.loginItems))
        workspace.callbacks[2](.success(()))
        expect(navigator.isOpening && navigator.message == nil, "late callback cannot overwrite newer request")
        workspace.callbacks[3](.success(()))
        expect(!navigator.isOpening && navigator.message == SourceSettingsPane.loginItems.guidance, "new request completes after timeout")
        let countBeforeUnsafe = workspace.openedApps.count
        navigator.open(.application(bundleID: "com.apple.BTMNotificationAgent"))
        navigator.open(.application(bundleID: "/tmp/Audio"))
        expect(workspace.openedApps.count == countBeforeUnsafe, "direct invalid and system-agent requests cannot launch app")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("WasThatSourceActionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func fakeApp(_ name: String, id: String, background: Bool = false, executable: Bool = true) throws -> URL {
            let url = temporary.appendingPathComponent(name + ".app")
            let contents = url.appendingPathComponent("Contents")
            let executableURL = contents.appendingPathComponent("MacOS/Fixture")
            try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: executableURL)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: executableURL.path)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "LSBackgroundOnly": background]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let validApp = try fakeApp("Valid", id: "com.example.Valid")
        expect(SystemSourceWorkspace.validatedApplication(url: validApp, bundleID: "com.example.Valid") == validApp.resolvingSymlinksInPath().standardizedFileURL, "validate actual app identity and executable")
        expect(SystemSourceWorkspace.validatedApplication(url: validApp, bundleID: "com.example.Other") == nil, "reject bundle identity mismatch")
        let headless = try fakeApp("Headless", id: "com.example.Headless", background: true)
        expect(SystemSourceWorkspace.validatedApplication(url: headless, bundleID: "com.example.Headless") == nil, "headless helper is not presented as an app window")
        let noExecutable = try fakeApp("NoExecutable", id: "com.example.NoExecutable", executable: false)
        expect(SystemSourceWorkspace.validatedApplication(url: noExecutable, bundleID: "com.example.NoExecutable") == nil, "reject app without executable")
        let parent = try fakeApp("Parent", id: "com.example.Parent")
        let helper = try fakeApp("Helper", id: "com.example.Parent.helper", background: true)
        let embedded = parent.appendingPathComponent("Contents/Frameworks/Helper.app")
        try FileManager.default.createDirectory(at: embedded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: helper, to: embedded)
        expect(SystemSourceWorkspace.validatedApplication(url: embedded, bundleID: "com.example.Parent.helper") == parent.resolvingSymlinksInPath().standardizedFileURL, "embedded helper opens its verified containing app")
        expect(SystemSourceWorkspace.validatedApplication(url: embedded, bundleID: "com.example.Other.helper") == nil, "embedded helper identity must match before parent resolution")
        expect(SystemSourceWorkspace.validatedApplication(url: URL(string: "https://example.com/Test.app")!, bundleID: "com.example.Test") == nil, "reject remote app URL")
        let system = SystemSourceWorkspace()
        expect(system.applicationURL(bundleID: "com.apple.systempreferences") != nil, "installed System Settings identity validates without launch")
        print("\(checks) source action checks passed. No app or settings destination was opened.")
    }
}
