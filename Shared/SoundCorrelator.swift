import Foundation

/// Build deterministic evidence groups. Timing alone never proves audible playback.
nonisolated enum SoundCorrelator {
    private struct Group {
        var sighting: Sighting
        var facts: [NotificationFact]
        var requestUUID: UUID?
    }

    static func sightings(from events: [SoundEvent]) -> [Sighting] {
        let ordered = events.enumerated().sorted {
            if $0.element.time != $1.element.time { return $0.element.time < $1.element.time }
            if $0.element.id != $1.element.id { return $0.element.id < $1.element.id }
            return $0.offset < $1.offset
        }
        var groups: [Group] = []
        var audio: [(SoundEvent, Int)] = []
        var unkeyedTimes: [String: [Date]] = [:]
        for (_, event) in ordered where event.kind == .notification {
            if let fact = NotificationFact.decode(detail: event.detail), fact.requestUUID == nil {
                unkeyedTimes[event.bundleID + "|" + fact.phase.rawValue, default: []].append(event.time)
            }
        }
        for (offset, event) in ordered {
            guard event.kind == .notification else {
                // audioActive is intentionally excluded. Existing activity is not a new onset.
                if event.kind == .audioStart { audio.append((event, offset)) }
                continue
            }
            guard !event.bundleID.isEmpty, let fact = NotificationFact.decode(detail: event.detail) else { continue }
            let matches = groups.indices.filter { index in
                let group = groups[index]
                guard group.sighting.bundleID == event.bundleID,
                      abs(event.time.timeIntervalSince(group.sighting.time)) <= 1.5,
                      !group.facts.contains(where: { $0.phase == fact.phase }) else { return false }
                let conflicting = group.facts.contains { old in
                    (old.phase == .playbackReported && fact.phase == .playbackSuppressed)
                        || (old.phase == .playbackSuppressed && fact.phase == .playbackReported)
                }
                guard !conflicting else { return false }
                if let request = fact.requestUUID { return group.requestUUID == request }
                guard group.requestUUID == nil else { return false }
                // Inspect the complete window, including later rows. Input order cannot resolve ambiguity.
                for existing in group.facts {
                    let times = unkeyedTimes[event.bundleID + "|" + existing.phase.rawValue] ?? []
                    guard count(in: times, around: event.time) == 1 else { return false }
                }
                let times = unkeyedTimes[event.bundleID + "|" + fact.phase.rawValue] ?? []
                return count(in: times, around: group.sighting.time) == 1
            }
            if matches.count == 1, let index = matches.first {
                groups[index].facts.append(fact)
                groups[index].sighting.evidenceIDs.append(event.id)
                if fact.phase == .playbackReported { groups[index].sighting.audibility = .playbackReported }
                if fact.phase == .playbackSuppressed {
                    groups[index].sighting.audibility = .suppressed
                    groups[index].sighting.suppression = fact.suppression ?? .unknown
                }
            } else {
                let audibility: Sighting.Audibility = fact.phase == .playbackReported ? .playbackReported
                    : (fact.phase == .playbackSuppressed ? .suppressed : .notEstablished)
                groups.append(Group(sighting: Sighting(id: identity(event, offset: offset), time: event.time,
                                                       category: .notification, bundleID: event.bundleID,
                                                       processName: nil, audibility: audibility,
                                                       suppression: fact.suppression, evidenceIDs: [event.id]),
                                    facts: [fact], requestUUID: fact.requestUUID))
            }
        }

        var compatibleAudioCounts: [Int: Int] = [:]
        for (event, _) in audio where isNotificationCenter(event) {
            for group in compatibleGroups(for: event, in: groups) {
                compatibleAudioCounts[group, default: 0] += 1
            }
        }
        var result: [Sighting] = []
        for (event, offset) in audio {
            if isNotificationCenter(event) {
                let candidates = compatibleGroups(for: event, in: groups)
                if candidates.count == 1, let index = candidates.first,
                   groups[index].sighting.audibility == .playbackReported,
                   compatibleAudioCounts[index] == 1 {
                    groups[index].sighting.evidenceIDs.append(event.id)
                } else {
                    let bundles = Set(candidates.compactMap { groups[$0].sighting.bundleID }).sorted()
                    result.append(Sighting(id: identity(event, offset: offset), time: event.time,
                                           category: .unidentifiedNotificationAudio, bundleID: nil,
                                           processName: "NotificationCenter", audibility: .activityObserved,
                                           evidenceIDs: [event.id], candidateBundleIDs: bundles))
                }
            } else {
                result.append(Sighting(id: identity(event, offset: offset), time: event.time,
                                       category: .appAudio, bundleID: event.bundleID.isEmpty ? nil : event.bundleID,
                                       processName: event.processName, audibility: .activityObserved,
                                       evidenceIDs: [event.id]))
            }
        }
        result.append(contentsOf: groups.map(\.sighting))
        for index in result.indices { result[index].evidenceIDs = Array(Set(result[index].evidenceIDs)).sorted() }
        return result.sorted {
            if $0.time != $1.time { return $0.time > $1.time }
            return $0.id < $1.id
        }
    }

    private static func identity(_ event: SoundEvent, offset: Int) -> String {
        event.id > 0 ? "event-\(event.id)" : "unpersisted-\(offset)"
    }

    private static func isNotificationCenter(_ event: SoundEvent) -> Bool {
        event.processName == "NotificationCenter" || event.bundleID == "com.apple.notificationcenterui"
    }

    private static func compatibleGroups(for event: SoundEvent, in groups: [Group]) -> [Int] {
        groups.indices.filter { index in
            let group = groups[index]
            return abs(event.time.timeIntervalSince(group.sighting.time)) <= 1.5
                && group.sighting.audibility != .suppressed
                && group.facts.contains { $0.phase == .playbackReported || $0.soundRequested == true }
        }
    }

    private static func count(in sorted: [Date], around date: Date) -> Int {
        func boundary(_ target: Date, inclusive: Bool) -> Int {
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle] < target || (inclusive && sorted[middle] == target) { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        return boundary(date.addingTimeInterval(1.5), inclusive: true)
            - boundary(date.addingTimeInterval(-1.5), inclusive: false)
    }
}
