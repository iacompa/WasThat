import Foundation
import SQLite3

@main struct ConcurrentMigrationTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("events.sqlite")
        var raw: OpaquePointer?
        guard sqlite3_open(url.path,&raw) == SQLITE_OK else { fatalError("fixture open") }
        guard sqlite3_exec(raw,"CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT,time REAL NOT NULL,kind TEXT NOT NULL,pid INTEGER NOT NULL DEFAULT 0,bundle_id TEXT NOT NULL DEFAULT '',process TEXT NOT NULL DEFAULT '',detail TEXT NOT NULL DEFAULT ''); INSERT INTO events(time,kind,process) VALUES(1,'audio_start','Preserved');",nil,nil,nil) == SQLITE_OK else { fatalError("fixture schema") }
        sqlite3_close_v2(raw)
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let store = try EventStore(url:url)
                    try store.insert(SoundEvent(time:Date(),kind:.notification,pid:0,bundleID:"com.example.test",processName:"usernoted",sourceKey:"one-shared-identity"))
                }
            }
            try await group.waitForAll()
        }
        let store = try EventStore(url:url)
        let rows = try store.events(since:.distantPast)
        guard rows.count == 2, rows.contains(where:{$0.processName == "Preserved"}) else { fatalError("concurrent migration lost rows or duplicate protection") }
        print("PASS: 8 concurrent schema opens, preserved history and shared-key idempotence")
    }
}
