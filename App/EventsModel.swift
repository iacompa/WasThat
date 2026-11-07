import AppKit
import Foundation
import Observation
import notify

@MainActor @Observable
final class EventsModel {
    private(set) var events: [SoundEvent] = []
    private(set) var sightings: [Sighting] = []
    private(set) var storeError: String?
    private(set) var lastUpdated: Date?
    let recorder = RecorderController()
    var lookback: TimeInterval = 3_600 { didSet { reload() } }

    @ObservationIgnored private var store: EventStore?
    @ObservationIgnored private var token: Int32 = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var workspaceObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false

    init() {
        reload()
        let status = notify_register_dispatch(AppInfo.eventsChanged, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(); self?.recorder.refresh() }
        }
        if status != NOTIFY_STATUS_OK { storeError = "Live updates are unavailable. Refresh to check recent activity." }
        workspaceObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload(); self?.recorder.refresh() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await recorder.startup() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload(); self?.recorder.refresh() }
        }
    }

    func reload() {
        do {
            if store == nil { store = try EventStore() }
            guard let store else { return }
            let fresh = try store.events(since: Date().addingTimeInterval(-lookback), limit: 2_000)
            events = fresh
            sightings = SoundCorrelator.sightings(from: fresh)
            storeError = nil
            lastUpdated = Date()
        } catch {
            storeError = "Recent activity could not be read. Your previous history is still shown. Choose Refresh to try again."
        }
    }
}
