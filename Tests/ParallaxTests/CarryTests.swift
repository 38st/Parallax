import XCTest
@testable import Parallax

final class CarryTests: ChatFixture {
    func testCarryBackKeepsTheOriginalTranscriptsOwnLines() throws {
        let a = space("A"), b = space("B")
        let own = [#"{"type":"file-history-snapshot","snapshot":"own"}"#, #"{"type":"custom-title","title":"own"}"#,
                   #"{"type":"pr-link","url":"own"}"#]
        try writeNativeChat(in: a, lines: own + [line("user", "hi")], lastActivity: 100)
        let raw = try Data(contentsOf: native(a))
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        try append("more", to: native(b))
        XCTAssertEqual(ClaudeChats.syncAll(to: a, spaces: [a, b], backups: backups).transferred, 1)
        let after = try Data(contentsOf: native(a))
        XCTAssertTrue(ClaudeChats.hasPrefix(after, raw))
        XCTAssertTrue(String(decoding: after, as: UTF8.self).contains("more"))
        XCTAssertTrue(try savedFiles().allSatisfy { $0.pathExtension == "json" })
    }

    func testIdenticalNativeTranscriptIsNotRewrittenAndLongerNativeIsNeverShortened() throws {
        let a = space("A")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        for longer in [false, true] {
            let b = space("B-\(longer)")
            _ = try namespace(b)
            try FileManager.default.createDirectory(at: native(b).deletingLastPathComponent(), withIntermediateDirectories: true)
            let raw = Data(([line("user", "hi")] + (longer ? [line("user", "own")] : [])).joined(separator: "\n").appending("\n").utf8)
            try raw.write(to: native(b))
            let fixed = Date(timeIntervalSince1970: 123)
            try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: native(b).path)
            try ClaudeChats.apply(try transfer(to: b, spaces: [a, b]), backups: backups)
            XCTAssertEqual(try Data(contentsOf: native(b)), raw)
            XCTAssertEqual(try native(b).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, fixed)
            XCTAssertTrue(try savedFiles().isEmpty)
        }
    }

