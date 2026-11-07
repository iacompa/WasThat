import CoreFoundation
import Foundation

/// Parse supported log grammars. Original messages never leave this parser.
nonisolated enum NotificationLogParser {
    static func parse(line: Data) -> NotificationParseResult {
        guard line.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let image = object["processImagePath"] as? String,
              let stamp = object["timestamp"] as? String,
              let time = timestamp(stamp) else { return .malformed }
        let emitter: NotificationObservation.Emitter
        switch image {
        case "/usr/sbin/usernoted": emitter = .usernoted
        case "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter":
            emitter = .notificationCenter
        default: return .ignored
        }

        if let result = notification(message) {
            return .observation(NotificationObservation(time: time, senderBundleID: result.0,
                                                        emitter: emitter, fact: result.1,
                                                        sourceKey: sourceKey(object, time: time)))
        }
        if captures(#"^muted by (DND suppression|display state \(displayShared\))(?=[:;,\s]|$)"#, message) != nil
            || captures(#"^Resolved event behavior\s*:?[ \t]+interruptionSuppression:\s*(none|silence|delay delivery)(?=[;,\s})]|$)"#, message) != nil {
            return .unattributedContext
        }
        return .ignored
    }

    private static func notification(_ message: String) -> (String, NotificationFact)? {
        if let fields = captures(#"^Presenting (<[^>\r\n]*>) as (banner|alert|list|none) \(\[([^\]\r\n]*)\]\)"#, message),
           let subject = subject(fields[0]),
           let style = NotificationFact.Presentation(rawValue: fields[1]) {
            let options = fields[2].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
            }
            // Unknown options are ignored. Only the literal sound token conveys a request.
            return (subject, NotificationFact(phase: .presented, presentation: style,
                                               soundRequested: options.contains("sound")))
        }
        if let fields = captures(#"^Presentation reply ([A-Za-z0-9][A-Za-z0-9.\-]{0,254}) \[([^\]\r\n]*)\]"#, message),
           validBundle(fields[0]) {
            let options = fields[1].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
            }
            return (fields[0], NotificationFact(phase: .presented, soundRequested: options.contains("sound")))
        }
        if let fields = captures(#"^Not playing sound for (<[^>\r\n]*>):[ \t]*(.*)$"#, message),
           let subject = subject(fields[0]), let muted = muteFlag(fields[1]) {
            return (subject, NotificationFact(phase: .playbackSuppressed,
                                               suppression: muted ? .mutedUnspecified : .unknown))
        }
        if let fields = captures(#"^Playing sound for (<[^>\r\n]*>)(?=[:\s]|$)"#, message),
           let subject = subject(fields[0]) {
            return (subject, NotificationFact(phase: .playbackReported))
        }
        if let fields = captures(#"^(<[^>\r\n]*>|[A-Za-z0-9][A-Za-z0-9.\-]{0,254}) muted by (DND suppression|display state \(displayShared\))(?=[:;,\s]|$)"#, message) {
            let bundle = fields[0].hasPrefix("<") ? subject(fields[0]) : (validBundle(fields[0]) ? fields[0] : nil)
            if let bundle {
                return (bundle, NotificationFact(phase: .playbackSuppressed,
                                                  suppression: fields[1] == "DND suppression" ? .focus : .screenSharing))
            }
        }
        return nil
    }

    /// Reject multiple subjects. A quoted title or body cannot supply an app field.
    private static func subject(_ descriptor: String) -> String? {
        let bytes = Array(descriptor.utf8)
        let key = Array("app:\"".utf8)
        var quoted = false
        var escaped = false
        var index = 0
        var subjects: [String] = []
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                index += 1
                continue
            }
            let boundary = index == 0 || [UInt8(60), 32, 9, 59, 44].contains(bytes[index - 1])
            if boundary, index + key.count <= bytes.count,
               Array(bytes[index..<(index + key.count)]) == key {
                let start = index + key.count
                guard let end = bytes[start...].firstIndex(of: 34) else { return nil }
                let candidate = String(decoding: bytes[start..<end], as: UTF8.self)
                guard validBundle(candidate) else { return nil }
                subjects.append(candidate)
                index = end + 1
                continue
            }
            if byte == 34 { quoted = true }
            index += 1
        }
        return subjects.count == 1 ? subjects[0] : nil
    }

    private static func validBundle(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.contains(".")
            && captures(#"^([A-Za-z0-9][A-Za-z0-9\-]*(?:\.[A-Za-z0-9][A-Za-z0-9\-]*)+)$"#, value) != nil
    }

    /// Parse only the structured Boolean prefix. Quoted payloads end this prefix.
    private static func muteFlag(_ tail: String) -> Bool? {
        var remaining = tail[...]
        for _ in 0..<32 {
            guard let expression = try? NSRegularExpression(pattern: #"^[ \t]*([A-Za-z_][A-Za-z0-9_]*):[ \t]*(true|false)(?=[,;\s})]|$)"#),
                  let match = expression.firstMatch(in: String(remaining), range: NSRange(remaining.startIndex..., in: remaining)),
                  let nameRange = Range(match.range(at: 1), in: remaining),
                  let valueRange = Range(match.range(at: 2), in: remaining),
                  let fullRange = Range(match.range, in: remaining) else { return nil }
            if remaining[nameRange] == "isMuted" { return remaining[valueRange] == "true" }
            remaining = remaining[fullRange.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
            guard remaining.first == "," else { return nil }
            remaining = remaining.dropFirst()
        }
        return nil
    }

    private static func timestamp(_ value: String) -> Date? {
        guard value.utf8.count <= 64,
              captures(#"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+\-]\d{2}:?\d{2}))$"#, value) != nil else { return nil }
        var normalized = value.replacingOccurrences(of: " ", with: "T")
        if normalized.count >= 5 {
            let suffix = normalized.suffix(5)
            if suffix.first == "+" || suffix.first == "-" {
                normalized.insert(":", at: normalized.index(normalized.endIndex, offsetBy: -2))
            }
        }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(normalized) { return date }
        return try? Date.ISO8601FormatStyle().parse(normalized)
    }

    private static func unsigned(_ object: Any?) -> UInt64? {
        guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !number.stringValue.isEmpty,
              number.stringValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(number.stringValue)
    }

    private static func sourceKey(_ object: [String: Any], time: Date) -> String? {
        guard let boot = object["bootUUID"] as? String, let bootID = UUID(uuidString: boot),
              let pid = unsigned(object["processIdentifier"]), pid > 0, pid <= UInt32.max,
              let thread = unsigned(object["threadID"]) else { return nil }
        let prefix = "notification-v1:\(bootID.uuidString.lowercased()):\(pid):\(thread):"
        if let mach = unsigned(object["machTimestamp"]), mach > 0 { return prefix + "mach:\(mach)" }
        if let trace = unsigned(object["traceID"]), trace > 0 {
            let microseconds = Int64((time.timeIntervalSince1970 * 1_000_000).rounded())
            return prefix + "trace:\(trace):\(microseconds)"
        }
        return nil
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }
}

/// Incremental framing bounds memory before a private log line reaches JSON parsing.
nonisolated struct NotificationLineBuffer {
    private var pending = Data()
    let maximumLineBytes: Int
    let maximumPendingBytes: Int

    mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= maximumPendingBytes, pending.count <= maximumPendingBytes - bytes.count else {
            throw NotificationFeedFailure.outputLimit
        }
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 10) {
            let count = pending.distance(from: pending.startIndex, to: newline)
            guard count <= maximumLineBytes else { throw NotificationFeedFailure.outputLimit }
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard pending.count <= maximumLineBytes else { throw NotificationFeedFailure.outputLimit }
        return lines
    }

    mutating func finish() throws -> [Data] {
        guard pending.count <= maximumLineBytes else { throw NotificationFeedFailure.outputLimit }
        defer { pending.removeAll(keepingCapacity: false) }
        return pending.isEmpty ? [] : [pending]
    }
}
