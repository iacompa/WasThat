// Feasibility probe: can a normal (non-root, no special permission) process see
// WHICH process is producing audio, the instant it happens?
import CoreAudio
import Darwin
import Foundation

let sys = AudioObjectID(kAudioObjectSystemObject)

func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func processList() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func pidOf(_ o: AudioObjectID) -> pid_t {
    var a = addr(kAudioProcessPropertyPID); var v: pid_t = -1
    var s = UInt32(MemoryLayout<pid_t>.size)
    AudioObjectGetPropertyData(o, &a, 0, nil, &s, &v); return v
}

func bundleOf(_ o: AudioObjectID) -> String {
    var a = addr(kAudioProcessPropertyBundleID)
    var v: Unmanaged<CFString>? = nil
    var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(o, &a, 0, nil, &s, $0) }
    if st == noErr, let v { let str = v.takeRetainedValue() as String; return str.isEmpty ? "-" : str }
    return "err(\(st))"
}

func isRunningOutput(_ o: AudioObjectID) -> Bool {
    var a = addr(kAudioProcessPropertyIsRunningOutput); var v: UInt32 = 0
    var s = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(o, &a, 0, nil, &s, &v); return v != 0
}

func procName(_ p: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    proc_pidpath(p, &buf, 4096)
    return String(cString: buf).split(separator: "/").last.map(String.init) ?? "?"
}

func run(_ path: String, _ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    try? p.run()
}

let t0 = Date()
func stamp() -> String { String(format: "+%5.2fs", Date().timeIntervalSince(t0)) }

let initial = processList()
print("Audio process objects visible: \(initial.count)")
for o in initial where isRunningOutput(o) {
    print("  already playing: \(procName(pidOf(o))) [\(bundleOf(o))]")
}

var state: [AudioObjectID: Bool] = [:]
for o in initial { state[o] = isRunningOutput(o) }
var fired1 = false, fired2 = false

while Date().timeIntervalSince(t0) < 11 {
    let el = Date().timeIntervalSince(t0)
    if !fired1 && el > 1.5 {
        fired1 = true
        print("\(stamp()) >> posting test notification (sound: Glass)")
        run("/usr/bin/osascript", ["-e", "display notification \"Probe from WasThat planning\" with title \"WasThat test\" sound name \"Glass\""])
    }
    if !fired2 && el > 6 {
        fired2 = true
        print("\(stamp()) >> afplay Tink.aiff")
        run("/usr/bin/afplay", ["/System/Library/Sounds/Tink.aiff"])
    }
    for o in processList() {
        let r = isRunningOutput(o)
        if state[o] == nil { print("\(stamp())    new audio client: \(procName(pidOf(o))) [\(bundleOf(o))]") }
        if state[o] != r {
            if state[o] != nil || r {
                print("\(stamp()) \(r ? "▶︎ START" : "■ stop ") \(procName(pidOf(o))) pid=\(pidOf(o)) [\(bundleOf(o))]")
            }
            state[o] = r
        }
    }
    usleep(20_000)
}
print("done")
