import Foundation

/// Identifiers and locations shared by the app and the background recorder.
nonisolated enum AppInfo {
    static let agentBundleID = "com.iacompa.wasthat.agent"
    /// Darwin notification the agent posts after writing new events.
    static let eventsChanged = "com.iacompa.wasthat.events-changed"
    static let repoURL = URL(string: "https://github.com/iacompa/WasThat")!

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WasThat", isDirectory: true)
    }

    static var eventsDatabase: URL { supportDirectory.appendingPathComponent("events.sqlite") }
}
