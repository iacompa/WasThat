import Foundation

/// Convert private log payloads to fixed facts. Never return message text or raw metadata.
enum NotificationLogSanitizer {
    static func summarize(_ ndjson: String) -> (seenLineCount: Int, interestingLines: [String]) {
        var total = 0
        var lines: [String] = []
        for line in ndjson.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["eventMessage"] as? String else { continue }
            total += 1
            guard lines.count < 80,
                  let path = object["processImagePath"] as? String,
                  let process = path.split(separator: "/").last.map(String.init),
                  ["usernoted", "NotificationCenter"].contains(process),
                  let fact = fact(from: message) else { continue }
            lines.append("[\(process)] \(fact)")
        }
        return (total, lines)
    }

    private static func fact(from message: String) -> String? {
        let app = #"<[^>\r\n]*\bapp:"com\.iacompa\.wasthat\.spike"[^>\r\n]*>"#
        // Check the first app field too. A later field cannot change the event subject.
        let firstApp = captures(#"\bapp:"([^"\r\n]*)""#, in: message)?.first
        let target = firstApp == "com.iacompa.wasthat.spike"
        if target,
           let match = captures("^Presenting " + app + #" as (banner|none|alert|list) \(\[([^\]\r\n]*)\]\)"#, in: message) {
            let options = match[1].split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            }
            return "spike presentation: style=\(match[0]), soundRequested=\(options.contains("sound"))"
        }
        if let match = captures(#"^Presentation reply com\.iacompa\.wasthat\.spike \[([^\]\r\n]*)\]"#, in: message) {
            let options = match[0].split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            }
            return "spike presentationReply: soundRequested=\(options.contains("sound"))"
        }
        if target,
           let flag = captures("^Not playing sound for " + app + #":[ \t]*(?:[A-Za-z_][A-Za-z0-9_]*:[ \t]*(?:true|false)[ \t]*,[ \t]*)*?isMuted:[ \t]*(true|false)(?=[,;\s})]|$)"#, in: message)?.first {
            return "spike playback: decision=notPlaying, isMuted=\(flag)"
        }
        if target, captures("^Playing sound for " + app + #"(?=[:\s]|$)"#, in: message) != nil {
            return "spike playback: decision=playing"
        }

        // These messages can lack an app ID. Keep their context separate from spike evidence.
        let bundle = #"com\.iacompa\.wasthat\.spike"#
        let suppressionSubject = target ? "(?:" + bundle + "|" + app + ")" : bundle
        let reason = #"(display state \(displayShared\)|DND suppression)(?=[:;,\s]|$)"#
        if let match = captures("^" + suppressionSubject + " muted by " + reason, in: message) {
            return "spike suppression: reason=\(match[0] == "DND suppression" ? "DND" : "displayShared")"
        }
        if let match = captures("^muted by " + reason, in: message) {
            return "suppression context: reason=\(match[0] == "DND suppression" ? "DND" : "displayShared")"
        }
        if let match = captures(#"^Resolved event behavior\s*:?[ \t]+interruptionSuppression:\s*(none|silence|delay delivery)(?=[;,\s})]|$)(?:[ \t]*;[ \t]*resolutionReason:\s*(none|disabled|mode configuration|display shared)(?=[;,\s})]|$))?"#, in: message) {
            let suppression = match[0] == "delay delivery" ? "delayDelivery" : match[0]
            var fields = ["interruptionSuppression=\(suppression)"]
            if match.count == 2,
               let reason = ["none": "none", "disabled": "disabled", "mode configuration": "modeConfiguration",
                             "display shared": "displayShared"][match[1]] {
                fields.append("resolutionReason=\(reason)")
            }
            return "suppression context: " + fields.joined(separator: ", ")
        }
        return nil
    }

    /// Raw captures validate the subject or select fixed facts. They never become output text.
    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
