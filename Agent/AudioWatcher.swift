import CoreAudio
import Foundation

/// Reports the moment any process starts or stops playing audio.
/// Event-driven through CoreAudio property listeners: no polling, about zero CPU while idle.
final class AudioWatcher {
    struct Client: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
    }

    var onStart: (Client, Date) -> Void = { _, _ in }
    var onStop: (Client, TimeInterval) -> Void = { _, _ in }

    private struct Watched {
        let client: Client
        var startedAt: Date?
        let listener: AudioObjectPropertyListenerBlock
    }

    private var watched: [AudioObjectID: Watched] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?

    func start() {
        var a = AudioProcess.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncProcessList() }
        }
        AudioObjectAddPropertyListenerBlock(AudioProcess.system, &a, .main, block)
        listListener = block
        syncProcessList()
    }

    private func syncProcessList() {
        let current = Set(AudioProcess.all())
        for object in current where watched[object] == nil { watch(object) }
        for object in watched.keys where !current.contains(object) { unwatch(object) }
    }

    private func watch(_ object: AudioObjectID) {
        let pid = AudioProcess.pid(of: object)
        let client = Client(pid: pid, bundleID: AudioProcess.bundleID(of: object), name: AudioProcess.executableName(of: pid))
        var a = AudioProcess.address(kAudioProcessPropertyIsRunningOutput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.playingChanged(object) }
        }
        AudioObjectAddPropertyListenerBlock(object, &a, .main, block)
        watched[object] = Watched(client: client, startedAt: nil, listener: block)
        playingChanged(object)
    }

    private func unwatch(_ object: AudioObjectID) {
        guard let entry = watched.removeValue(forKey: object) else { return }
        if let started = entry.startedAt { onStop(entry.client, Date().timeIntervalSince(started)) }
        var a = AudioProcess.address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(object, &a, .main, entry.listener)
    }

    private func playingChanged(_ object: AudioObjectID) {
        guard var entry = watched[object] else { return }
        let playing = AudioProcess.isPlaying(object)
        if playing, entry.startedAt == nil {
            let now = Date()
            entry.startedAt = now
            onStart(entry.client, now)
        } else if !playing, let started = entry.startedAt {
            entry.startedAt = nil
            onStop(entry.client, Date().timeIntervalSince(started))
        }
        watched[object] = entry
    }
}
