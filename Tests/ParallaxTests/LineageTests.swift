import CoreFoundation
import XCTest
@testable import Parallax

final class LineageTests: ChatFixture {
    private let parent = "local_parent"

    private var lineage: [String: Any] {
        ["spawnedFrom": ["sessionId": parent, "taskId": "task", "title": "Parent", "name": "Child",
                         "sideSession": true, "sharedFolder": false, "wakeParent": true, "pendingPop": true,
                         "joinInFlight": true, "proposalPicks": ["private"], "sharedCheckout": true],
         "spawnedFromEndNotified": true, "forkedFromSessionId": parent, "forkedAtMessageUuid": "message"]
    }

    private func assertClaudeAcceptsSession(_ record: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        func parentID(_ value: Any?) throws {
            let id = try XCTUnwrap(value as? String, file: file, line: line)
            XCTAssertTrue(id.hasPrefix("local_"), file: file, line: line)
            XCTAssertNotEqual(id, record["sessionId"] as? String, file: file, line: line)
            XCTAssertNotNil(id.range(of: #"^local_[\p{L}\p{N}_-]+$"#, options: .regularExpression), file: file, line: line)
        }
        if let value = record["spawnedFrom"] {
            let spawn = try XCTUnwrap(value as? [String: Any], file: file, line: line)
            try parentID(spawn["sessionId"])
            XCTAssertTrue(spawn["taskId"] is String, file: file, line: line)
            for key in ["title", "name"] where spawn[key] != nil { XCTAssertTrue(spawn[key] is String, file: file, line: line) }
            for key in ["sideSession", "userFork", "handOff", "btw", "sharedFolder"] {
                if let flag = spawn[key] { XCTAssertEqual(CFGetTypeID(flag as CFTypeRef), CFBooleanGetTypeID(), file: file, line: line) }
            }
            if let deleted = spawn["deletedParent"] {
                let object = try XCTUnwrap(deleted as? [String: Any], file: file, line: line)
                XCTAssertTrue(object["sessionId"] is String, file: file, line: line)
                if let title = object["title"] { XCTAssertTrue(title is String, file: file, line: line) }
            }
        }
        if let id = record["forkedFromSessionId"] { try parentID(id) }
        if let uuid = record["forkedAtMessageUuid"] { XCTAssertTrue(uuid is String, file: file, line: line) }
        for key in ["lineageDetached", "spawnedFromEndNotified"] {
            if let flag = record[key] { XCTAssertEqual(CFGetTypeID(flag as CFTypeRef), CFBooleanGetTypeID(), file: file, line: line) }
        }
    }

    func testAddCarriesSubChatLineageButNotPrivateFields() throws {
        for trusted in [false, true] {
            let a = space("A-\(trusted)"), b = space("B-\(trusted)")
            try writeNativeChat(in: a, lines: [line("user", "child")], lastActivity: 100, trusted: trusted,
                                extra: lineage.merging(["worktreePath": "/private/tree"]) { _, new in new })
            try writeNativeChat(in: a, lines: [line("user", "parent")], lastActivity: 90, chatID: parent, cliSessionID: "parent")
            _ = try namespace(b)
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 2)
            let child = try record(b)
            try assertClaudeAcceptsSession(child)
            XCTAssertEqual(Set((child["spawnedFrom"] as? [String: Any] ?? [:]).keys), ["sessionId", "taskId", "title", "name", "sideSession", "sharedFolder"])
            XCTAssertEqual(child["forkedFromSessionId"] as? String, parent)
            XCTAssertEqual(child["forkedAtMessageUuid"] as? String, "message")
            XCTAssertEqual(child["spawnedFromEndNotified"] as? Bool, true)
            XCTAssertNil(child["spawnSeed"])
            XCTAssertNil(child["worktreePath"])
            XCTAssertTrue(String(decoding: try Data(contentsOf: recordURL(b)), as: UTF8.self).contains(#""sideSession":true"#))
            XCTAssertNotNil(try record(b, id: parent)["sessionId"])
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
        }
    }

    func testExistingFlatCopyIsRepairedOnceAsMetadataOnly() throws {
        for reverse in [false, true] {
            let a = space(reverse ? "Z-source" : "A-source"), b = space(reverse ? "A-target" : "Z-target")
            try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, extra: lineage)
            try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
            let raw = try Data(contentsOf: native(b))
            XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
            let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
            XCTAssertEqual(result.transferred, 1)
            XCTAssertEqual(try Data(contentsOf: native(b)), raw)
            XCTAssertTrue(try savedFiles().allSatisfy { $0.pathExtension == "json" })
            try assertClaudeAcceptsSession(record(b))
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
        }
        XCTAssertEqual(try savedFiles().count, 2)
    }

    func testNullLineageKeyConverges() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, extra: lineage)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100, extra: ["forkedFromSessionId": NSNull()])
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
        XCTAssertEqual(try savedFiles().count, 1)
        try assertClaudeAcceptsSession(record(b))
    }

    func testLineageComesFromWhicheverCopyHasIt() throws {
        let a = space("A"), b = space("B"), c = space("C")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, extra: lineage)
        try writeNativeChat(in: b, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200, extra: ["importedFrom": "local-1p-code", "resumeConfirmed": true])
        _ = try namespace(c)
        XCTAssertEqual(ClaudeChats.syncAll(to: c, spaces: [a, b, c], backups: backups).transferred, 1)
        XCTAssertEqual(try record(c)["forkedFromSessionId"] as? String, parent)
        XCTAssertTrue(try String(contentsOf: native(c), encoding: .utf8).contains("more"))
    }

    func testDestinationLineageWins() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "new")], lastActivity: 200, extra: lineage)
        let own: [String: Any] = ["spawnedFrom": ["sessionId": "local_other", "taskId": "own", "wakeParent": true,
                                                "deletedParent": ["sessionId": parent, "title": "Gone"]], "lineageDetached": true]
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100, extra: own)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        let result = try record(b)
        XCTAssertEqual(result["lineageDetached"] as? Bool, true)
        XCTAssertEqual(result["spawnedFrom"] as? NSDictionary, own["spawnedFrom"] as? NSDictionary)
        XCTAssertNil(result["forkedFromSessionId"])
        try assertClaudeAcceptsSession(result)
    }

    func testInvalidLineageIsOmittedButChatCarried() throws {
        let invalid: [[String: Any]] = [
            ["spawnedFrom": ["sessionId": parent]], ["spawnedFrom": ["sessionId": 12, "taskId": "t"]],
            ["spawnedFrom": ["sessionId": "local_../bad", "taskId": "t"]],
            ["spawnedFrom": ["sessionId": chatID, "taskId": "t"]],
            ["forkedFromSessionId": NSNull(), "forkedAtMessageUuid": 12, "lineageDetached": 1],
            ["spawnedFrom": ["sessionId": parent, "taskId": "t", "sideSession": 1, "title": 2,
                             "deletedParent": ["sessionId": 3]]],
        ]
        for (index, extra) in invalid.enumerated() {
            let a = space("A\(index)"), b = space("B\(index)")
            try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, extra: extra)
            _ = try namespace(b)
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
            let result = try record(b)
            try assertClaudeAcceptsSession(result)
            if index < 5 { XCTAssertNil(result["spawnedFrom"]) }
            else {
                let spawn = try XCTUnwrap(result["spawnedFrom"] as? [String: Any])
                XCTAssertNil(spawn["sideSession"]); XCTAssertNil(spawn["title"]); XCTAssertNil(spawn["deletedParent"])
            }
        }
    }

    func testMessageUpdateBacksUpInvalidDestinationLineageBeforeSanitizingIt() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200, extra: lineage)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100,
                            extra: ["spawnedFrom": ["sessionId": parent, "taskId": "own", "sideSession": 1,
                                                   "deletedParent": ["sessionId": NSNull()], "wakeParent": true],
                                    "forkedFromSessionId": NSNull(), "lineageDetached": 1])
        let before = try Data(contentsOf: recordURL(b))
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        let result = try record(b)
        try assertClaudeAcceptsSession(result)
        let spawn = try XCTUnwrap(result["spawnedFrom"] as? [String: Any])
        XCTAssertNil(spawn["sideSession"]); XCTAssertNil(spawn["deletedParent"])
        XCTAssertEqual(spawn["wakeParent"] as? Bool, true)
        XCTAssertTrue(try savedFiles().contains { (try? Data(contentsOf: $0)) == before })
    }

    func testChildWhoseParentIsNotCarried() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "child")], lastActivity: 100, extra: lineage)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(try record(b)["forkedFromSessionId"] as? String, parent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try recordURL(b, id: parent).path))
    }

    func testLineageRoundTripIsIdempotentAndKeepsOriginalAccountNative() throws {
        let a = space("A"), b = space("B")
        let own: [String: Any] = ["model": "own", "effort": "high", "agent": "local", "originCwd": "/work",
            "worktreePath": cwd, "worktreeName": "own-tree", "isStarred": true, "prs": ["pr"],
            "sessionPermissionUpdates": ["own": true], "priorCliSessionIds": ["old"],
            "interruptedByQuitAt": 100, "armedWorkAtQuit": true, "lastAssistantUuid": "old"]
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, extra: lineage.merging(own) { _, new in new })
        let before = try record(a)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        try append("new", to: native(b))
        try editRecord(b) { $0["lastActivityAt"] = 200; $0["title"] = "New title" }
        XCTAssertEqual(ClaudeChats.syncAll(to: a, spaces: [a, b], backups: backups).transferred, 1)
        let after = try record(a)
        for key in ["spawnedFrom", "model", "effort", "agent", "originCwd", "worktreePath", "worktreeName", "spawnSeed", "isStarred", "prs", "sessionPermissionUpdates", "priorCliSessionIds"] {
            XCTAssertEqual(NSDictionary(dictionary: [key: after[key] as Any]), NSDictionary(dictionary: [key: before[key] as Any]), key)
        }
        for key in ["interruptedByQuitAt", "armedWorkAtQuit", "lastAssistantUuid", "importedFrom"] { XCTAssertNil(after[key], key) }
        XCTAssertEqual(after["title"] as? String, "New title")
        XCTAssertTrue(try String(contentsOf: native(a), encoding: .utf8).contains("new"))
        for target in [a, b] { XCTAssertEqual(ClaudeChats.syncAll(to: target, spaces: [a, b], backups: backups).transferred, 0) }
    }

    func testUpdateKeepsDestinationLocalFieldsAndActivityNeverMovesBackwards() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 100, title: "Source title", lastFocused: 800)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 200, lastFocused: 900,
                            permissionMode: "plan", extra: ["model": "own", "effort": "high", "worktreePath": cwd,
                            "rewindEdges": ["edge"], "transcriptCuts": ["cut"], "transcriptModelStates": ["state"],
                            "interruptedByQuitAt": 42, "cutTurnUuid": "old", "pendingFirstStart": true])
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        let result = try record(b)
        XCTAssertEqual(result["lastActivityAt"] as? Double, 200)
        XCTAssertEqual(result["lastFocusedAt"] as? Double, 900)
        XCTAssertEqual(result["title"] as? String, "Source title")
        XCTAssertEqual(result["model"] as? String, "own")
        XCTAssertEqual(result["effort"] as? String, "high")
        XCTAssertEqual(result["permissionMode"] as? String, "plan")
        XCTAssertEqual(result["worktreePath"] as? String, cwd)
        XCTAssertNotNil(result["spawnSeed"])
        for key in ["rewindEdges", "transcriptCuts", "transcriptModelStates"] { XCTAssertNotNil(result[key]) }
        for key in ["interruptedByQuitAt", "cutTurnUuid", "pendingFirstStart"] { XCTAssertNil(result[key]) }
    }

    func testReplaceDivergedDropsTranscriptCoupledKeysAndWorktreeKeysWhenCwdChanges() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "source")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "target")], lastActivity: 100, extra: ["cwd": "/other",
            "originCwd": cwd, "worktreePath": "/other/tree", "worktreeName": "tree", "sessionPermissionUpdates": ["own": true],
            "rewindEdges": ["edge"], "transcriptCuts": ["cut"], "transcriptModelStates": ["state"]])
        let prepared = try transfer(to: b, spaces: [a, b])
        XCTAssertEqual(prepared.kind, .replaceDiverged)
        try ClaudeChats.apply(prepared, backups: backups)
        let result = try record(b)
        for key in ["worktreePath", "worktreeName", "sessionPermissionUpdates", "rewindEdges", "transcriptCuts", "transcriptModelStates"] { XCTAssertNil(result[key]) }
        XCTAssertEqual(result["originCwd"] as? String, cwd)
    }

    func testUntrustedResultKeepsImportedFrom() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200, trusted: false)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(try record(b)["importedFrom"] as? String, "local-1p-code")
        XCTAssertNotNil(try record(b)["stagedTranscriptPath"])
    }

    func testChangedTargetRecordIsRefusedForUpdate() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        let prepared = try transfer(to: b, spaces: [a, b])
        XCTAssertEqual(prepared.kind, .update)
        let raw = try Data(contentsOf: native(b))
        for change in ["cwd", "sessionId"] {
            let original = try Data(contentsOf: recordURL(b))
            try editRecord(b) { $0[change] = change == "cwd" ? "/changed" : "local_changed" }
            let changed = try Data(contentsOf: recordURL(b))
            XCTAssertThrowsError(try ClaudeChats.apply(prepared, backups: backups))
            XCTAssertEqual(try Data(contentsOf: recordURL(b)), changed)
            XCTAssertEqual(try Data(contentsOf: native(b)), raw)
            try original.write(to: recordURL(b))
        }
        XCTAssertTrue(try savedFiles().isEmpty)
    }

    func testMissingTitleIsNotWrittenAsPlaceholderAndUserRenameSurvivesUpdate() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, title: "")
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.scan([a])[0].title, "Untitled conversation")
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertNil(try record(b)["title"])
        for titleSource in ["user", "tool"] {
            try editRecord(b) { $0["title"] = "My name"; $0["titleSource"] = titleSource }
            try append(titleSource, to: native(a))
            try editRecord(a) { $0["title"] = "Automatic name"; $0["titleSource"] = "auto"; $0["lastActivityAt"] = 200 }
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
            XCTAssertEqual(try record(b)["title"] as? String, "My name")
            XCTAssertEqual(try record(b)["titleSource"] as? String, titleSource)
        }
    }

    func testUnparsedDestinationModeIsKept() throws {
        for mode in ["dontAsk", "bypassPermissions", "adopted"] {
            let a = space("A-\(mode)"), b = space("B-\(mode)")
            try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, extra: lineage)
            try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100, permissionMode: mode)
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
            XCTAssertEqual(try record(b)["permissionMode"] as? String, mode)
            try append("more", to: native(a))
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
            XCTAssertEqual(try record(b)["permissionMode"] as? String, mode)
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
        }
    }

    func testDontAskCarriesAndUntrustedDestinationLosesUnchosenBypass() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200, permissionMode: "dontAsk")
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100, trusted: false, permissionMode: "bypassPermissions", bypassChosen: true)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(try record(b)["permissionMode"] as? String, "dontAsk")
        XCTAssertNil(try record(b)["bypassChosenInApp"])
    }
}
