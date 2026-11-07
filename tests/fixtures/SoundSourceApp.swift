// GPL-3.0. Synthetic audio and notification fixtures for local acceptance checks.
// This app does not read or write WasThat data.
import AppKit
import AVFoundation
import Darwin
import UserNotifications

nonisolated private struct FixtureOptions {
    enum Action: String { case play, playOnce = "play-once", notify }
    enum Invalid: Error {
        case unsupported, duplicate, conflicting, missingAction
        var message: String {
            switch self {
            case .unsupported: "Unsupported argument. Use --play, --play-once, --notify, or --quit-after-test."
            case .duplicate: "Duplicate arguments are not allowed."
            case .conflicting: "Choose only one action: --play, --play-once, or --notify."
            case .missingAction: "--quit-after-test requires --play, --play-once, or --notify."
            }
        }
    }
    let action: Action?
    let quitAfterTest: Bool

    init(arguments: [String]) throws {
        var action: Action?
        var quitAfterTest = false
        var seen = Set<String>()
        for argument in arguments {
            guard seen.insert(argument).inserted else { throw Invalid.duplicate }
            let next: Action
            switch argument {
            case "--quit-after-test": quitAfterTest = true; continue
            case "--play": next = .play
            case "--play-once": next = .playOnce
            case "--notify": next = .notify
            default: throw Invalid.unsupported
            }
            guard action == nil else { throw Invalid.conflicting }
            action = next
        }
        guard !quitAfterTest || action != nil else { throw Invalid.missingAction }
        self.action = action
        self.quitAfterTest = quitAfterTest
    }
}

nonisolated private struct FixtureEvent: Encodable {
    let event: String
    let outcome: String
    let bundleID: String
    let message: String
    let trial: Int?
    let total: Int?
}

nonisolated private enum FixtureReporter {
    static func emit(_ message: String, event: String = "status", outcome: String = "running",
                     trial: Int? = nil, total: Int? = nil) {
        let value = FixtureEvent(event: event, outcome: outcome,
                                 bundleID: Bundle.main.bundleIdentifier ?? "missing",
                                 message: message, trial: trial, total: total)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(value)
            bytes.append(0x0A)
            // Direct writes bypass buffered stdout, including when a harness uses a pipe.
            try FileHandle.standardOutput.write(contentsOf: bytes)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Fixture status output failed.\n".utf8))
            Darwin.exit(74)
        }
    }
}

