import Darwin
import Foundation
import notify

// One recorder owns this user's event stream, even if two app copies launch together.
do { try FileManager.default.createDirectory(at: AppInfo.supportDirectory, withIntermediateDirectories: true) }
catch { NSLog("WasThat: the local data folder is unavailable."); exit(0) }
let lockDescriptor = open(AppInfo.recorderLock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
guard lockDescriptor >= 0 else { NSLog("WasThat: the recorder lock is unavailable."); exit(0) }
guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { exit(0) }

@MainActor
final class RecorderRuntime {
    private let watcher = AudioWatcher()
    private var store: EventStore?
    private var feed: NotificationFeed?
    private var pruning: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var healthToken: Int32 = 0
    private var stopToken: Int32 = 0
    private var stopping = false
    private var audioHadFailure = false
    private var health = RecorderHealth(
        sessionID: UUID(), pid: getpid(),
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1",
        generation: 0, startedAt: Date(), updatedAt: Date(), audio: .starting,
        notifications: .starting, history: .starting, storage: .starting,
        notificationStatus: "starting", activeSources: [])

    init() {
        do { store = try EventStore(); health.storage = .ready }
        catch { health.storage = .failed }
    }

    func start() async {
        notify_register_dispatch(AppInfo.healthRequested, &healthToken, .main) { [weak self] _ in
            Task { @MainActor in await self?.publishHealthWithTransport() }
        }
        notify_register_dispatch(AppInfo.stopRequested, &stopToken, .main) { [weak self] _ in
            Task { @MainActor in await self?.stop() }
        }
        watcher.onStart = { [weak self] client, time in self?.audio(client, time: time, kind: .audioStart) }
        watcher.onActive = { [weak self] client, time in self?.audio(client, time: time, kind: .audioActive) }
        watcher.onStop = { [weak self] client, duration in
            self?.audio(client, time: Date(), kind: .audioStop, detail: String(format: "%.2f", duration))
        }
        watcher.onFailure = { [weak self] in
            guard let self, !self.stopping else { return }
            self.audioHadFailure = true
            self.health.audio = .partial
            self.publishHealth()
        }
        watcher.onChange = { [weak self] in self?.publishHealth() }
        do {
            try watcher.start()
            health.audio = audioHadFailure ? .partial : .ready
        } catch { health.audio = .failed }
        let feed = NotificationFeed(onObservation: { [weak self] observation in
            await self?.notification(observation)
        }, onState: { [weak self] state in
            await self?.notificationState(state)
        })
        self.feed = feed
        publishHealth()
        await feed.start()
        guard !stopping, !Task.isCancelled else { return }
        recovery = Task { [weak self] in
            guard let self, !self.stopping, !Task.isCancelled else { return }
            do {
                let result = try await feed.scan(since: Date().addingTimeInterval(-3_600))
                guard !self.stopping, !Task.isCancelled else { return }
                for observation in result.observations { self.notification(observation) }
                self.health.history = result.isPartial ? .partial : .ready
                self.publishHealth()
            } catch {
                guard !self.stopping else { return }
                self.health.history = .partial
                self.publishHealth()
            }
        }
        prune()
        pruning = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                guard let self, !self.stopping else { return }
                self.prune()
            }
        }
    }

    private func audio(_ client: AudioWatcher.Client, time: Date, kind: SoundEvent.Kind, detail: String = "") {
        guard client.pid != getpid(), !stopping else { return }
        record(SoundEvent(time: time, kind: kind, pid: client.pid, bundleID: client.bundleID, processName: client.name, detail: detail))
    }

    private func notification(_ observation: NotificationObservation) {
        guard !stopping else { return }
        record(SoundEvent(time: observation.time, kind: .notification, pid: 0,
                          bundleID: observation.senderBundleID, processName: observation.emitter.rawValue,
                          detail: observation.fact.encodedDetail, sourceKey: observation.sourceKey))
    }

    private func record(_ event: SoundEvent) {
        guard !stopping, let store else { health.storage = .failed; publishHealth(); return }
        do {
            let inserted = try store.insert(event)
            health.storage = .ready
            if inserted { notify_post(AppInfo.eventsChanged) }
        } catch { health.storage = .failed; publishHealth() }
    }

    private func notificationState(_ state: NotificationFeedState) async {
        guard !stopping else { return }
        switch state {
        case .stopped: health.notifications = .stopped; health.notificationStatus = "stopped"
        case .starting: health.notifications = .starting; health.notificationStatus = "starting"
        case .collecting: health.notifications = .ready; health.notificationStatus = "collecting"
        case .retrying: health.notifications = .partial; health.notificationStatus = "retrying"
        case .failed(let failure):
            health.notifications = .failed
            // Fixed categories contain no original log data or notification content.
            switch failure {
            case .launchFailed: health.notificationStatus = "failed:launch"
            case .accessDenied: health.notificationStatus = "failed:access-denied"
            case .timedOut: health.notificationStatus = "failed:timeout"
            case .outputLimit: health.notificationStatus = "failed:output-limit"
            case .malformedOutput: health.notificationStatus = "failed:malformed-output"
            case .exited(let code): health.notificationStatus = "failed:exit:\(code)"
            }
        }
        await publishHealthWithTransport()
    }

    private func publishHealthWithTransport() async {
        guard !stopping else { return }
        let metrics = await feed?.transportMetrics()
        guard !stopping, !Task.isCancelled else { return }
        health.notificationTransport = metrics
        publishHealth()
    }

    private func prune() {
        do {
            guard let store else { throw CocoaError(.fileNoSuchFile) }
            try store.prune(olderThan: Date().addingTimeInterval(-7 * 86_400))
        } catch { health.storage = .failed; publishHealth() }
    }

    private func publishHealth() {
        health.generation &+= 1
        health.updatedAt = Date()
        health.activeSources = watcher.activeClients.prefix(128).map {
            ActiveAudioSource(pid: $0.pid, bundleID: $0.bundleID, processName: $0.name)
        }
        do { try health.write(); notify_post(AppInfo.eventsChanged) }
        catch { NSLog("WasThat: detector status could not be saved.") }
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        recovery?.cancel()
        pruning?.cancel()
        watcher.stop()
        await feed?.stop()
        health.audio = .stopped
        health.notifications = .stopped
        health.history = .stopped
        publishHealth()
        notify_cancel(healthToken)
        notify_cancel(stopToken)
        exit(0)
    }
}

let runtime = RecorderRuntime()
var signalSources: [DispatchSourceSignal] = []
for value in [SIGTERM, SIGINT] {
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
    source.setEventHandler { Task { @MainActor in await runtime.stop() } }
    source.resume()
    signalSources.append(source)
}
Task { await runtime.start() }
RunLoop.main.run()