    func testPromotionOverIdenticalNativeWritesOnlyRecord() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, trusted: false)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        let staged = URL(fileURLWithPath: try XCTUnwrap(record(b)["stagedTranscriptPath"] as? String))
        let raw = try Data(contentsOf: staged)
        try FileManager.default.createDirectory(at: native(b).deletingLastPathComponent(), withIntermediateDirectories: true)
        try raw.write(to: native(b))
        let fixed = Date(timeIntervalSince1970: 123)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: native(b).path)
        try editRecord(a) { $0.removeValue(forKey: "importedFrom") }
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(try native(b).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, fixed)
        XCTAssertTrue(try savedFiles().allSatisfy { $0.pathExtension == "json" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    func testUnterminatedNativeTranscriptIsReplacedNotAppended() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        let raw = Data(line("user", "hi").utf8)
        try raw.write(to: native(b))
        let prepared = try transfer(to: b, spaces: [a, b])
        try ClaudeChats.apply(prepared, backups: backups)
        XCTAssertEqual(try Data(contentsOf: native(b)), prepared.transcript)
        XCTAssertTrue(try savedFiles().contains { (try? Data(contentsOf: $0)) == raw })
    }

    func testRewoundChatStillSyncsInBulkAndReportsBackupAsNote() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "rewound", sessionID: "rewound")], lastActivity: 200, cliSessionID: "rewound")
        try writeNativeChat(in: b, lines: [line("user", "old branch")], lastActivity: 100)
        let raw = try Data(contentsOf: native(b))
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(try XCTUnwrap(result.summary).contains(backups.path))
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("Fix the build"))
        XCTAssertEqual(try record(b)["priorCliSessionIds"] as? [String], [cli])
        XCTAssertEqual(try Data(contentsOf: native(b)), raw)
        XCTAssertTrue(try savedFiles().contains { (try? Data(contentsOf: $0)) == raw })
    }

    func testForkWithParentSessionLinesIsCarried() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "inherited", sessionID: "parent-cli"), line("user", "new")], lastActivity: 200)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        let output = try String(contentsOf: native(b), encoding: .utf8)
        XCTAssertTrue(output.contains("inherited")); XCTAssertTrue(output.contains("new")); XCTAssertFalse(output.contains("sessionId"))
    }

    func testForkIntoAnotherFolderBeforeItsFirstMessageIsCarried() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "inherited", sessionID: "parent-cli")], lastActivity: 200,
                            extra: ["cwd": "/work/fork", "originCwd": cwd, "worktreePath": "/work/fork"])
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(try record(b)["originCwd"] as? String, cwd)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testStagedPathOutsideImportedStagingIsIgnoredAndUsesClaudesFileName() throws {
        let a = space("A")
        try writeNativeChat(in: a, lines: [line("user", "native")], lastActivity: 100)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent(cli + ".jsonl")
        try Data("outside bytes never parsed".utf8).write(to: outsideFile)
        let staging = try namespace(a).appendingPathComponent("imported-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let link = staging.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let fifoFolder = staging.appendingPathComponent("fifo")
        try FileManager.default.createDirectory(at: fifoFolder, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fifoFolder.appendingPathComponent(cli + ".jsonl").path, 0o600), 0)
        for path in [outsideFile.path, link.appendingPathComponent(cli + ".jsonl").path, fifoFolder.appendingPathComponent(cli + ".jsonl").path, "relative/file"] {
            try editRecord(a) { $0["stagedTranscriptPath"] = path }
            let copy = try XCTUnwrap(ClaudeChats.scan([a]).first?.newest)
            XCTAssertEqual(try ClaudeChats.transcriptURL(for: copy, in: a)?.resolvingSymlinksInPath(), native(a).resolvingSymlinksInPath())
        }
        // Flat Claude staging, a digest directory, and a fork beside the recorded parent's file.
        for folder in [staging, staging.appendingPathComponent(cli + "-" + String(repeating: "a", count: 64)), staging.appendingPathComponent("parent-digest")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(cli + ".jsonl")
            let bytes = Data((line("user", "staged") + "\n").utf8)
            try bytes.write(to: file)
            try editRecord(a) { $0["stagedTranscriptPath"] = folder.appendingPathComponent("parent.jsonl").path }
            let copy = try XCTUnwrap(ClaudeChats.scan([a]).first?.newest)
            XCTAssertEqual(try ClaudeChats.transcriptURL(for: copy, in: a)?.path, file.path)
        }
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside bytes never parsed".utf8))
        XCTAssertTrue(try savedFiles().isEmpty)
    }

    func testDuplicateTranscriptsUseTheCopyThatHoldsTheOthers() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        let duplicate = a.config.appendingPathComponent("projects/other/" + cli + ".jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((line("user", "hi") + "\n" + line("user", "longer") + "\n").utf8).write(to: duplicate)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertTrue(try String(contentsOf: native(b), encoding: .utf8).contains("longer"))
        let before = try Data(contentsOf: duplicate)
        XCTAssertEqual(ClaudeChats.syncAll(to: a, spaces: [a, b], backups: backups).transferred, 0)
        XCTAssertEqual(try Data(contentsOf: duplicate), before)
        // An unreadable duplicate cannot hide a readable one.
        try Data("{bad".utf8).write(to: native(a))
        XCTAssertEqual(try ClaudeChats.transcriptURL(for: ClaudeChats.scan([a])[0].newest, in: a)?.path, duplicate.resolvingSymlinksInPath().path)
        try Data("{bad".utf8).write(to: duplicate)
        XCTAssertThrowsError(try ClaudeChats.transcriptURL(for: ClaudeChats.scan([a])[0].newest, in: a))
    }

    func testAmbiguousDestinationIsNotOverwrittenByOlderSource() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "old")], lastActivity: 100)
        try writeNativeChat(in: b, lines: [line("user", "one branch")], lastActivity: 200)
        let duplicate = b.config.appendingPathComponent("projects/other/" + cli + ".jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = Data((line("user", "another branch") + "\n").utf8)
        try raw.write(to: duplicate)
        for target in [a, b] {
            let result = ClaudeChats.syncAll(to: target, spaces: [a, b], backups: backups)
            XCTAssertEqual(result.transferred, 0)
            XCTAssertEqual(result.issues.count, 1)
            XCTAssertTrue(try XCTUnwrap(result.summary).contains("two different message files"))
        }
        XCTAssertEqual(try Data(contentsOf: duplicate), raw)
        XCTAssertTrue(try savedFiles().isEmpty)
    }

    func testUnreadableDuplicateDestinationIsNotTreatedAsOneDamagedFile() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 200)
        try writeNativeChat(in: b, lines: ["{bad"], lastActivity: 100)
        let duplicate = b.config.appendingPathComponent("projects/other/" + cli + ".jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{also bad".utf8).write(to: duplicate)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.transferred, 0); XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(try String(contentsOf: duplicate, encoding: .utf8), "{also bad")
        XCTAssertTrue(try savedFiles().isEmpty)
    }

    func testSymlinkedProjectsAndSessionsFoldersSettle() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b)
        for (index, original) in [a.config.appendingPathComponent("projects"), b.sessions].enumerated() {
            let moved = root.appendingPathComponent("resolved-\(index)")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        }
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
        XCTAssertTrue(try savedFiles().isEmpty)
    }

    func testPrimaryNamespaceFollowsLastKnownAccountUuid() throws {
        let a = space("A")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        let old = try namespace(a), new = try namespace(a, account: "acct-new")
        try Data("{}".utf8).write(to: new.appendingPathComponent("local_new.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: new.appendingPathComponent("local_new.json").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: recordURL(a).path)
        let config = a.sessions.deletingLastPathComponent().appendingPathComponent("config.json")
        func choose(_ id: String) throws { try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": id]).write(to: config) }
        XCTAssertEqual(try ClaudeChats.primaryNamespace(in: a).resolvingSymlinksInPath().path, old.resolvingSymlinksInPath().path)
        try choose("acct-new")
        XCTAssertEqual(try ClaudeChats.primaryNamespace(in: a).resolvingSymlinksInPath().path, new.resolvingSymlinksInPath().path)
        try choose("missing")
        XCTAssertThrowsError(try ClaudeChats.primaryNamespace(in: a))
        try choose("../invalid")
        XCTAssertEqual(try ClaudeChats.primaryNamespace(in: a).resolvingSymlinksInPath().path, old.resolvingSymlinksInPath().path)
        let b = space("B")
        let only = try namespace(b, account: "deployment")
        try Data(#"{"lastKnownAccountUuid":"unmatched"}"#.utf8).write(to: b.sessions.deletingLastPathComponent().appendingPathComponent("config.json"))
        XCTAssertEqual(try ClaudeChats.primaryNamespace(in: b).resolvingSymlinksInPath().path, only.resolvingSymlinksInPath().path)
    }

    func testExcludedRecordsAreNotReportedAndRoutineRunsStayHome() throws {
        let a = space("A"), b = space("B")
        let ns = try namespace(a)
        _ = try namespace(b)
        for (i, extra) in [["sshConfig": ["host": "x"]], ["wslConfig": ["distro": "x"]], ["cliSessionId": NSNull()], ["cliSessionId": ""]].enumerated() {
            var object: [String: Any] = ["sessionId": "local_\(i)", "cliSessionId": "\(i)", "cwd": cwd]
            object.merge(extra) { _, new in new }
            try JSONSerialization.data(withJSONObject: object).write(to: ns.appendingPathComponent("local_\(i).json"))
        }
        try Data(#"{"sessionId":"local_empty","cwd":"/work/project"}"#.utf8).write(to: ns.appendingPathComponent("local_empty.json"))
        XCTAssertNil(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).summary)
        try writeNativeChat(in: a, lines: [line("user", "routine")], lastActivity: 200, extra: ["scheduledTaskId": "routine"])
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
        try writeNativeChat(in: b, lines: [line("user", "stray")], lastActivity: 100)
        let before = try Data(contentsOf: recordURL(b))
        for target in [a, b] {
            let result = ClaudeChats.syncAll(to: target, spaces: [a, b], backups: backups)
            XCTAssertEqual(result.checked, 0); XCTAssertTrue(result.issues.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: recordURL(b)), before)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .replaceDiverged, "Explicit Continue Here still works")
    }

    func testSubagentSidecarsCopiedWithoutOverwritingOrFollowingLinks() throws {
        let a = space("A"), b = space("B"), c = space("C")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b); _ = try namespace(c)
        let folder = native(a).deletingLastPathComponent().appendingPathComponent(cli + "/subagents")
        let destination = native(b).deletingLastPathComponent().appendingPathComponent(cli + "/subagents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, bytes) in ["agent-one.jsonl": "{\"data\":1}\n", "agent-one.meta.json": "{\"toolUseId\":\"tool\"}",
                              "agent-existing.jsonl": "new\n", "agent-torn.jsonl": "unfinished", "other.jsonl": "other\n"] {
            try Data(bytes.utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data("keep\n".utf8).write(to: destination.appendingPathComponent("agent-existing.jsonl"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("agent-link.jsonl"), withDestinationURL: folder.appendingPathComponent("agent-one.jsonl"))
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        for name in ["agent-one.jsonl", "agent-one.meta.json"] {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), try Data(contentsOf: folder.appendingPathComponent(name)))
        }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("agent-existing.jsonl"), encoding: .utf8), "keep\n")
        for name in ["agent-link.jsonl", "agent-torn.jsonl", "other.jsonl"] { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path)) }
        try editRecord(a) { $0["importedFrom"] = "local-1p-code" }
        XCTAssertEqual(ClaudeChats.syncAll(to: c, spaces: [a, c], backups: backups).transferred, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.config.appendingPathComponent("projects").path))
    }
}
