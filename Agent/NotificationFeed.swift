import Darwin
import Foundation

nonisolated enum NotificationFeedState: Equatable, Sendable {
    case stopped, starting, collecting
    case retrying(attempt: Int)
    case failed(NotificationFeedFailure)
}

nonisolated struct NotificationScanResult: Sendable {
    var observations: [NotificationObservation]
    var coverageStart: Date
    var coverageEnd: Date
    var isPartial: Bool
}

/// One owned live child and one bounded history child. No original log payload is stored.
actor NotificationFeed {
    nonisolated struct Configuration: Sendable {
        var executableURL: URL
        var streamArguments: [String]
        var historyArguments: @Sendable (Date, Date) -> [String]
        var historyTimeout: Duration = .seconds(20)
        var terminationGrace: Duration = .seconds(2)
        var retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        var maximumLineBytes = 65_536
        var maximumPendingBytes = 262_144
        var maximumHistoryEvents = 10_000
        var maximumHistoryBytes = 16 * 1_024 * 1_024

        static var system: Configuration {
            let predicate = #"process == "usernoted" OR process == "NotificationCenter""#
            return Configuration(executableURL: URL(fileURLWithPath: "/usr/bin/log"),
                                 streamArguments: ["stream", "--level", "debug", "--style", "ndjson", "--predicate", predicate],
                                 historyArguments: { since, end in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"
                return ["show", "--style", "ndjson", "--info", "--debug", "--predicate", predicate,
                        "--start", formatter.string(from: since), "--end", formatter.string(from: end)]
            })
        }
    }

    private let configuration: Configuration
    private let onObservation: @Sendable (NotificationObservation) async -> Void
    private let onState: @Sendable (NotificationFeedState) async -> Void
    private var generation: UInt64 = 0
    private var acceptsHistoryScans = true
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<NotificationScanResult, Error>?
    private var liveChild: NotificationChild?
    private var historyChild: NotificationChild?
    private var lastTransportMetrics = NotificationTransportMetrics()

    init(onObservation: @escaping @Sendable (NotificationObservation) async -> Void,
         onState: @escaping @Sendable (NotificationFeedState) async -> Void) {
        configuration = .system
        self.onObservation = onObservation
        self.onState = onState
    }

    init(configuration: Configuration,
         onObservation: @escaping @Sendable (NotificationObservation) async -> Void,
         onState: @escaping @Sendable (NotificationFeedState) async -> Void) {
        self.configuration = configuration
        self.onObservation = onObservation
        self.onState = onState
    }

    func start() async {
        guard streamTask == nil else { return }
        generation &+= 1
        acceptsHistoryScans = true
        lastTransportMetrics = NotificationTransportMetrics()
        let current = generation
        streamTask = Task { await self.runStream(generation: current) }
    }

    func transportMetrics() -> NotificationTransportMetrics {
        liveChild?.transportMetrics ?? historyChild?.transportMetrics ?? lastTransportMetrics
    }

    func scan(since: Date) async throws -> NotificationScanResult {
        guard acceptsHistoryScans, !Task.isCancelled else { throw CancellationError() }
        if let historyTask { return try await historyTask.value }
        let end = Date()
        let child = NotificationChild(executableURL: configuration.executableURL,
                                      arguments: configuration.historyArguments(since, end))
        let current = generation
        historyChild = child
        let task = Task { try await self.readHistory(child, since: since, end: end, generation: current) }
        historyTask = task
        defer {
            if historyChild === child {
                if liveChild == nil { lastTransportMetrics = child.transportMetrics }
                historyChild = nil
                historyTask = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            child.requestTermination()
        }
    }

    func stop() async {
        acceptsHistoryScans = false
        generation &+= 1
        let stoppedGeneration = generation
        streamTask?.cancel()
        historyTask?.cancel()
        streamTask = nil
        historyTask = nil
        let lastChild = liveChild ?? historyChild
        let children = [liveChild, historyChild].compactMap { $0 }
        liveChild = nil
        historyChild = nil
        let grace = configuration.terminationGrace
        await withTaskGroup(of: Void.self) { group in
            for child in children { group.addTask { await child.stop(grace: grace) } }
        }
        guard generation == stoppedGeneration else { return }
        if let lastChild { lastTransportMetrics = lastChild.transportMetrics }
        await onState(.stopped)
    }

    private func runStream(generation current: UInt64) async {
        guard generation == current, !Task.isCancelled else { return }
        await onState(.starting)
        var failure: NotificationFeedFailure = .launchFailed
        let delays = Array(configuration.retryDelays.prefix(3))
        for attempt in 0...delays.count {
            guard generation == current, !Task.isCancelled else { return }
            if attempt > 0 {
                await onState(.retrying(attempt: attempt))
                do { try await Task.sleep(for: delays[attempt - 1]) } catch { return }
                guard generation == current, !Task.isCancelled else { return }
            }
            let child = NotificationChild(executableURL: configuration.executableURL,
                                          arguments: configuration.streamArguments)
            liveChild = child
            do {
                try child.start()
                guard generation == current, !Task.isCancelled else {
                    await child.stop(grace: configuration.terminationGrace)
                    return
                }
                await onState(.collecting)
                failure = await readLive(child, generation: current)
            } catch { failure = .launchFailed }
            await child.stop(grace: configuration.terminationGrace)
            guard generation == current, !Task.isCancelled else { return }
            lastTransportMetrics = child.transportMetrics
            liveChild = nil
        }
        guard generation == current, !Task.isCancelled else { return }
        streamTask = nil
        await onState(.failed(failure))
    }

    private func readLive(_ child: NotificationChild, generation current: UInt64) async -> NotificationFeedFailure {
        var lines = NotificationLineBuffer(maximumLineBytes: configuration.maximumLineBytes,
                                           maximumPendingBytes: configuration.maximumPendingBytes)
        var malformed = 0
        var accessDenied = false
        for await event in child.events {
            guard generation == current, !Task.isCancelled else { return .exited(code: 0) }
            switch event {
            case .output(let data):
                do {
                    for line in try lines.append(data) {
                        switch NotificationLogParser.parse(line: line) {
                        case .observation(let observation):
                            malformed = 0
                            await onObservation(observation)
                            guard generation == current, !Task.isCancelled else { return .exited(code: 0) }
                        case .malformed: malformed += 1
                        case .ignored, .unattributedContext: malformed = 0
                        }
                        if malformed >= 64 { return .malformedOutput }
                    }
                } catch { return .outputLimit }
            case .diagnostic(let bytes):
                accessDenied = accessDenied || Self.denied(bytes)
            case .ended(let code):
                do {
                    for line in try lines.finish() {
                        if case .observation(let observation) = NotificationLogParser.parse(line: line) {
                            await onObservation(observation)
                        }
                    }
                } catch { return .outputLimit }
                return accessDenied ? .accessDenied : .exited(code: code)
            case .readFailed: return .malformedOutput
            }
        }
        return accessDenied ? .accessDenied : .exited(code: 0)
    }

    private func readHistory(_ child: NotificationChild, since: Date, end: Date,
                             generation current: UInt64) async throws -> NotificationScanResult {
        guard acceptsHistoryScans, generation == current, !Task.isCancelled else { throw CancellationError() }
        do { try child.start() } catch { throw NotificationFeedFailure.launchFailed }
        let grace = configuration.terminationGrace
        let timeout = configuration.historyTimeout
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            child.markTimedOut()
            await child.stop(grace: grace)
        }
        defer { deadline.cancel() }
        var lines = NotificationLineBuffer(maximumLineBytes: configuration.maximumLineBytes,
                                           maximumPendingBytes: configuration.maximumPendingBytes)
        var observations: [NotificationObservation] = []
        var sourceKeys = Set<String>()
        var bytesSeen = 0
        var accessDenied = false
        var malformed = 0
        do {
            for await event in child.events {
                guard generation == current, !Task.isCancelled else { throw CancellationError() }
                if child.didTimeOut { throw NotificationFeedFailure.timedOut }
                switch event {
                case .output(let data):
                    bytesSeen += data.count
                    guard bytesSeen <= configuration.maximumHistoryBytes else {
                        await child.stop(grace: grace)
                        return NotificationScanResult(observations: observations, coverageStart: since,
                                                      coverageEnd: end, isPartial: true)
                    }
                    for line in try lines.append(data) {
                        switch NotificationLogParser.parse(line: line) {
                        case .observation(let observation):
                            malformed = 0
                            if let key = observation.sourceKey, !sourceKeys.insert(key).inserted { continue }
                            if observations.count >= configuration.maximumHistoryEvents {
                                await child.stop(grace: grace)
                                return NotificationScanResult(observations: observations, coverageStart: since,
                                                              coverageEnd: end, isPartial: true)
                            }
                            observations.append(observation)
                        case .malformed: malformed += 1
                        case .ignored, .unattributedContext: malformed = 0
                        }
                        if malformed >= 64 { throw NotificationFeedFailure.malformedOutput }
                    }
                case .diagnostic(let data): accessDenied = accessDenied || Self.denied(data)
                case .ended(let code):
                    if accessDenied { throw NotificationFeedFailure.accessDenied }
                    guard code == 0 else { throw NotificationFeedFailure.exited(code: code) }
                    for line in try lines.finish() {
                        if case .observation(let observation) = NotificationLogParser.parse(line: line) {
                            if let key = observation.sourceKey, !sourceKeys.insert(key).inserted { continue }
                            if observations.count >= configuration.maximumHistoryEvents {
                                return NotificationScanResult(observations: observations, coverageStart: since,
                                                              coverageEnd: end, isPartial: true)
                            }
                            observations.append(observation)
                        }
                    }
                    return NotificationScanResult(observations: observations, coverageStart: since,
                                                  coverageEnd: end, isPartial: false)
                case .readFailed: throw NotificationFeedFailure.malformedOutput
                }
            }
            if child.didTimeOut { throw NotificationFeedFailure.timedOut }
            throw CancellationError()
        } catch {
            await child.stop(grace: grace)
            if child.didTimeOut { throw NotificationFeedFailure.timedOut }
            throw error
        }
    }

    private static func denied(_ bytes: Data) -> Bool {
        let text = String(decoding: bytes.prefix(4_096), as: UTF8.self).lowercased()
        return ["permission denied", "operation not permitted", "insufficient privileges", "not authorized", "must be root"]
            .contains { text.contains($0) }
    }
}

