import AppKit
import Foundation
import ServiceManagement
import SQLite3

@MainActor final class MockRecorderService: RecorderService {
    var status: SMAppService.Status = .notRegistered
    var helperExists = true
    var helperMustBeStopped: (() -> Bool)?
    var registrations = 0
    var stops = 0
    var failStart = false
    var failStop = false
    func register() throws {
        registrations += 1
        if let helperMustBeStopped, !helperMustBeStopped() { throw CocoaError(.executableRuntimeMismatch) }
        if failStart { throw CocoaError(.fileReadUnknown) }
        status = .enabled
    }
    func unregister() async throws {
        stops += 1
        if failStop { throw CocoaError(.fileReadUnknown) }
        status = .notRegistered
    }
}

@main struct CoreRecorderTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            guard condition else { fatalError("FAIL: " + name) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("events.sqlite")
        var raw: OpaquePointer?
        check(sqlite3_open(dbURL.path, &raw) == SQLITE_OK, "old database created")
        check(sqlite3_exec(raw, "CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT,time REAL NOT NULL,kind TEXT NOT NULL,pid INTEGER NOT NULL DEFAULT 0,bundle_id TEXT NOT NULL DEFAULT '',process TEXT NOT NULL DEFAULT '',detail TEXT NOT NULL DEFAULT ''); INSERT INTO events(time,kind,process) VALUES(100,'audio_start','Old event');", nil, nil, nil) == SQLITE_OK, "old schema fixture")
        sqlite3_close_v2(raw)
        let store = try EventStore(url: dbURL)
        check(try store.events(since: .distantPast).count == 1, "migration preserves history")
        let sample = SoundEvent(time: Date(timeIntervalSince1970: 200),kind:.notification,pid:0,bundleID:"com.example.source",processName:"usernoted",detail:"fixed",sourceKey:"verified-envelope-1")
        check(try store.insert(sample), "first stable source inserted")
        check(try !store.insert(sample), "stable source overlap is idempotent")
        check(try store.events(since: .distantPast).count == 2, "overlap does not duplicate")
        var independent = sample
        independent.sourceKey = nil
        check(try store.insert(independent), "missing identity preserves event")
        check(try store.insert(independent), "same second is not an invented identity")
        var invalidLimitFailed = false
        do { _ = try store.events(since:.distantPast,limit:0) } catch { invalidLimitFailed = true }
        check(invalidLimitFailed, "invalid read limit rejected")
        try store.prune(olderThan: Date(timeIntervalSince1970: 150))
        check(try store.events(since:.distantPast).count == 3, "retention uses event time")
        var destructive: OpaquePointer?
        check(sqlite3_open(dbURL.path,&destructive) == SQLITE_OK, "second connection")
        check(sqlite3_exec(destructive,"DROP TABLE events",nil,nil,nil) == SQLITE_OK, "injected unavailable table")
        sqlite3_close_v2(destructive)
        var readFailed = false
        do { _ = try store.events(since:.distantPast) } catch { readFailed = true }
        check(readFailed,"read error cannot become empty success")

