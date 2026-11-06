// WasThatAgent: the headless recorder. SMAppService starts it at login.
// It sleeps until CoreAudio (and, from M1, the system log) reports something, then writes one row.

import Foundation
import notify

let retention: TimeInterval = 7 * 86_400

let store: EventStore
do {
    store = try EventStore()
} catch {
    NSLog("WasThatAgent: cannot open event store: \(error)")
    exit(1)
}

func record(_ event: SoundEvent) {
    do {
        try store.insert(event)
        notify_post(AppInfo.eventsChanged)
    } catch {
        NSLog("WasThatAgent: write failed: \(error)")
    }
}

let ownPID = getpid()
let watcher = AudioWatcher()
watcher.onStart = { client, time in
    guard client.pid != ownPID else { return }
    record(SoundEvent(time: time, kind: .audioStart, pid: client.pid,
                      bundleID: client.bundleID, processName: client.name))
}
watcher.onStop = { client, duration in
    guard client.pid != ownPID else { return }
    record(SoundEvent(time: Date(), kind: .audioStop, pid: client.pid,
                      bundleID: client.bundleID, processName: client.name,
                      detail: String(format: "%.2f", duration)))
}

try? store.prune(olderThan: Date().addingTimeInterval(-retention))
watcher.start()
RunLoop.main.run()