private nonisolated enum NotificationChildEvent: Sendable {
    case output(Data), diagnostic(Data), ended(Int32), readFailed

    var payloadBytes: Int {
        switch self {
        case .output(let data), .diagnostic(let data): data.count
        case .ended, .readFailed: 0
        }
    }
}

/// Only Dispatch reader queues call send. Consumers suspend without blocking an executor.
private nonisolated final class NotificationEventChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var buffer: [NotificationChildEvent] = []
    private var consumer: CheckedContinuation<NotificationChildEvent?, Never>?
    private var terminal: NotificationChildEvent?
    private var closed = false
    private var counters = NotificationTransportMetrics()

    init(capacity: Int) { self.capacity = capacity }

    var metrics: NotificationTransportMetrics {
        condition.lock()
        defer { condition.unlock() }
        return counters
    }

    /// A full channel stops its background producer before another payload can enter.
    func send(_ event: NotificationChildEvent) -> Bool {
        condition.lock()
        counters.maximumChunkBytes = max(counters.maximumChunkBytes, event.payloadBytes)
        while buffer.count >= capacity, !closed {
            counters.backpressureWaits += 1
            counters.blockedProducers += 1
            counters.peakBlockedProducers = max(counters.peakBlockedProducers, counters.blockedProducers)
            condition.wait()
            counters.blockedProducers -= 1
        }
        guard !closed else { condition.unlock(); return false }
        if let waiting = consumer {
            consumer = nil
            condition.unlock()
            waiting.resume(returning: event)
            return true
        }
        buffer.append(event)
        counters.queuedEvents = buffer.count
        counters.queuedBytes += event.payloadBytes
        counters.peakQueuedEvents = max(counters.peakQueuedEvents, counters.queuedEvents)
        counters.peakQueuedBytes = max(counters.peakQueuedBytes, counters.queuedBytes)
        condition.unlock()
        return true
    }

    func next() async -> NotificationChildEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting in
                condition.lock()
                if !buffer.isEmpty {
                    let event = buffer.removeFirst()
                    counters.queuedEvents = buffer.count
                    counters.queuedBytes -= event.payloadBytes
                    condition.broadcast()
                    condition.unlock()
                    waiting.resume(returning: event)
                } else if let terminal {
                    self.terminal = nil
                    condition.unlock()
                    waiting.resume(returning: terminal)
                } else if closed {
                    condition.unlock()
                    waiting.resume(returning: nil)
                } else {
                    // Each child has exactly one iterator, owned by its live or history task.
                    consumer = waiting
                    condition.unlock()
                }
            }
        } onCancel: { self.cancel() }
    }

    /// Terminal status follows queued data. EOF never waits for space in the data queue.
    func finish(with event: NotificationChildEvent) {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        let waiting = consumer
        consumer = nil
        if waiting == nil { terminal = event }
        condition.broadcast()
        condition.unlock()
        waiting?.resume(returning: event)
    }

    /// Stop clears queued payloads and wakes both producers before child teardown.
    func cancel() {
        condition.lock()
        closed = true
        terminal = nil
        buffer.removeAll(keepingCapacity: false)
        counters.queuedEvents = 0
        counters.queuedBytes = 0
        let waiting = consumer
        consumer = nil
        condition.broadcast()
        condition.unlock()
        waiting?.resume(returning: nil)
    }
}

