// WasThat · M0 spike app
// A guided checklist for the feasibility questions that need a human's ears and eyes.
// Every test appends one JSON line to ~/Library/Application Support/WasThat/spike-results.jsonl.
// Privacy: notification logs persist only fixed, selected facts. Raw payloads stay in memory.

import AppKit
import CoreAudio
import Darwin
import Foundation
import SQLite3
import SwiftUI
import UserNotifications

// MARK: - Results file

enum Results {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WasThat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spike-results.jsonl")
    }()

    @discardableResult
    static func record(_ test: String, _ data: [String: Any]) -> Bool {
        var d = data
        d["test"] = test
        d["time"] = ISO8601DateFormatter().string(from: Date())
        d["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        guard JSONSerialization.isValidJSONObject(d),
              let json = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return false }
        let line = json + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close(); return true
        }
        return (try? line.write(to: url)) != nil
    }
}

// MARK: - Helpers

func fourCC(_ s: OSStatus) -> String {
    if s == noErr { return "noErr" }
    let u = UInt32(bitPattern: s)
    let bytes = [24, 16, 8, 0].map { UInt8((u >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let str = String(bytes: bytes, encoding: .ascii) {
        return "'\(str)' (\(s))"
    }
    return "\(s)"
}

func scrub(_ s: String) -> String {
    var t = s
    t = t.replacingOccurrences(of: #"defaultActionURL:"[^"]*""#, with: "defaultActionURL:<scrubbed>", options: .regularExpression)
    t = t.replacingOccurrences(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, with: "<email>", options: [.regularExpression, .caseInsensitive])
    t = t.replacingOccurrences(of: #"\+?\d[\d\-\s().]{7,}\d"#, with: "<number>", options: .regularExpression)
    return String(t.prefix(400))
}

final class PeakMeter {
    private var peak: Float = 0
    private let lock = NSLock()
    func raise(_ v: Float) { lock.lock(); if v > peak { peak = v }; lock.unlock() }
    var value: Float { lock.lock(); defer { lock.unlock() }; return peak }
}

final class LockedBuffer {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// A 16-bit mono WAV of soft 880 Hz beeps (120 ms on, every 400 ms).
func makeBeepWAV(seconds: Double) -> URL {
    let sr = 44_100
    let n = Int(Double(sr) * seconds)
    var samples = [Int16](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / Double(sr)
        let ph = t.truncatingRemainder(dividingBy: 0.4)
        if ph < 0.12 {
            let env = sin(Double.pi * ph / 0.12)
            samples[i] = Int16(0.22 * env * sin(2 * Double.pi * 880 * t) * 32_767)
        }
    }
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
    samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wasthat-spike-beeps.wav")
    try? d.write(to: url)
    return url
}

// MARK: - CoreAudio

enum CA {
    static let sys = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func processList() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func pid(_ o: AudioObjectID) -> pid_t {
        var a = addr(kAudioProcessPropertyPID); var v: pid_t = -1
        var s = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(o, &a, 0, nil, &s, &v); return v
    }

    static func bundle(_ o: AudioObjectID) -> String {
        var a = addr(kAudioProcessPropertyBundleID)
        var v: Unmanaged<CFString>? = nil
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(o, &a, 0, nil, &s, $0) }
        if st == noErr, let v { return v.takeRetainedValue() as String }
        return ""
    }

    static func running(_ o: AudioObjectID) -> Bool {
        var a = addr(kAudioProcessPropertyIsRunningOutput); var v: UInt32 = 0
        var s = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(o, &a, 0, nil, &s, &v); return v != 0
    }

    static func procName(_ p: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        proc_pidpath(p, &buf, 4096)
        return String(cString: buf).split(separator: "/").last.map(String.init) ?? "?"
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var s = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(sys, &a, UInt32(MemoryLayout<pid_t>.size), &p, &s, &obj)
        return (st == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }

    static func defaultOutputUID() -> String? {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = AudioObjectID(0)
        var s = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &s, &dev) == noErr else { return nil }
        var ua = addr(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>? = nil
        var us = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(dev, &ua, 0, nil, &us, $0) }
        guard st == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - Model

final class Spike: ObservableObject {
    // 1 · notification sound
    @Published var notifStatus = "Not run yet."
    @Published var notifRunning = false
    @Published var notifDone = false
    private var notifData: [String: Any] = [:]

    // 2 · mute
    @Published var phase = "Not run yet."
    @Published var phaseColor: Color = Comic.common
    @Published var muteRunning = false
    @Published var muteDone = false
    @Published var bSilent = false
    @Published var cSilent = false
    @Published var dAudible = true
    @Published var sawIndicator = false
    @Published var gotPrompt = false
    private var muteData: [String: Any] = [:]

    // 3 · deep links
    static let links: [(key: String, url: String)] = [
        ("link1", "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.apple.MobileSMS"),
        ("link2", "x-apple.systempreferences:com.apple.preference.notifications?id=com.apple.MobileSMS"),
    ]
    @Published var linkAnswers: [String: String] = [:]

    // 4 · database
    @Published var dbStatus = "Not run yet."

    @Published var saved = ""
    /// Called when a test finishes (used by --auto mode to quit).
    var onFinish: (() -> Void)?

    private func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
    private func note(_ s: String) { onMain { self.saved = s } }

    // MARK: 1 · Notification sound

    func runNotif() {
        notifRunning = true; notifDone = false
        notifStatus = "Asking for notification permission…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Post through the normal notification API (the hardened runtime blocks osascript's Apple Events).
            let center = UNUserNotificationCenter.current()
            let gate = DispatchSemaphore(value: 0)
            var permission = false
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in permission = granted; gate.signal() }
            gate.wait()
            onMain { self.notifStatus = "Watching log + audio… (about 7 s)" }

            let stream = Process()
            stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            stream.arguments = ["stream", "--level", "debug", "--style", "ndjson", "--predicate",
                                "process == \"usernoted\" OR process == \"NotificationCenter\" OR process == \"coreaudiod\""]
            let pipe = Pipe()
            stream.standardOutput = pipe
            stream.standardError = FileHandle.nullDevice
            let buf = LockedBuffer()
            pipe.fileHandleForReading.readabilityHandler = { buf.append($0.availableData) }
            try? stream.run()
            usleep(1_500_000)

            var state: [AudioObjectID: Bool] = [:]
            for o in CA.processList() { state[o] = CA.running(o) }
            var starts: [[String: Any]] = []
            let t0 = Date()

            let content = UNMutableNotificationContent()
            content.title = "WasThat spike"
            content.body = "Did you hear this notification's sound?"
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))

            while Date().timeIntervalSince(t0) < 5 {
                for o in CA.processList() {
                    let r = CA.running(o)
                    if r && state[o] != true {
                        let p = CA.pid(o)
                        starts.append(["t": (Date().timeIntervalSince(t0) * 100).rounded() / 100,
                                       "process": CA.procName(p), "bundle": CA.bundle(o)])
                    }
                    state[o] = r
                }
                usleep(20_000)
            }
            usleep(700_000)
            stream.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil

            let summary = NotificationLogSanitizer.summarize(buf.string)
            let total = summary.seenLineCount
            let interesting = summary.interestingLines
            let data: [String: Any] = ["notificationPermission": permission, "audioStarts": starts,
                                       "logLinesSeen": total, "interestingLines": interesting]
            let ok = Results.record("notification-sound", data)
            onMain {
                self.notifData = data
                self.saved = ok ? "Test 1 auto-saved ✓" : "Test 1 could not be saved"
                self.onFinish?()
                self.notifRunning = false
                self.notifDone = true
                let who = starts.map { "\($0["process"] ?? "?")" }.joined(separator: ", ")
                self.notifStatus = "Captured \(total) log lines. Audio started in: \(who.isEmpty ? "nothing" : who)"
            }
        }
    }

    func saveNotif(heard: Bool) {
        var d = notifData
        d["userHeardSound"] = heard
        note(Results.record("notification-sound", d) ? "Saved test 1 ✓" : "Could not save test 1")
    }

    // MARK: 2 · Mute

    private func setPhase(_ text: String, _ color: Color) { onMain { self.phase = text; self.phaseColor = color } }

    func runMute() {
        muteRunning = true; muteDone = false
        setPhase("Preparing…", Comic.common)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var info: [String: Any] = [:]
            let wav = makeBeepWAV(seconds: 14)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [wav.path]
            do { try player.run() } catch {
                info["afplayError"] = "\(error)"; finishMute(info); return
            }
            var obj: AudioObjectID? = nil
            for _ in 0..<150 {
                if let o = CA.processObject(for: player.processIdentifier) { obj = o; break }
                usleep(20_000)
            }
            guard let obj else {
                info["afplayProcessObjectFound"] = false
                player.terminate(); finishMute(info); return
            }
            info["afplayProcessObjectFound"] = true

            setPhase("PHASE A · normal: you should HEAR beeps", Comic.uncommon)
            usleep(3_000_000)
            info["runningOutputA"] = CA.running(obj)

            let desc = CATapDescription(stereoMixdownOfProcesses: [obj])
            desc.uuid = UUID()
            desc.name = "WasThat spike mute"
            desc.isPrivate = true
            desc.muteBehavior = .muted
            var tap = AudioObjectID(kAudioObjectUnknown)
            let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
            info["createTap"] = fourCC(tapStatus)
            setPhase("PHASE B · tap only (muted): silent?", Comic.legendary)
            usleep(3_500_000)
            info["runningOutputB"] = CA.running(obj)

            let peak = PeakMeter()
            var agg = AudioObjectID(kAudioObjectUnknown)
            var procID: AudioDeviceIOProcID? = nil
            if tapStatus == noErr, let outUID = CA.defaultOutputUID() {
                let d: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "WasThat-Spike",
                    kAudioAggregateDeviceUIDKey: "com.iacompa.wasthat.spike.\(UUID().uuidString)",
                    kAudioAggregateDeviceMainSubDeviceKey: outUID,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceIsStackedKey: false,
                    kAudioAggregateDeviceTapAutoStartKey: true,
                    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
                    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                       kAudioSubTapUIDKey: desc.uuid.uuidString]],
                ]
                let aggStatus = AudioHardwareCreateAggregateDevice(d as CFDictionary, &agg)
                info["createAggregate"] = fourCC(aggStatus)
                if aggStatus == noErr {
                    let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, input, _, _, _ in
                        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                            guard let data = buffer.mData else { continue }
                            let samples = data.assumingMemoryBound(to: Float.self)
                            var local: Float = 0
                            for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { local = max(local, abs(samples[i])) }
                            peak.raise(local)
                        }
                    }
                    info["createIOProc"] = fourCC(ioStatus)
                    if ioStatus == noErr, let procID {
                        info["deviceStart"] = fourCC(AudioDeviceStart(agg, procID))
                    }
                }
            }
            setPhase("PHASE C · tap + running device: silent?", Comic.rust)
            usleep(3_500_000)
            info["runningOutputC"] = CA.running(obj)
            info["tapCapturedPeakC"] = Double(peak.value)
            info["tapCapturedAudio"] = peak.value > 0.001

            if let procID {
                AudioDeviceStop(agg, procID)
                AudioDeviceDestroyIOProcID(agg, procID)
            }
            if agg != kAudioObjectUnknown { info["destroyAggregate"] = fourCC(AudioHardwareDestroyAggregateDevice(agg)) }
            if tap != kAudioObjectUnknown { info["destroyTap"] = fourCC(AudioHardwareDestroyProcessTap(tap)) }
            setPhase("PHASE D · released: beeps should be BACK", Comic.uncommon)
            usleep(2_500_000)
            player.terminate()
            finishMute(info)
        }
    }

    private func finishMute(_ info: [String: Any]) {
        let ok = Results.record("mute-tap", info)
        onMain {
            self.muteData = info
            self.muteRunning = false
            self.muteDone = true
            self.phase = ok ? "Done · auto-saved ✓" : "Done · could not save"
            self.phaseColor = Comic.yellow
            self.saved = ok ? "Test 2 auto-saved ✓" : "Test 2 could not be saved"
            self.onFinish?()
        }
    }

    func saveMute() {
        var d = muteData
        d["user_B_tapOnly_silent"] = bSilent
        d["user_C_tapPlusDevice_silent"] = cSilent
        d["user_D_audibleAgain"] = dAudible
        d["user_sawMenuBarIndicator"] = sawIndicator
        d["user_gotPermissionPrompt"] = gotPrompt
        note(Results.record("mute-tap", d) ? "Saved test 2 ✓" : "Could not save test 2")
    }

    // MARK: 3 · Deep links

    func open(_ key: String) {
        guard let s = Spike.links.first(where: { $0.key == key })?.url, let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }

    func saveLinks() {
        var d: [String: Any] = [:]
        for l in Spike.links { d[l.key] = ["url": l.url, "landed": linkAnswers[l.key] ?? "not tried"] }
        note(Results.record("settings-deeplink", d) ? "Saved test 3 ✓" : "Could not save test 3")
    }

    // MARK: 4 · Notification DB (structure only)

    func checkDB() {
        let fm = FileManager.default
        let src = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2")
        let tmp = fm.temporaryDirectory.appendingPathComponent("wasthat-spike-db-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        do {
            try fm.copyItem(at: src.appendingPathComponent("db"), to: tmp.appendingPathComponent("db"))
            for f in ["db-wal", "db-shm"] {
                try? fm.copyItem(at: src.appendingPathComponent(f), to: tmp.appendingPathComponent(f))
            }
        } catch {
            dbStatus = "No access yet (Full Disk Access not granted)."
            Results.record("notification-db", ["access": false, "error": scrub("\(error)")])
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent("db").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            dbStatus = "Copied, but SQLite could not open it."
            Results.record("notification-db", ["access": true, "openError": true])
            return
        }
        defer { sqlite3_close(db) }

        func query(_ sql: String) -> [[String]] {
            var stmt: OpaquePointer?
            var rows: [[String]] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    var r: [String] = []
                    for i in 0..<sqlite3_column_count(stmt) {
                        r.append(sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "")
                    }
                    rows.append(r)
                }
            }
            sqlite3_finalize(stmt)
            return rows
        }

        let tables = query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").compactMap(\.first)
        var schema: [String: Any] = [:]
        for t in tables {
            let cols = query("PRAGMA table_info('\(t)')").map { "\($0[1]) \($0[2])" }
            let count = query("SELECT COUNT(*) FROM '\(t)'").first?.first ?? "?"
            schema[t] = ["columns": cols, "rows": count]
        }
        Results.record("notification-db", ["access": true, "schema": schema])
        dbStatus = "✓ Access OK. \(tables.count) tables: \(tables.joined(separator: ", "))"
        note("Saved test 4 ✓")
    }
}

/// Lets the test notification play its sound even while the spike is the frontmost app
/// (without this, macOS asks the app and gets "no options", so no sound).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let presenter = NotificationPresenter()

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = presenter
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    let autoSpike = Spike()

    private func runAutoIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--auto"), i + 1 < args.count else { return false }
        autoSpike.onFinish = { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
        switch args[i + 1] {
        case "notif": autoSpike.runNotif()
        case "mute": autoSpike.runMute()
        default: NSApp.terminate(nil)
        }
        return true
    }

    /// `--snapshot <file.png>` renders the window content to a PNG and quits (design review aid).
    func applicationDidFinishLaunching(_ notification: Notification) {
        if runAutoIfRequested() { return }
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let spike = Spike()
        if args.contains("--done") {
            spike.muteDone = true
            spike.phase = "PHASE B · tap only (muted): silent?"
            spike.phaseColor = Comic.legendary
            spike.saved = "Saved test 2 ✓"
        }
        let renderer = ImageRenderer(content: ContentView(snapshot: true).environmentObject(spike))
        renderer.scale = 2
        if let cg = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }
}

@main
struct SpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var spike = Spike()
    var body: some Scene {
        WindowGroup("WasThat Spike") { ContentView().environmentObject(spike) }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
