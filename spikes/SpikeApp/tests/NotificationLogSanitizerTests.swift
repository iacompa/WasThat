import Foundation

@main
struct NotificationLogSanitizerTests {
    static func main() throws {
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.append(name) }
        }
        func event(_ message: String, process: String = "NotificationCenter", metadata: String = "") throws -> String {
            let object: [String: Any] = [
                "eventMessage": message,
                "processImagePath": "/System/Library/" + process,
                "category": metadata,
                "messageType": metadata,
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let target = #"<app:"com.iacompa.wasthat.spike">"#
        let privateTail = #" title:"PRIVATE_TITLE" body:"PRIVATE_BODY" url:https://example.invalid/PRIVATE_URL email:person@example.invalid phone:+1 (202) 555-0138"#
        let contaminated = try event("Presenting " + target + #" as banner (["sound", "list"])"# + privateTail,
                                     metadata: "PRIVATE_METADATA https://example.invalid/metadata")
        let presentation = NotificationLogSanitizer.summarize(contaminated)
        let persisted = presentation.interestingLines.joined(separator: "\n")
        for token in ["PRIVATE_TITLE", "PRIVATE_BODY", "https://", "person@", "202", "PRIVATE_METADATA"] {
            check(!persisted.contains(token), "presentation omits private token: " + token)
        }
        check(persisted.contains("style=banner"), "presentation preserves banner style")
        check(persisted.contains("soundRequested=true"), "presentation preserves the sound request")

        let chain = try [
            event("Presentation reply com.iacompa.wasthat.spike [sound, banner, list]", process: "usernoted"),
            event("Presenting " + target + #" as none (["list"])"#),
            event("Resolved event behavior interruptionSuppression: silence; resolutionReason: display shared" + privateTail, process: "usernoted"),
            event("com.iacompa.wasthat.spike muted by display state (displayShared)" + privateTail),
            event("com.iacompa.wasthat.spike muted by DND suppression" + privateTail),
            event("Not playing sound for " + target + ": isMuted: true" + privateTail),
            event("Playing sound for " + target + privateTail),
            event("Resolved event behavior interruptionSuppression: delay delivery; resolutionReason: mode configuration", process: "usernoted"),
            event("Resolved event behavior interruptionSuppression: none; resolutionReason: disabled", process: "usernoted"),
            event("muted by DND suppression" + privateTail),
            event("muted by display state (displayShared)" + privateTail),
        ].joined(separator: "\n")
        let chainResult = NotificationLogSanitizer.summarize(chain)
        let facts = chainResult.interestingLines.joined(separator: "\n")
        for fact in ["presentationReply", "style=none", "soundRequested=false", "interruptionSuppression=silence",
                     "resolutionReason=displayShared", "reason=displayShared", "reason=DND", "decision=notPlaying",
                     "isMuted=true", "decision=playing", "interruptionSuppression=delayDelivery",
                     "resolutionReason=modeConfiguration", "interruptionSuppression=none", "resolutionReason=disabled",
                     "suppression context"] {
            check(facts.contains(fact), "decision chain preserves: " + fact)
        }
        check(!facts.contains("PRIVATE_"), "decision chain omits arbitrary tails")
        check(chainResult.seenLineCount == 11, "valid event count remains compatible")

        let invalid = try [
            event("Personal sound message" + privateTail),
            event("Presenting " + #"<app:"other.bundle"> as banner (["sound"])"# + privateTail),
            event("Presenting " + #"<app:"other.bundle"> as banner (["sound"]) body:"# + target),
            event("Playing sound for " + #"<app:"other.bundle"> body:"# + target),
            event("Presenting " + #"<app:"com.iacompa.wasthat.spike.private"> as banner (["sound"])"#),
            event("Presenting " + target + #" as privateStyle (["sound"])"#),
            event("Presenting " + target + #" as banner (["sound"])"#, process: "PRIVATE_PROCESS"),
            event("on behalf of private process" + privateTail, process: "coreaudiod"),
            event("Not playing sound for " + target + ": isMuted: privateValue"),
            event("Resolved event behavior interruptionSuppression: privateValue; resolutionReason: privateValue"),
            #"{"eventMessage":42,"processImagePath":"/NotificationCenter"}"#,
            #"{"eventMessage":"sound","processImagePath":42}"#,
            "not JSON",
            "{}",
        ].joined(separator: "\n")
        check(NotificationLogSanitizer.summarize(invalid).interestingLines.isEmpty,
              "malformed and unrecognized events fail closed")
        let quotedTailCases: [(String, String)] = [
            ("display reason cannot come from a body", #"com.iacompa.wasthat.spike muted by other reason body:"muted by display state (displayShared)""#),
            ("DND reason cannot come from a body", #"com.iacompa.wasthat.spike muted by other reason body:"muted by DND suppression""#),
            ("context display reason cannot come from a title", #"muted by other reason title:"muted by display state (displayShared)""#),
            ("context DND reason cannot come from a title", #"muted by other reason title:"muted by DND suppression""#),
            ("resolved fields cannot come from a quoted title", #"Resolved event behavior title:"interruptionSuppression: silence; resolutionReason: display shared""#),
            ("interruption suppression cannot come from a body", #"Resolved event behavior body:"interruptionSuppression: delay delivery; ""#),
            ("resolution reason cannot come from a body", #"Resolved event behavior body:"resolutionReason: mode configuration; ""#),
            ("mute flag cannot come from a body", "Not playing sound for " + target + #": body:"isMuted: true; ""#),
            ("mute flag cannot come from a title", "Not playing sound for " + target + #": title:"isMuted: false; ""#),
        ]
        for (name, message) in quotedTailCases {
            let result = NotificationLogSanitizer.summarize(try event(message))
            check(result.interestingLines.isEmpty, name)
        }
        let interruptedFields = try event(#"Resolved event behavior interruptionSuppression: none; title:"resolutionReason: display shared; ""#)
        let interruptedFacts = NotificationLogSanitizer.summarize(interruptedFields).interestingLines.joined()
        check(!interruptedFacts.contains("resolutionReason="), "a title cannot supply a later resolution field")
        let booleanFields = try event("Not playing sound for " + target + ": otherFlag: true, isMuted: true, anotherFlag: true, finalFlag: false")
        check(NotificationLogSanitizer.summarize(booleanFields).interestingLines.first?.contains("isMuted=true") == true,
              "playback finds the mute flag after structured Boolean fields")
        let interruptedBooleanFields = try event("Not playing sound for " + target + #": otherFlag: true, body:"isMuted: true; ""#)
        check(NotificationLogSanitizer.summarize(interruptedBooleanFields).interestingLines.isEmpty,
              "a quoted body ends the structured Boolean fields")
        let repeatedFlag = try event("Not playing sound for " + target + #": isMuted: false title:"isMuted: true; ""#)
        let repeatedFact = NotificationLogSanitizer.summarize(repeatedFlag).interestingLines.joined()
        check(repeatedFact.contains("isMuted=false") && !repeatedFact.contains("isMuted=true"),
              "a later quoted mute flag cannot replace the first structured flag")
        let falseFlag = try event("Not playing sound for " + target + ": isMuted: false")
        check(NotificationLogSanitizer.summarize(falseFlag).interestingLines.first?.contains("isMuted=false") == true,
              "playback preserves an explicit false mute flag")
        let capped = NotificationLogSanitizer.summarize(Array(repeating: contaminated, count: 100).joined(separator: "\n"))
        check(capped.interestingLines.count == 80, "record limit bounds persisted evidence")
        check(capped.seenLineCount == 100, "record limit does not truncate the event count")

        if !failures.isEmpty {
            for name in failures { print("FAIL: " + name) }
            print("\(failures.count) of \(checks) checks failed")
            exit(1)
        }
        print("PASS: \(checks) notification log privacy checks")
    }
}
