import CoreAudio
import Darwin

nonisolated enum AudioReadError: Error {
    case property(OSStatus)
    case malformed
}

/// Reads activity state, never microphone samples or audio amplitude.
@MainActor
enum AudioProcess {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() throws -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
        guard status == noErr else { throw AudioReadError.property(status) }
        guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0, size <= 4_194_304 else { throw AudioReadError.malformed }
        if size == 0 { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)
        guard status == noErr else { throw AudioReadError.property(status) }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func pid(of object: AudioObjectID) throws -> pid_t {
        var a = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
        guard status == noErr else { throw AudioReadError.property(status) }
        guard value > 0 else { throw AudioReadError.malformed }
        return value
    }

    static func bundleID(of object: AudioObjectID) throws -> String {
        var a = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr else { throw AudioReadError.property(status) }
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    static func isPlaying(_ object: AudioObjectID) throws -> Bool {
        var a = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
        guard status == noErr else { throw AudioReadError.property(status) }
        return value != 0
    }

    static func executableName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "Process \(pid)" }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.split(separator: "/").last.map(String.init) ?? "Background process"
    }
}
