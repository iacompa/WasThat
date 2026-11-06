import Foundation

/// One raw thing the recorder observed. The UI groups these into "sightings".
nonisolated struct SoundEvent: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case audioStart = "audio_start"
        case audioStop = "audio_stop"
        case notification
        case system
    }

    var id: Int64 = 0
    var time: Date
    var kind: Kind
    var pid: Int32
    var bundleID: String
    var processName: String
    var detail: String = ""
}

/// How mysterious a sighting is, shown as a loot tier.
nonisolated enum Rarity: Int, CaseIterable, Sendable {
    case common, uncommon, rare, epic, legendary

    var title: String {
        switch self {
        case .common: "Common"
        case .uncommon: "Uncommon"
        case .rare: "Rare"
        case .epic: "Epic"
        case .legendary: "Legendary"
        }
    }
}