@MainActor
private final class SoundSourceDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let options: FixtureOptions
    private let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
    private let allowedBundleIDs = [
        "com.iacompa.wasthat.test.alpha",
        "com.iacompa.wasthat.test.beta",
    ]
    private var window: NSWindow?
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var automaticDeadline: Task<Void, Never>?
    private var automaticFinished = false
    private var notificationBusy = false
    private let status = NSTextField(wrappingLabelWithString: "Ready. No test has started.")
    private lazy var playButton = NSButton(title: "Play test sound", target: self, action: #selector(playClicked))
    private lazy var notifyButton = NSButton(title: "Send test notification", target: self, action: #selector(notifyClicked))

    init(options: FixtureOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        showWindow()
        guard allowedBundleIDs.contains(Bundle.main.bundleIdentifier ?? "") else {
            finishTest(success: false, message: "Unexpected fixture identity. No test started.", automatic: true, forceExit: true)
            return
        }
        guard let action = options.action else { return }
        let timeout: Int = action == .play ? 40 : action == .playOnce ? 15 : 10
        automaticDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.finishTest(success: false, message: "Automatic test exceeded its \(timeout)-second deadline.",
                             automatic: true, forceExit: true)
        }
        switch action {
        case .play: startPlayback(count: 3, automatic: true)
        case .playOnce: startPlayback(count: 1, automatic: true)
        case .notify:
            notificationTask = Task { await sendNotification(allowPermissionRequest: false, automatic: true) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if options.action != nil && !automaticFinished {
            automaticFinished = true
            FixtureReporter.emit("The automatic test was interrupted before completion.", event: "complete", outcome: "failure")
            stopWork()
            Darwin.exit(1)
        }
        stopWork()
    }

    private func stopWork() {
        automaticDeadline?.cancel()
        automaticDeadline = nil
        playbackTask?.cancel()
        notificationTask?.cancel()
        player?.stop()
        player = nil
    }

    private func showWindow() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "WasThat Test Source"
        let heading = NSTextField(labelWithString: appName)
        heading.font = .systemFont(ofSize: 25, weight: .bold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Synthetic sound and notification tests. This app has no personal inputs. Notification permission is requested only after you click Send test notification.")
        let identity = NSTextField(labelWithString: Bundle.main.bundleIdentifier ?? "Missing bundle ID")
        identity.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        identity.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 14, weight: .medium)
        let stack = NSStackView(views: [heading, identity, explanation, playButton, notifyButton, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 370),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = appName
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func playClicked() { startPlayback(count: 1) }

    private func startPlayback(count: Int, automatic: Bool = false) {
        guard playbackTask == nil, !notificationBusy, (1...3).contains(count) else { return }
        playButton.isEnabled = false
        notifyButton.isEnabled = false
        playbackTask = Task {
            defer {
                player?.stop()
                player = nil
                playButton.isEnabled = true
                notifyButton.isEnabled = true
                playbackTask = nil
            }
            do {
                // Each iteration owns a separate player. The gap leaves distinct output edges.
                for trial in 1...count {
                    try Task.checkCancellation()
                    let current = try AVAudioPlayer(contentsOf: soundURL)
                    player = current
                    current.numberOfLoops = 0
                    current.volume = 1
                    guard current.play() else {
                        finishTest(success: false, message: "Audio playback could not start.", automatic: automatic, total: count)
                        return
                    }
                    setStatus("Playing test sound \(trial) of \(count).", event: "sound_started", trial: trial, total: count)
                    var finished = false
                    for _ in 0..<200 {
                        try await Task.sleep(for: .milliseconds(50))
                        if !current.isPlaying { finished = true; break }
                    }
                    current.stop()
                    player = nil
                    guard finished else {
                        finishTest(success: false, message: "Audio test stopped after its 10-second timeout.",
                                   automatic: automatic, total: count, forceExit: true)
                        return
                    }
                    setStatus("Test sound \(trial) finished.", event: "sound_finished", trial: trial, total: count)
                    if trial < count {
                        setStatus("Two-second silent interval.", trial: trial, total: count)
                        try await Task.sleep(for: .seconds(2))
                    }
                }
                finishTest(success: true, message: "Audio test complete. Played \(count) separate test sound(s).",
                           automatic: automatic, total: count)
            } catch is CancellationError {
                finishTest(success: false, message: "Audio test cancelled.", automatic: automatic, total: count)
            } catch {
                finishTest(success: false, message: "The fixed test sound could not be opened.", automatic: automatic, total: count)
            }
        }
    }

    @objc private func notifyClicked() {
        notificationTask = Task { await sendNotification(allowPermissionRequest: true) }
    }

    private func sendNotification(allowPermissionRequest: Bool, automatic: Bool = false) async {
        guard !notificationBusy, playbackTask == nil else { return }
        notificationBusy = true
        notifyButton.isEnabled = false
        playButton.isEnabled = false
        defer {
            notificationBusy = false
            notifyButton.isEnabled = true
            playButton.isEnabled = true
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        do {
            if settings.authorizationStatus == .notDetermined {
                guard allowPermissionRequest else {
                    finishTest(success: false, message: "No notification sent. Click Send test notification to request permission.", automatic: automatic)
                    return
                }
                setStatus("The owner must answer the macOS notification permission prompt.")
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    finishTest(success: false, message: "Notification permission was not granted. No notification sent.", automatic: automatic)
                    return
                }
            } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
                finishTest(success: false, message: "Notifications are not authorized. Only the owner can change macOS notification settings.", automatic: automatic)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "WasThat test notification"
            content.body = "This is a synthetic notification for the WasThat acceptance test."
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try await center.add(request)
            finishTest(success: true, message: "Notification submitted. macOS settings control presentation and sound.", automatic: automatic)
        } catch {
            finishTest(success: false, message: "The synthetic notification could not be submitted.", automatic: automatic)
        }
    }

    private func finishTest(success: Bool, message: String, automatic: Bool, total: Int? = nil, forceExit: Bool = false) {
        if automatic {
            guard !automaticFinished else { return }
            automaticFinished = true
            automaticDeadline?.cancel()
            automaticDeadline = nil
        }
        player?.stop()
        player = nil
        status.stringValue = message
        FixtureReporter.emit(message, event: "complete", outcome: success ? "success" : "failure", total: total)
        if forceExit || (automatic && (!success || options.quitAfterTest)) {
            stopWork()
            if success { NSApp.terminate(nil) }
            else { Darwin.exit(1) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    private func setStatus(_ message: String, event: String = "status", trial: Int? = nil, total: Int? = nil) {
        status.stringValue = message
        FixtureReporter.emit(message, event: event, trial: trial, total: total)
    }
}

@main
@MainActor
enum SoundSourceApp {
    static func main() {
        let options: FixtureOptions
        do { options = try FixtureOptions(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch {
            let message = (error as? FixtureOptions.Invalid)?.message ?? "Invalid fixture arguments."
            FixtureReporter.emit(message, event: "complete", outcome: "failure")
            Darwin.exit(2)
        }
        let app = NSApplication.shared
        let delegate = SoundSourceDelegate(options: options)
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