private nonisolated struct NotificationChildEvents: AsyncSequence, Sendable {
    typealias Element = NotificationChildEvent
    let channel: NotificationEventChannel

    struct AsyncIterator: AsyncIteratorProtocol {
        let channel: NotificationEventChannel
        mutating func next() async -> NotificationChildEvent? { await channel.next() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(channel: channel) }
}

/// The lock protects lifecycle fields shared by Dispatch sources and process termination.
private nonisolated final class NotificationChild: @unchecked Sendable {
    private let channel = NotificationEventChannel(capacity: 32)
    var events: NotificationChildEvents { NotificationChildEvents(channel: channel) }
    var transportMetrics: NotificationTransportMetrics { channel.metrics }
    private let process = Process()
    private let output = Pipe()
    private let diagnostic = Pipe()
    private let lock = NSLock()
    private var readers: [DispatchSourceRead] = []
    private var endedReaders = 0
    private var exitCode: Int32?
    private var timedOut = false
    private var launched = false
    private var completed = false

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = diagnostic
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        process.terminationHandler = { [weak self] process in self?.exited(process.terminationStatus) }
        try process.run()
        lock.withLock { launched = true }
        installReader(output.fileHandleForReading, isDiagnostic: false)
        installReader(diagnostic.fileHandleForReading, isDiagnostic: true)
    }

    var didTimeOut: Bool { lock.withLock { timedOut } }
    func markTimedOut() { lock.withLock { timedOut = true } }

    func requestTermination() {
        if lock.withLock({ launched }), process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGTERM) }
    }

    func stop(grace: Duration) async {
        channel.cancel()
        let sources = lock.withLock { readers }
        for source in sources { source.cancel() }
        requestTermination()
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: grace)
        while process.isRunning, clock.now < end { await Self.pause() }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            for _ in 0..<10 where process.isRunning { await Self.pause() }
        }
    }

    private static func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
        }
    }

    private func installReader(_ handle: FileHandle, isDiagnostic: Bool) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                                   queue: DispatchQueue(label: "com.iacompa.wasthat.notification-reader"))
        let index = lock.withLock { () -> Int in readers.append(source); return readers.count - 1 }
        source.setEventHandler { [weak self] in self?.read(descriptor, index: index, isDiagnostic: isDiagnostic) }
        source.setCancelHandler { [weak self] in
            try? handle.close()
            self?.readerEnded()
        }
        source.resume()
    }

    private func read(_ descriptor: Int32, index: Int, isDiagnostic: Bool) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let bytes = Data(buffer.prefix(count))
                if !channel.send(isDiagnostic ? .diagnostic(bytes) : .output(bytes)) {
                    lock.withLock { readers[index] }.cancel()
                    return
                }
            } else if count == 0 {
                lock.withLock { readers[index] }.cancel()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else {
                _ = channel.send(.readFailed)
                lock.withLock { readers[index] }.cancel()
                return
            }
        }
    }

    private func exited(_ code: Int32) {
        lock.withLock { exitCode = code }
        finishIfReady()
    }

    private func readerEnded() {
        lock.withLock { endedReaders += 1 }
        finishIfReady()
    }

    private func finishIfReady() {
        let status = lock.withLock { () -> Int32? in
            guard !completed, endedReaders == 2, let exitCode else { return nil }
            completed = true
            return exitCode
        }
        if let status { channel.finish(with: .ended(status)) }
    }
}
