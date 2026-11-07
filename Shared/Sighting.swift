import Foundation

nonisolated struct Sighting: Identifiable, Hashable, Sendable {
    enum Category: String, Sendable {
        case appAudio, notification, unidentifiedNotificationAudio
    }

    enum Audibility: String, Sendable {
        case activityObserved, playbackReported, suppressed, notEstablished
    }

    var id: String
    var time: Date
    var category: Category
    var bundleID: String?
    var processName: String?
    var audibility: Audibility
    var suppression: NotificationFact.Suppression? = nil
    var evidenceIDs: [Int64] = []
    var candidateBundleIDs: [String] = []
}
