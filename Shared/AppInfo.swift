import Foundation

/// Identifiers and locations shared by the app and the background recorder.
nonisolated enum AppInfo {
    static var publicVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1" }
    static let agentBundleID = "com.iacompa.wasthat.agent"
    /// Darwin notification the agent posts after writing new events.
    static let eventsChanged = "com.iacompa.wasthat.events-changed"
    static let healthRequested = "com.iacompa.wasthat.health-requested"
    static let stopRequested = "com.iacompa.wasthat.stop-requested"
    static let retryRequested = "com.iacompa.wasthat.retry-requested"
    static let repoURL = URL(string: "https://github.com/iacompa/WasThat")!

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WasThat", isDirectory: true)
    }

    static var eventsDatabase: URL { supportDirectory.appendingPathComponent("events.sqlite") }
    static var recorderStatus: URL { supportDirectory.appendingPathComponent("recorder-status.json") }
    static var recorderLock: URL { supportDirectory.appendingPathComponent("recorder.lock") }
}
