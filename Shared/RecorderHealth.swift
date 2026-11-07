import Foundation

nonisolated struct ActiveAudioSource: Codable, Hashable, Identifiable, Sendable {
    var pid: Int32
    var bundleID: String
    var processName: String
    var id: Int32 { pid }
}

nonisolated struct RecorderHealth: Codable, Equatable, Sendable {
    enum Component: String, Codable, Sendable {
        case starting, ready, partial, failed, stopped
    }

    var sessionID: UUID
    var pid: Int32
    var version: String
    var generation: UInt64
    var startedAt: Date
    var updatedAt: Date
    var audio: Component
    var notifications: Component
    var history: Component
    var storage: Component
    var notificationStatus: String
    var activeSources: [ActiveAudioSource]
    var notificationTransport: NotificationTransportMetrics? = nil

    static func read(url: URL = AppInfo.recorderStatus) throws -> RecorderHealth {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func write(url: URL = AppInfo.recorderStatus) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