        let suite = "WasThatTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let service = MockRecorderService()
        var clock = Date()
        var health = RecorderHealth(sessionID:UUID(),pid:123,version:"1.1",generation:1,startedAt:clock,updatedAt:clock,audio:.ready,notifications:.ready,history:.ready,storage:.ready,notificationStatus:"collecting",activeSources:[])
        let controller = RecorderController(service:service,defaults:defaults,readHealth:{ health },matchesProcess:{ _ in service.status == .enabled },requestHealth:{ health.generation += 1; health.updatedAt = clock },requestStop:{ health.audio = .stopped; health.notifications = .stopped; health.generation += 1 },now:{ clock })
        await controller.startup()
        check(service.registrations == 1,"first launch starts detector once")
        check(controller.state == .starting,"registration alone is not healthy detection")
        controller.refresh()
        check(controller.state == .listening,"new handshake establishes running health")
        health.notifications = .failed
        controller.refresh()
        check(controller.state == .degraded,"failed notification collector degrades audio")
        check(controller.statusDetail.contains("Notification activity"),"component error is visible")
        health.storage = .failed
        controller.refresh()
        check(controller.statusDetail.contains("saved"),"storage error is visible")
        health.storage = .ready
        health.notifications = .ready
        service.failStop = true
        await controller.setEnabled(false)
        check(controller.state == .failed,"stop failure is not off")
        check(!controller.isEnabled,"stop intent remains off after teardown failure")
        check(defaults.object(forKey:"WasThat.detectionEnabled") as? Bool == false,"stop intent persists before teardown")
        let relaunchedStop = RecorderController(service:service,defaults:defaults,readHealth:{ health },matchesProcess:{ _ in true },requestHealth:{},requestStop:{ health.audio = .stopped; health.notifications = .stopped; health.generation += 1 },now:{ clock })
        await relaunchedStop.startup()
        check(!relaunchedStop.isEnabled && relaunchedStop.state == .failed,"failed Stop is reconciled on relaunch")
        service.failStop = false
        await relaunchedStop.retry()
        check(relaunchedStop.state == .off && !relaunchedStop.isEnabled,"stop retry completes")
        let afterStop = RecorderController(service:service,defaults:defaults,readHealth:{ health },matchesProcess:{ _ in true },requestHealth:{},requestStop:{ health.audio = .stopped; health.notifications = .stopped; health.generation += 1 },now:{ clock })
        await afterStop.startup()
        check(afterStop.state == .off && service.registrations == 1,"explicit stop survives relaunch")
        service.status = .requiresApproval
        await afterStop.setEnabled(true)
        check(afterStop.state == .needsApproval,"approval requirement is visible")
        check(service.registrations == 1,"external revocation is not automatically reversed")
        await afterStop.setEnabled(false)
        check(afterStop.state == .off,"pending approval can be cancelled")
        service.failStart = true
        await afterStop.setEnabled(true)
        check(afterStop.state == .failed && afterStop.lastError != nil,"start failure is visible")
        service.failStart = false
        service.status = .enabled
        let dead = RecorderController(service:service,defaults:defaults,readHealth:{ health },matchesProcess:{ _ in false },requestHealth:{},requestStop:{ health.audio = .stopped; health.notifications = .stopped; health.generation += 1 },now:{ clock })
        await dead.startup()
        clock = clock.addingTimeInterval(12)
        dead.refresh()
        check(dead.state == .failed,"dead helper cannot report healthy registration")
        service.status = .notFound
        service.helperExists = false
        dead.refresh()
        check(dead.state == .failed && dead.statusDetail.contains("missing"),"missing helper is explicit")
        let manualService = MockRecorderService()
        health.audio = .ready
        health.notifications = .ready
        var manualAlive = true
        var manualStopRequests = 0
        let manual = RecorderController(service:manualService,defaults:defaults,readHealth:{ health },matchesProcess:{ _ in manualAlive },requestHealth:{},requestStop:{ manualAlive = false; manualStopRequests += 1; health.audio = .stopped; health.notifications = .stopped; health.generation += 1 },now:{ clock })
        await manual.setEnabled(false)
        check(manualStopRequests == 1 && !manualAlive && manual.state == .off,"unregistered helper is actually stopped")
        health.audio = .ready
        health.notifications = .ready
        health.history = .partial
        manualAlive = true
        manualService.helperMustBeStopped = { !manualAlive }
        let delayController = RecorderController(service:manualService,defaults:defaults,readHealth:{ health },matchesProcess:{ _ in manualAlive },requestHealth:{ health.generation += 1; health.updatedAt = clock },requestStop:{ Task { try? await Task.sleep(for:.milliseconds(250)); manualAlive = false; health.audio = .stopped; health.notifications = .stopped } },now:{ clock })
        await delayController.setEnabled(true)
        check(delayController.state != .failed,"Start also reconciles an unregistered live helper")
        manualService.status = .notRegistered
        manualAlive = true
        health.audio = .ready
        health.notifications = .ready
        await delayController.retry()
        check(!manualAlive && manualService.registrations == 2,"retry waits for an unregistered helper to stop")
        check(delayController.state != .failed,"delayed teardown does not race replacement")
        let freshSuite = suite + ".fresh"
        let freshDefaults = UserDefaults(suiteName:freshSuite)!
        defer { freshDefaults.removePersistentDomain(forName:freshSuite) }
        let missingService = MockRecorderService()
        missingService.status = .notFound
        let firstLaunch = RecorderController(service:missingService,defaults:freshDefaults,readHealth:{ health },matchesProcess:{ _ in false },requestHealth:{},requestStop:{},now:{ clock })
        await firstLaunch.startup()
        check(missingService.registrations == 1,"unregistered service with bundled helper is registered on first launch")
        let healthURL = root.appendingPathComponent("health.json")
        try health.write(url:healthURL)
        check(try RecorderHealth.read(url:healthURL) == health,"typed health round trip")
        let legacyHealth = try RecorderHealth.read(url:healthURL)
        check(legacyHealth.notificationTransport == nil,"older health without transport metrics remains readable")
        health.notificationTransport = NotificationTransportMetrics(peakQueuedEvents:32,peakQueuedBytes:131_072,backpressureWaits:3)
        try health.write(url:healthURL)
        check(try RecorderHealth.read(url:healthURL) == health,"fixed transport metrics preserve health round trip")
        check(health.notificationTransport?.peakQueuedEvents == 32,"transport metrics contain fixed numeric values")
        try Data(repeating:0,count:65_537).write(to:healthURL)
        var oversizeFailed = false
        do { _ = try RecorderHealth.read(url:healthURL) } catch { oversizeFailed = true }
        check(oversizeFailed,"oversized health input rejected")
        print("PASS: \(checks) core recorder and storage checks")
    }
}
