import Foundation

/// Selected notification metadata. This type cannot contain notification text.
nonisolated struct NotificationFact: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable {
        case presented, playbackReported, playbackSuppressed
    }

    enum Presentation: String, Codable, Sendable {
        case banner, alert, list, none
    }

    enum Suppression: String, Codable, Sendable {
        case focus, screenSharing, mutedUnspecified, unknown
    }

    var version: Int = 1
    var phase: Phase
    var presentation: Presentation? = nil
    var soundRequested: Bool? = nil
    var suppression: Suppression? = nil
    var requestUUID: UUID? = nil

    var encodedDetail: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(self) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decode(detail: String) -> NotificationFact? {
        guard detail.utf8.count <= 2_048,
              let fact = try? JSONDecoder().decode(Self.self, from: Data(detail.utf8)),
              fact.version == 1 else { return nil }
        switch fact.phase {
        case .presented:
            guard fact.suppression == nil else { return nil }
        case .playbackReported:
            guard fact.suppression == nil, fact.presentation == nil else { return nil }
        case .playbackSuppressed:
            guard fact.presentation == nil else { return nil }
        }
        return fact
    }
}

nonisolated struct NotificationObservation: Hashable, Sendable {
    enum Emitter: String, Sendable {
        case usernoted
        case notificationCenter = "NotificationCenter"
    }

    var time: Date
    var senderBundleID: String
    var emitter: Emitter
    var fact: NotificationFact
    var sourceKey: String? = nil
}

nonisolated enum NotificationParseResult: Sendable {
    case observation(NotificationObservation)
    case unattributedContext
    case ignored
    case malformed
}

/// Shared because bounded framing is compiled into both app and recorder targets.
nonisolated enum NotificationFeedFailure: Error, Equatable, Sendable {
    case launchFailed, accessDenied, timedOut, outputLimit, malformedOutput
    case exited(code: Int32)
}

/// Numerical transport diagnostics. No original log bytes are exposed.
nonisolated struct NotificationTransportMetrics: Codable, Equatable, Sendable {
    var queuedEvents = 0
    var queuedBytes = 0
    var peakQueuedEvents = 0
    var peakQueuedBytes = 0
    var backpressureWaits = 0
    var maximumChunkBytes = 0
    var blockedProducers = 0
    var peakBlockedProducers = 0
}
