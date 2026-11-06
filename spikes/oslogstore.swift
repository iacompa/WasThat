// Spike: can a normal, non-root process read the system log in-process via OSLogStore,
// instead of spawning /usr/bin/log? Measures how long a 10-minute notification query takes.
import Foundation
import OSLog

let t0 = Date()
do {
    let store = try OSLogStore.local()
    print("OSLogStore.local(): OK after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    let since = store.position(date: Date().addingTimeInterval(-600))
    let pred = NSPredicate(format: "process == 'usernoted' OR process == 'NotificationCenter'")
    let t1 = Date()
    let entries = try store.getEntries(at: since, matching: pred)
    var n = 0, withBundle = 0
    for case let e as OSLogEntryLog in entries {
        n += 1
        if e.composedMessage.contains("app:\"") || e.composedMessage.contains("bundle=") { withBundle += 1 }
    }
    print("entries (last 10 min): \(n), mentioning a bundle id: \(withBundle), query took \(String(format: "%.2f", Date().timeIntervalSince(t1)))s")
} catch {
    print("OSLogStore.local() FAILED: \(error)")
}
