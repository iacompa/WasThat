import ServiceManagement

/// Turns the background recorder (login item) on or off. Off = Scan-only mode.
enum AgentManager {
    static var service: SMAppService { .loginItem(identifier: AppInfo.agentBundleID) }

    static var isRecording: Bool { service.status == .enabled }

    static var statusText: String {
        switch service.status {
        case .enabled: "Recorder on"
        case .requiresApproval: "Recorder needs approval in Login Items"
        case .notRegistered: "Scan-only mode"
        case .notFound: "Recorder missing from the app bundle"
        @unknown default: "Recorder status unknown"
        }
    }

    static func setRecording(_ on: Bool) throws {
        if on { try service.register() } else { try service.unregister() }
    }
}
