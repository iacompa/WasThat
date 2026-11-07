import Foundation

actor FeedEvidence {
    var observations: [NotificationObservation] = []
    var states: [NotificationFeedState] = []
    func observe(_ value: NotificationObservation) { observations.append(value) }
    func state(_ value: NotificationFeedState) { states.append(value) }
    func snapshot() -> ([NotificationObservation], [NotificationFeedState]) { (observations, states) }
}

nonisolated final class CommandPreparationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

actor StartSuspension {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func suspendFirst() async {
        guard !entered else { return }
        await suspend()
    }
}

@main
@MainActor
struct NotificationPipelineTests {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ result: Bool, _ name: String) {
        checks += 1
        if !result { failures.append(name) }
    }

    static let timestamp = "2026-11-06 17:30:00.123456-0500"
    static let subjectA = #"<app:"com.example.chat">"#
    static let subjectB = #"<app:"org.example.mail-helper">"#
    static let tail = #" title:"PRIVATE_TITLE app:\"com.fake.sender\"" body:"PRIVATE_BODY isMuted: true" url:https://private.invalid/path email:private@example.invalid phone:+1 (202) 555-0138"#

    static func line(_ message: String, timestamp: String = timestamp,
                     process: String = "NotificationCenter", extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["eventMessage": message, "timestamp": timestamp,
                                     "processImagePath": "/System/Library/CoreServices/\(process).app/Contents/MacOS/\(process)"]
        object.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func observation(_ data: Data) -> NotificationObservation? {
        if case .observation(let value) = NotificationLogParser.parse(line: data) { return value }
        return nil
    }

    static func event(_ id: Int64, _ observation: NotificationObservation) -> SoundEvent {
        SoundEvent(id: id, time: observation.time, kind: .notification, pid: 0,
                   bundleID: observation.senderBundleID, processName: observation.emitter.rawValue,
                   detail: observation.fact.encodedDetail)
    }

    static func audio(_ id: Int64, _ time: Date, name: String = "afplay", bundle: String = "") -> SoundEvent {
        SoundEvent(id: id, time: time, kind: .audioStart, pid: 42,
                   bundleID: bundle, processName: name)
    }

    static func main() async throws {
        let presented = try line("Presenting " + subjectA + #" as banner (["sound", "list"])"# + tail)
        let a = observation(presented)
        check(a?.senderBundleID == "com.example.chat", "general bundle is attributed")
        check(a?.fact.phase == .presented, "presentation remains a presentation")
        check(a?.fact.soundRequested == true, "sound request is retained")
        check(a?.fact.presentation == .banner, "presentation style is retained")
        check(a?.sourceKey == nil, "missing identity does not create a guessed source key")
        check(a?.time.timeIntervalSince1970 == 1_794_004_200.123456, "log timestamp retains event time")
        let usernoted = observation(try line("Presenting " + subjectA + #" as banner (["sound"])"#,
                                             extra: ["processImagePath": "/usr/sbin/usernoted"]))
        check(usernoted?.senderBundleID == "com.example.chat" && usernoted?.emitter == .usernoted,
              "actual system usernoted path is accepted")
        for image in ["/System/Library/PrivateSpoof/NotificationCenter", "/usr/libexec/usernoted",
                      "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/usernoted"] {
            check(observation(try line("Presenting " + subjectA + #" as banner (["sound"])"#,
                                       extra: ["processImagePath": image])) == nil,
                  "unverified or mismatched emitter path is rejected: " + image)
        }
        let detail = a?.fact.encodedDetail ?? ""
        for token in ["PRIVATE_", "https:", "private@", "202", "com.fake"] {
            check(!detail.contains(token), "encoded facts exclude private token " + token)
        }
        check(NotificationFact.decode(detail: detail) == a?.fact, "typed detail round trip")
        check(NotificationFact.decode(detail: "PRIVATE_BODY") == nil, "legacy arbitrary detail fails closed")
        check(NotificationFact.decode(detail: #"{"version":2,"phase":"presented"}"#) == nil, "unknown detail version fails closed")

        let b = observation(try line("Presenting " + subjectB + #" as none (["list"])"#))
        check(b?.senderBundleID == "org.example.mail-helper", "second unrelated bundle is attributed")
        check(b?.fact.soundRequested == false, "no requested sound remains false")
        check(b?.fact.presentation == NotificationFact.Presentation.none, "none is a real presentation value")
        let blocked = observation(try line("Not playing sound for " + subjectA + ": otherFlag: true, isMuted: false" + tail))
        check(blocked?.fact.phase == .playbackSuppressed, "not playing is not a positive playback")
        check(blocked?.fact.suppression == .unknown, "false mute flag does not invent a suppression reason")
        let muted = observation(try line("Not playing sound for " + subjectA + ": isMuted: true" + tail))
        check(muted?.fact.suppression == .mutedUnspecified, "true mute remains an unspecified mute")
        let played = observation(try line("Playing sound for " + subjectA + ": " + tail))
        check(played?.fact.phase == .playbackReported, "explicit supported playback grammar is separate")
        check(observation(try line("com.example.chat muted by DND suppression" + tail))?.fact.suppression == .focus,
              "explicit sender suppression retains Focus")
        check(observation(try line("com.example.chat muted by display state (displayShared)" + tail))?.fact.suppression == .screenSharing,
              "explicit sender suppression retains display sharing")
        if case .unattributedContext = NotificationLogParser.parse(line: try line("muted by DND suppression" + tail)) {
            check(true, "subjectless suppression remains context")
        } else { check(false, "subjectless suppression remains context") }

        let rejected: [Data] = try [
            line("Presenting " + #"<app:"com.first.sender" app:"com.second.sender"> as banner (["sound"])"#),
            line("Presenting " + #"<app:"com.other.sender"> as privateStyle (["sound"])"#),
            line("Presenting " + #"<body:"app:\"com.fake.sender\""> as banner (["sound"])"#),
            line("Presenting " + #"<app:"https://private.invalid"> as banner (["sound"])"#),
            line("Not playing sound for " + subjectA + #": body:"isMuted: true""#),
            line("com.example.chat muted by other reason body:\"muted by DND suppression\""),
            line("Personal sound text" + tail),
            line("Presenting " + subjectA + #" as banner (["sound"])"#, timestamp: "PRIVATE_TIME"),
            line("Presenting " + subjectA + #" as banner (["sound"])"#, process: "PrivateApp"),
            line("Presenting " + subjectA + #" as banner (["sound"])"#, extra: ["eventMessage": 42]),
            line("Presenting " + subjectA + #" as banner (["sound"])"#, extra: ["timestamp": 42]),
        ]
        for (index, value) in rejected.enumerated() {
            check(observation(value) == nil, "untrusted or malformed event rejected \(index)")
        }
        check(observation(Data("not JSON".utf8)) == nil, "invalid JSON rejected")

        let identity: [String: Any] = ["bootUUID": "12345678-1234-1234-1234-123456789ABC",
                                      "processIdentifier": 123, "threadID": 456,
                                      "machTimestamp": 999_999, "traceID": 88]
        let keyed = observation(try line("Presenting " + subjectA + #" as banner (["sound"])"#, extra: identity))
        let replay = observation(try line("Presenting " + subjectA + #" as banner (["sound"])"# + tail, extra: identity))
        check(keyed?.sourceKey != nil, "validated numeric envelope creates a source key")
        check(keyed?.sourceKey == replay?.sourceKey, "history and live identity ignores private message tails")
        var otherIdentity = identity
        otherIdentity["machTimestamp"] = 1_000_000
        let distinct = observation(try line("Presenting " + subjectA + #" as banner (["sound"])"#, extra: otherIdentity))
        check(keyed?.sourceKey != distinct?.sourceKey, "simultaneous source events remain distinct")
        var badIdentity = identity
        badIdentity["machTimestamp"] = true
        badIdentity["traceID"] = false
        check(observation(try line("Presenting " + subjectA + #" as banner (["sound"])"#, extra: badIdentity))?.sourceKey == nil,
              "Boolean numbers cannot become source identities")
        let utc = observation(try line("Presenting " + subjectA + #" as banner (["sound"])"#,
                                       timestamp: "2026-11-06T22:30:00.123456Z"))
        check(utc?.time == a?.time, "ISO and local-offset timestamps agree")

        if let a, let played, let muted, let b {
            let onlyRequested = SoundCorrelator.sightings(from: [event(1, a)])
            check(onlyRequested.first?.audibility == .notEstablished, "a request alone never proves playback")
            let plusUnrelatedAudio = SoundCorrelator.sightings(from: [event(1, a), audio(2, a.time)])
            check(plusUnrelatedAudio.count == 2, "unrelated app output remains independent")
            check(plusUnrelatedAudio.first(where: { $0.category == .notification })?.audibility == .notEstablished,
                  "unrelated app output cannot promote a request")
            let nc = audio(3, a.time, name: "NotificationCenter", bundle: "com.apple.notificationcenterui")
            let possible = SoundCorrelator.sightings(from: [event(1, a), nc])
            let possibleNC = possible.first { $0.category == .unidentifiedNotificationAudio }
            check(possibleNC?.candidateBundleIDs == [a.senderBundleID], "requested sender is a candidate only")
            check(possibleNC?.bundleID == nil, "candidate notification audio has no asserted sender")
            let direct = SoundCorrelator.sightings(from: [event(4, played), nc])
            check(direct.count == 1, "unique explicit playback can join NotificationCenter output")
            check(direct.first?.evidenceIDs == [3, 4], "joined playback preserves both evidence IDs")
            check(direct.first?.audibility == .playbackReported, "join retains reported rather than measured playback")
            let secondNC = audio(10, a.time.addingTimeInterval(0.8), name: "NotificationCenter",
                                 bundle: "com.apple.notificationcenterui")
            let reverseAmbiguity = SoundCorrelator.sightings(from: [event(4, played), nc, secondNC])
            check(reverseAmbiguity.count == 3, "one report cannot consume two notification audio occurrences")
            check(reverseAmbiguity.filter { $0.category == .unidentifiedNotificationAudio }.count == 2,
                  "both ambiguous audio occurrences remain visible")
            check(reverseAmbiguity.first(where: { $0.category == .notification })?.evidenceIDs == [4],
                  "reverse ambiguity leaves the report independent")
            check(reverseAmbiguity.filter { $0.category == .unidentifiedNotificationAudio }
                .allSatisfy { $0.bundleID == nil && $0.candidateBundleIDs == [a.senderBundleID] },
                  "reverse ambiguous audio retains candidates without asserting a sender")
            let suppression = SoundCorrelator.sightings(from: [event(5, muted), nc])
            check(suppression.count == 2, "suppressed notification cannot consume audio")
            check(suppression.first(where: { $0.category == .notification })?.audibility == .suppressed,
                  "nearby audio cannot override suppression")
            var requestedB = b
            requestedB.fact.soundRequested = true
            let ambiguous = SoundCorrelator.sightings(from: [event(1, a), event(6, requestedB), nc])
            check(ambiguous.first(where: { $0.category == .unidentifiedNotificationAudio })?.candidateBundleIDs.count == 2,
                  "two concurrent senders remain ambiguous")
            let sameSender = SoundCorrelator.sightings(from: [event(1, a), event(7, a), event(4, played)])
            check(sameSender.count == 3, "simultaneous same-sender requests are not guessed into one notification")
            var followup = played
            followup.time = a.time.addingTimeInterval(0.2)
            let chain = SoundCorrelator.sightings(from: [event(1, a), event(4, followup)])
            check(chain.count == 1 && chain.first?.evidenceIDs == [1, 4], "a unique compatible decision chain merges")
            let contradictory = SoundCorrelator.sightings(from: [event(4, played), event(5, muted)])
            check(contradictory.count == 2, "contradictory decisions remain distinct")
            let stopped = SoundEvent(id: 8, time: a.time, kind: .audioStop, pid: 42, bundleID: "", processName: "afplay", detail: "1.36")
            check(SoundCorrelator.sightings(from: [stopped]).isEmpty, "legacy numeric audio stop is not another sound")
            check(SoundCorrelator.sightings(from: [event(9, a)]).first?.id == SoundCorrelator.sightings(from: [event(9, a)]).first?.id,
                  "sighting identity is deterministic")
        }

        var buffer = NotificationLineBuffer(maximumLineBytes: 32, maximumPendingBytes: 64)
        check(try buffer.append(Data("{\"a\":".utf8)).isEmpty, "partial NDJSON waits for a complete line")
        check(try buffer.append(Data("1}\n".utf8)) == [Data("{\"a\":1}".utf8)], "chunk boundaries preserve a line")
        do { _ = try buffer.append(Data(repeating: 65, count: 33)); check(false, "oversized lines fail") }
        catch { check(true, "oversized lines fail") }

        try await feedChecks(presented: presented)
        for failure in failures { print("FAIL: " + failure) }
        if !failures.isEmpty { print("\(failures.count) of \(checks) checks failed"); exit(1) }
        print("PASS: \(checks) notification pipeline checks")
    }

    static func feedChecks(presented: Data) async throws {
        let sink = FeedEvidence()
        let json = String(decoding: presented, as: UTF8.self)
        let emit = "printf '%s\\n' " + shellQuote(json)
        var config = NotificationFeed.Configuration(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                                     streamArguments: ["-c", emit + "; exec sleep 30"],
                                                     historyArguments: { _, _ in ["-c", emit] })
        config.terminationGrace = .milliseconds(100)
        config.retryDelays = [.milliseconds(10), .milliseconds(20), .milliseconds(40)]
        let feed = NotificationFeed(configuration: config,
                                    onObservation: { await sink.observe($0) }, onState: { await sink.state($0) })
        await feed.start()
        try await Task.sleep(for: .milliseconds(150))
        let beforeStop = await sink.snapshot()
        check(beforeStop.0.count == 1, "live child output reaches the callback")
        let scan = try await feed.scan(since: Date(timeIntervalSince1970: 0))
        check(scan.observations.count == 1 && !scan.isPartial, "bounded history query returns parsed facts")
        await feed.stop()
        let stopped = await sink.snapshot()
        check(stopped.1.last == .stopped, "stop ends in stopped state")
        try await Task.sleep(for: .milliseconds(100))
        let afterStop = await sink.snapshot()
        check(afterStop.0.count == stopped.0.count && afterStop.1.last == .stopped,
              "old process callbacks cannot restart a stopped generation")
        for _ in 0..<5 { await feed.start(); await feed.stop() }
        try await Task.sleep(for: .milliseconds(100))
        check(await sink.snapshot().1.last == .stopped, "immediate start-stop cannot publish a stale starting state")

        let stoppedCommand = CommandPreparationCount()
        var stoppedConfig = config
        stoppedConfig.historyArguments = { _, _ in stoppedCommand.increment(); return ["-c", emit] }
        let explicitlyStopped = NotificationFeed(configuration: stoppedConfig,
                                                 onObservation: { _ in }, onState: { _ in })
        await explicitlyStopped.stop()
        do { _ = try await explicitlyStopped.scan(since: Date()); check(false, "stop closes history scan admission") }
        catch is CancellationError { check(true, "stop closes history scan admission") }
        catch { check(false, "stopped scan returns cancellation") }
        check(stoppedCommand.value == 0, "a stopped scan cannot prepare or launch a history child")
        await explicitlyStopped.start()
        let resumedScan = try await explicitlyStopped.scan(since: Date(timeIntervalSince1970: 0))
        check(resumedScan.observations.count == 1 && stoppedCommand.value == 1,
              "a new start reopens history scan admission")
        await explicitlyStopped.stop()

        let gate = StartSuspension()
        let queuedCommand = CommandPreparationCount()
        var queuedConfig = config
        queuedConfig.historyArguments = { _, _ in queuedCommand.increment(); return ["-c", emit] }
        let queuedSink = FeedEvidence()
        let queued = NotificationFeed(configuration: queuedConfig, onObservation: { _ in }, onState: { state in
            await queuedSink.state(state)
            if state == .starting { await gate.suspend() }
        })
        await queued.start()
        await gate.waitForEntry()
        await queued.stop()
        let queuedScan = Task { try await queued.scan(since: Date()) }
        await gate.release()
        do { _ = try await queuedScan.value; check(false, "queued history cannot outlive a suspended start-stop") }
        catch is CancellationError { check(true, "queued history cannot outlive a suspended start-stop") }
        catch { check(false, "queued stopped history returns cancellation") }
        check(queuedCommand.value == 0, "suspended start-stop never prepares a later history child")
        check(await queuedSink.snapshot().1.last == .stopped, "suspended starting callback cannot overwrite stopped state")

        let failures = FeedEvidence()
        config.streamArguments = ["-c", "exit 7"]
        let failing = NotificationFeed(configuration: config,
                                       onObservation: { await failures.observe($0) }, onState: { await failures.state($0) })
        await failing.start()
        try await Task.sleep(for: .milliseconds(500))
        let retries = await failures.snapshot()
        check(retries.1.filter { if case .retrying = $0 { return true }; return false }.count == 3,
              "stream failure has exactly three bounded retries")
        check(retries.1.last == .failed(.exited(code: 7)), "retry exhaustion exposes the fixed failure")
        await failing.stop()

        let timerSink = FeedEvidence()
        config.historyTimeout = .milliseconds(75)
        config.historyArguments = { _, _ in ["-c", "exec sleep 30"] }
        let timed = NotificationFeed(configuration: config,
                                     onObservation: { await timerSink.observe($0) }, onState: { await timerSink.state($0) })
        do { _ = try await timed.scan(since: Date()); check(false, "history deadline terminates its owned child") }
        catch NotificationFeedFailure.timedOut { check(true, "history deadline terminates its owned child") }
        catch { check(false, "history deadline has a fixed typed failure") }
        await timed.stop()

        config.historyTimeout = .seconds(2)
        config.maximumHistoryEvents = 1
        config.historyArguments = { _, _ in ["-c", emit + "; " + emit] }
        let capped = NotificationFeed(configuration: config, onObservation: { _ in }, onState: { _ in })
        let partial = try await capped.scan(since: Date(timeIntervalSince1970: 0))
        check(partial.observations.count == 1 && partial.isPartial, "history event cap exposes partial coverage")
        await capped.stop()

        config.historyArguments = { _, _ in ["-c", "printf 'Operation not permitted PRIVATE_MESSAGE' >&2; exit 1"] }
        let denied = NotificationFeed(configuration: config, onObservation: { _ in }, onState: { _ in })
        do { _ = try await denied.scan(since: Date()); check(false, "access denial is reported") }
        catch NotificationFeedFailure.accessDenied { check(true, "access denial has a fixed typed failure") }
        catch { check(false, "access denial has a fixed typed failure") }
        await denied.stop()

        config.maximumLineBytes = 32
        config.historyArguments = { _, _ in ["-c", "printf '%0100d' 0"] }
        let oversized = NotificationFeed(configuration: config, onObservation: { _ in }, onState: { _ in })
        do { _ = try await oversized.scan(since: Date()); check(false, "history oversized line fails closed") }
        catch NotificationFeedFailure.outputLimit { check(true, "history oversized line fails closed") }
        catch { check(false, "history oversized line has a fixed failure") }
        await oversized.stop()

        config.maximumLineBytes = 65_536
        config.historyArguments = { _, _ in ["-c", "trap '' TERM; exec sleep 30"] }
        let cancelled = NotificationFeed(configuration: config, onObservation: { _ in }, onState: { _ in })
        let clock = ContinuousClock()
        let begin = clock.now
        let scanTask = Task { try await cancelled.scan(since: Date()) }
        try await Task.sleep(for: .milliseconds(100))
        scanTask.cancel()
        do { _ = try await scanTask.value; check(false, "cancelled history does not succeed") }
        catch is CancellationError { check(true, "cancelled history reports cancellation") }
        catch { check(false, "cancelled history reports cancellation rather than timeout") }
        check(begin.duration(to: clock.now) < .seconds(1), "cancellation respects the configured grace period")
        await cancelled.stop()

        try await backpressureChecks()
    }

    static func backpressureChecks() async throws {
        // Match the measured red reproduction: 600 records of 1,248 bytes and a 2 ms callback.
        let object: [String: String] = [
            "timestamp": "2026-11-07T00:00:00.123456Z",
            "processImagePath": "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter",
            "eventMessage": "Presenting <app:\"com.example.burst\"> as banner ([\"sound\"]) title:\""
                + String(repeating: "S", count: 1_000) + "\"",
        ]
        let record = try JSONSerialization.data(withJSONObject: object)
        let quotedRecord = shellQuote(String(decoding: record, as: UTF8.self))
        let burst = "i=0; while [ \"$i\" -lt 600 ]; do printf '%s\\n' " + quotedRecord + "; i=$((i+1)); done"
        var config = NotificationFeed.Configuration(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                                     streamArguments: ["-c", burst + "; exec sleep 30"],
                                                     historyArguments: { _, _ in ["-c", burst] })
        config.terminationGrace = .milliseconds(100)
        config.retryDelays = [.milliseconds(10), .milliseconds(20), .milliseconds(40)]
        let sink = FeedEvidence()
        let feed = NotificationFeed(configuration: config, onObservation: {
            await sink.observe($0)
            try? await Task.sleep(for: .milliseconds(2))
        }, onState: { await sink.state($0) })
        await feed.start()
        for _ in 0..<120 {
            let current = await sink.snapshot()
            if current.0.count == 600 || current.1.contains(where: { if case .failed = $0 { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = await sink.snapshot()
        let metrics = await feed.transportMetrics()
        check(result.0.count == 600, "representative burst delivers every observation exactly once")
        check(!result.1.contains(where: { if case .retrying = $0 { return true }; if case .failed = $0 { return true }; return false }),
              "a bounded valid burst does not exhaust retries")
        check(metrics.backpressureWaits > 0, "slow consumer applies backpressure rather than dropping chunks")
        check(metrics.peakQueuedEvents == 32, "burst reaches but does not exceed the event bound")
        check(metrics.peakQueuedBytes <= 32 * 4_096 && metrics.maximumChunkBytes <= 4_096,
              "transport byte and chunk bounds remain fixed")
        print("BACKPRESSURE: records=600 recordBytes=\(record.count) delivered=\(result.0.count) peakEvents=\(metrics.peakQueuedEvents) peakBytes=\(metrics.peakQueuedBytes) waits=\(metrics.backpressureWaits)")
        await feed.stop()

        let history = NotificationFeed(configuration: config, onObservation: { _ in }, onState: { _ in })
        let scanned = try await history.scan(since: Date(timeIntervalSince1970: 0))
        let eofMetrics = await history.transportMetrics()
        check(scanned.observations.count == 600 && !scanned.isPartial, "normal EOF drains a full queue without losing records")
        check(eofMetrics.peakQueuedEvents == 32 && eofMetrics.backpressureWaits > 0,
              "normal EOF test exercises an actually full queue")
        check(eofMetrics.queuedEvents == 0 && eofMetrics.queuedBytes == 0, "normal EOF leaves no queued payload")
        print("FULL-QUEUE EOF: delivered=\(scanned.observations.count) peakEvents=\(eofMetrics.peakQueuedEvents) peakBytes=\(eofMetrics.peakQueuedBytes) waits=\(eofMetrics.backpressureWaits)")
        await history.stop()

        let gate = StartSuspension()
        let blockedSink = FeedEvidence()
        let twoStreams = "trap '' TERM PIPE; i=0; while [ \"$i\" -lt 600 ]; do printf '%s\\n' " + quotedRecord
            + "; printf '%s\\n' " + quotedRecord + " >&2; i=$((i+1)); done; exec sleep 30"
        config.streamArguments = ["-c", twoStreams]
        let blocked = NotificationFeed(configuration: config, onObservation: {
            await blockedSink.observe($0)
            await gate.suspendFirst()
        }, onState: { await blockedSink.state($0) })
        await blocked.start()
        await gate.waitForEntry()
        for _ in 0..<100 {
            if await blocked.transportMetrics().blockedProducers == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let blockedMetrics = await blocked.transportMetrics()
        check(blockedMetrics.blockedProducers == 2 && blockedMetrics.peakBlockedProducers == 2,
              "stress suspends both background pipe readers at the fixed bound")
        print("BLOCKED STOP: producers=\(blockedMetrics.blockedProducers) peakEvents=\(blockedMetrics.peakQueuedEvents) peakBytes=\(blockedMetrics.peakQueuedBytes)")
        let clock = ContinuousClock()
        let begin = clock.now
        let stopping = Task { await blocked.stop() }
        try await Task.sleep(for: .milliseconds(10))
        await blocked.start()
        await gate.release()
        await stopping.value
        check(begin.duration(to: clock.now) < .seconds(1), "stop wakes blocked producers before bounded child cleanup")
        try await Task.sleep(for: .milliseconds(150))
        let restarted = await blockedSink.snapshot()
        check(restarted.1.last == .collecting, "an old stop cannot overwrite a concurrent new generation")
        check(!restarted.1.contains(where: { if case .failed = $0 { return true }; return false }),
              "stop under backpressure does not become a collector failure")
        await blocked.stop()
        check(await blockedSink.snapshot().1.last == .stopped, "the restarted producer also stops cleanly")
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
