import Foundation
import notify
import Observation

/// Reads what the recorder saw and refreshes whenever the agent posts `AppInfo.eventsChanged`.
@Observable
final class EventsModel {
    private(set) var events: [SoundEvent] = []
    private(set) var storeError: String?
    var lookback: TimeInterval = 3_600

    @ObservationIgnored private var store: EventStore?
    @ObservationIgnored private var token: Int32 = 0

    init() {
        do { store = try EventStore() } catch { storeError = "\(error)" }
        reload()
        notify_register_dispatch(AppInfo.eventsChanged, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        events = (try? store?.events(since: Date().addingTimeInterval(-lookback))) ?? []
    }

    /// Sounds only (start events), newest first.
    var sounds: [SoundEvent] { events.filter { $0.kind == .audioStart } }
}
