import CoreAudio
import Foundation

/// Observes output I/O transitions. An active stream is not proof of an audible transient.
@MainActor
final class AudioWatcher {
    struct Client: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
    }

    var onStart: (Client, Date) -> Void = { _, _ in }
    var onActive: (Client, Date) -> Void = { _, _ in }
    var onStop: (Client, TimeInterval) -> Void = { _, _ in }
    var onFailure: () -> Void = {}
    var onChange: () -> Void = {}

    private struct Watched {
        let client: Client
        var startedAt: Date?
        let listener: AudioObjectPropertyListenerBlock
    }
    private static let triggers: [AudioObjectPropertySelector] = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput]
    private var watched: [AudioObjectID: Watched] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?

    var activeClients: [Client] {
        watched.values.filter { $0.startedAt != nil }.map(\.client).sorted { $0.pid < $1.pid }
    }

    func start() throws {
        guard listListener == nil else { return }
        var a = AudioProcess.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                do { try self?.syncProcessList(initial: false) } catch { self?.onFailure() }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioProcess.system, &a, .main, block)
        guard status == noErr else { throw AudioReadError.property(status) }
        listListener = block
        do { try syncProcessList(initial: true) } catch { stop(); throw error }
    }

    func stop() {
        if let listListener {
            var a = AudioProcess.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioProcess.system, &a, .main, listListener)
        }
        listListener = nil
        for object in Array(watched.keys) { unwatch(object, recordStop: false) }
    }

    private func syncProcessList(initial: Bool) throws {
        let current = Set(try AudioProcess.all())
        var failure = false
        for object in current where watched[object] == nil {
            do { try watch(object, initial: initial) } catch { failure = true }
        }
        for object in Array(watched.keys) where !current.contains(object) { unwatch(object, recordStop: true) }
        if failure { onFailure() }
        onChange()
    }

    private func watch(_ object: AudioObjectID, initial: Bool) throws {
        let pid = try AudioProcess.pid(of: object)
        let client = Client(pid: pid, bundleID: try AudioProcess.bundleID(of: object), name: AudioProcess.executableName(of: pid))
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                do { try self?.playingChanged(object, initial: false) } catch { self?.onFailure() }
            }
        }
        var installed: [AudioObjectPropertySelector] = []
        do {
            for selector in Self.triggers {
                var a = AudioProcess.address(selector)
                let status = AudioObjectAddPropertyListenerBlock(object, &a, .main, block)
                guard status == noErr else { throw AudioReadError.property(status) }
                installed.append(selector)
            }
            watched[object] = Watched(client: client, startedAt: nil, listener: block)
            try playingChanged(object, initial: initial)
        } catch {
            watched.removeValue(forKey: object)
            for selector in installed {
                var a = AudioProcess.address(selector)
                AudioObjectRemovePropertyListenerBlock(object, &a, .main, block)
            }
            throw error
        }
    }

    private func unwatch(_ object: AudioObjectID, recordStop: Bool) {
        guard let entry = watched.removeValue(forKey: object) else { return }
        if recordStop, let started = entry.startedAt { onStop(entry.client, max(0, Date().timeIntervalSince(started))) }
        for selector in Self.triggers {
            var a = AudioProcess.address(selector)
            AudioObjectRemovePropertyListenerBlock(object, &a, .main, entry.listener)
        }
    }

    private func playingChanged(_ object: AudioObjectID, initial: Bool) throws {
        guard var entry = watched[object] else { return }
        let playing = try AudioProcess.isPlaying(object)
        if playing, entry.startedAt == nil {
            let date = Date()
            entry.startedAt = date
            watched[object] = entry
            if initial { onActive(entry.client, date) } else { onStart(entry.client, date) }
        } else if !playing, let started = entry.startedAt {
            entry.startedAt = nil
            watched[object] = entry
            onStop(entry.client, max(0, Date().timeIntervalSince(started)))
        }
        onChange()
    }
}
