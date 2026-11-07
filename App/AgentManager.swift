import AppKit
import Darwin
import Foundation
import Observation
import ServiceManagement
import notify

@MainActor
protocol RecorderService {
    var status: SMAppService.Status { get }
    var helperExists: Bool { get }
    func register() throws
    func unregister() async throws
}

@MainActor
final class LoginItemService: RecorderService {
    private let service = SMAppService.loginItem(identifier: AppInfo.agentBundleID)
    var status: SMAppService.Status { service.status }
    var helperExists: Bool {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/WasThatAgent.app")
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == AppInfo.agentBundleID,
              let executable = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

@MainActor @Observable
final class RecorderController {
    nonisolated enum State: String, Sendable {
        case off, starting, listening, needsApproval, degraded, failed
    }

    private(set) var state: State = .off
    private(set) var isEnabled: Bool
    private(set) var isBusy = false
    private(set) var lastError: String?
    private(set) var health: RecorderHealth?
    private var stopping = false
    private var pendingStop = false
    private var started = false
    private var startupDeadline: Date?
    private var lastReply: Date?
    private var nextProbe = Date.distantPast
    private var challenge: (UUID?, UInt64, Date)?
    private var deadlineTask: Task<Void, Never>?
    private let service: any RecorderService
    private let defaults: UserDefaults
    private let readHealth: () throws -> RecorderHealth
    private let matchesProcess: (Int32) -> Bool
    private let requestHealth: () -> Void
    private let requestStop: () -> Void
    private let now: () -> Date
    private static let preferenceKey = "WasThat.detectionEnabled"
    private static let stopPendingKey = "WasThat.stopPending"
    private static let configuredKey = "WasThat.detectionConfigured"

    init(service: (any RecorderService)? = nil, defaults: UserDefaults = .standard,
         readHealth: @escaping () throws -> RecorderHealth = { try RecorderHealth.read() },
         matchesProcess: ((Int32) -> Bool)? = nil,
         requestHealth: @escaping () -> Void = { notify_post(AppInfo.healthRequested) },
         requestStop: @escaping () -> Void = { notify_post(AppInfo.stopRequested) },
         now: @escaping () -> Date = Date.init) {
        self.service = service ?? LoginItemService()
        self.defaults = defaults
        self.readHealth = readHealth
        self.matchesProcess = matchesProcess ?? Self.isCurrentHelper
        self.requestHealth = requestHealth
        self.requestStop = requestStop
        self.now = now
        self.isEnabled = defaults.object(forKey: Self.preferenceKey) == nil ? true : defaults.bool(forKey: Self.preferenceKey)
        self.pendingStop = defaults.bool(forKey: Self.stopPendingKey)
    }

    var statusTitle: String {
        if stopping { return "Stopping detection…" }
        switch state {
        case .off: return "Detection is off"
        case .starting: return "Starting detection…"
        case .listening: return "Detecting activity"
        case .needsApproval: return "Allow background detection"
        case .degraded: return "Detection needs attention"
        case .failed: return "Detection unavailable"
        }
    }

    var statusDetail: String {
        if let lastError { return lastError }
        switch state {
        case .off: return "Start detection to keep track of recent app sounds."
        case .starting: return "Connecting to WasThat’s background detector."
        case .needsApproval: return "Allow WasThat in Login Items, then return here. You can stop detection at any time."
        case .failed: return "The detector is not responding. Try again or reopen WasThat."
        case .degraded:
            if health?.storage == .failed { return "Recent activity could not be saved. Retry detection." }
            if health?.audio != .ready { return "App audio detection is unavailable. Notification activity may still appear." }
            if health?.notifications != .ready { return "App audio detection is on. Notification activity is currently unavailable." }
            return "Recent notification history is incomplete. New activity is still being checked."
        case .listening:
            return health?.history == .partial
                ? "New activity is being checked. Some past notifications were not available."
                : "App audio and available notification activity are being checked."
        }
    }

    func startup() async {
        guard !started else { return }
        started = true
        if !isEnabled {
            if pendingStop || service.status != .notRegistered || matchingRunningHelper() != nil {
                await setEnabled(false)
            } else { state = .off }
            return
        }
        if (service.status == .notRegistered || (service.status == .notFound && service.helperExists)) && !defaults.bool(forKey: Self.configuredKey) {
            await setEnabled(true)
        } else {
            state = .starting
            startupDeadline = now().addingTimeInterval(10)
            refresh()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        if enabled && pendingStop {
            await setEnabled(false)
            guard !pendingStop else { return }
        }
        isBusy = true
        stopping = !enabled
        lastError = nil
        deadlineTask?.cancel()
        challenge = nil
        defer { isBusy = false; stopping = false }
        if enabled {
            isEnabled = true
            pendingStop = false
            defaults.set(true, forKey: Self.preferenceKey)
            defaults.set(true, forKey: Self.configuredKey)
            state = .starting
            startupDeadline = now().addingTimeInterval(10)
            do {
                if service.status == .notRegistered || (service.status == .notFound && service.helperExists) {
                    if matchingRunningHelper() != nil { try await stopCurrentHelper() }
                    try service.register()
                }
                refresh(whileBusy: true)
            } catch {
                if service.status == .requiresApproval { state = .needsApproval }
                else { state = .failed; lastError = "WasThat could not start background detection. Retry, or reinstall the app in Applications." }
            }
        } else {
            // Preserve the user's stop request even when system teardown fails.
            isEnabled = false
            pendingStop = true
            defaults.set(false, forKey: Self.preferenceKey)
            defaults.set(true, forKey: Self.stopPendingKey)
            do {
                try await stopCurrentHelper()
                pendingStop = false
                defaults.set(false, forKey: Self.stopPendingKey)
                state = .off
                health = nil
                lastReply = nil
                startupDeadline = nil
            } catch {
                state = .failed
                lastError = "Detection could not be stopped. Retry to stop the background detector."
            }
        }
    }

    private func matchingRunningHelper() -> RecorderHealth? {
        guard let value = try? readHealth(), matchesProcess(value.pid),
              value.audio != .stopped || value.notifications != .stopped else { return nil }
        return value
    }

    private func stopCurrentHelper() async throws {
        let registered = service.status == .enabled || service.status == .requiresApproval
        if registered || matchingRunningHelper() != nil { requestStop() }
        if registered { try await service.unregister() }
        for _ in 0..<20 {
            if matchingRunningHelper() == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard matchingRunningHelper() == nil else { throw CocoaError(.executableRuntimeMismatch) }
    }

    func retry() async {
        guard !isBusy else { return }
        if pendingStop { await setEnabled(false); return }
        if !isEnabled { await setEnabled(true); return }
        if service.status == .requiresApproval { refresh(); return }
        isBusy = true
        lastError = nil
        deadlineTask?.cancel()
        challenge = nil
        do {
            try await stopCurrentHelper()
            guard service.helperExists else { throw CocoaError(.executableNotLoadable) }
            try service.register()
            defaults.set(true, forKey: Self.configuredKey)
            health = nil
            lastReply = nil
            nextProbe = .distantPast
            state = .starting
            startupDeadline = now().addingTimeInterval(10)
        } catch {
            state = service.status == .requiresApproval ? .needsApproval : .failed
            if state == .failed { lastError = "WasThat could not restart detection. Reopen the app and try again." }
        }
        isBusy = false
        if state != .failed { refresh() }
    }

    func refresh() { refresh(whileBusy: false) }

    private func refresh(whileBusy: Bool) {
        guard isEnabled, (!isBusy || whileBusy), !pendingStop else { return }
        switch service.status {
        case .requiresApproval: state = .needsApproval; health = nil; challenge = nil; return
        case .notRegistered:
            state = .failed
            lastError = "Background detection is not enabled. Choose Retry to start it."
            health = nil
            return
        case .notFound:
            state = .failed
            lastError = service.helperExists
                ? "Background detection is not enabled. Choose Retry to start it."
                : "The background detector is missing. Reinstall WasThat in Applications."
            health = nil
            return
        case .enabled: break
        @unknown default: state = .failed; lastError = "macOS could not report detection status."; return
        }
        let date = now()
        let value = try? readHealth()
        let expectedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let value, matchesProcess(value.pid), value.updatedAt <= date.addingTimeInterval(5),
           date.timeIntervalSince(value.updatedAt) < 45,
           (expectedVersion == nil || value.version == expectedVersion) {
            if let challenge, value.sessionID != challenge.0 || value.generation > challenge.1 {
                self.challenge = nil
                lastReply = date
            }
            if lastReply != nil { health = value }
        } else {
            health = nil
            if date > (startupDeadline ?? .distantPast) {
                state = .failed
                lastError = "The background detector is not responding. Retry detection."
                return
            }
        }
        if let challenge, date > challenge.2, date > (startupDeadline ?? .distantPast) {
            state = .failed
            lastError = "The background detector is not responding. Retry detection."
            health = nil
            return
        }
        if let health, let lastReply, date.timeIntervalSince(lastReply) < 45 {
            lastError = nil
            if health.audio == .failed && health.notifications == .failed { state = .failed }
            else if health.audio != .ready || health.notifications != .ready || health.storage != .ready || health.history == .failed { state = .degraded }
            else { state = .listening }
        } else { state = .starting }
        if challenge == nil && date >= nextProbe {
            challenge = (value?.sessionID, value?.generation ?? 0, date.addingTimeInterval(3))
            nextProbe = date.addingTimeInterval(15)
            requestHealth()
            scheduleDeadline()
        }
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        let delay = max(3.1, (startupDeadline ?? now()).timeIntervalSince(now()) + 0.1)
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    private static func isCurrentHelper(_ pid: Int32) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let executable = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/WasThatAgent.app/Contents/MacOS/WasThatAgent").resolvingSymlinksInPath().path
        return URL(fileURLWithPath: executable).resolvingSymlinksInPath().path == expected
    }
}
