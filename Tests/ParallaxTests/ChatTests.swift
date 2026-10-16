import XCTest
@testable import Parallax

final class ChatTests: ChatFixture {
    func testNormalizedTranscriptGoldenBytes() throws {
        let lines = [
            " \t\r", "",
            #"{"z":1,"type":"user","cwd":"/work/project","sessionId":"gold","message":{"content":"héllo / 世界"},"a":2}"# + "\r",
            #"{"type":"summary","summary":"without cwd"}"#,
            #"{"type":"file-history-snapshot","snapshot":{"files":[]}}"#,
            #"{"type":"assistant","cwd":"/work/project","sessionId":"gold","toolUseResult":{"agentId":"strip","content":"ok/yes"},"agentId":"keep"}"#,
            #"{"type":"user","cwd":"/work/project","sessionId":"gold","isSidechain":true,"message":{"content":"side"}}"#,
            #"{"type":"assistant","cwd":"/work/project","message":{"content":"lone \ud83d"}}"#,
            #"{"type":"assistant","cwd":"/work/project","message":{"content":"pair \ud83d\ude00"}}"#,
            #"{"type":"progress","cwd":"/elsewhere","n":1.25,"large":12345678901234567890,"zero":-0.0}"#,
            #"{"type":"progress","cwd":"/work/project","n":1e-7,"yes":true,"no":false,"nil":null}"#,
            #"{"type":"progress","cwd":"/work/project","nested":{"z":[],"a":{}}}"#,
            #"{"type":"summary","cwd":"/work/project","summary":"kept"}"#,
            "", "\t", "\r",
            #"{"type":"assistant","cwd":"/work/project","message":{"content":"last/no newline"}}"#,
        ]
        let actual = try ClaudeChats.normalizedTranscript(Data(lines.joined(separator: "\n").utf8), cwds: [cwd])
        // Captured from unmodified a2643ef before changing normalization.
        let expected = Data(base64Encoded: "eyJhIjoyLCJjd2QiOiJcL3dvcmtcL3Byb2plY3QiLCJtZXNzYWdlIjp7ImNvbnRlbnQiOiJow6lsbG8gXC8g5LiW55WMIn0sInR5cGUiOiJ1c2VyIiwieiI6MX0KeyJhZ2VudElkIjoia2VlcCIsImN3ZCI6Ilwvd29ya1wvcHJvamVjdCIsInRvb2xVc2VSZXN1bHQiOnsiY29udGVudCI6Im9rXC95ZXMifSwidHlwZSI6ImFzc2lzdGFudCJ9CnsiY3dkIjoiXC93b3JrXC9wcm9qZWN0IiwiaXNTaWRlY2hhaW4iOnRydWUsIm1lc3NhZ2UiOnsiY29udGVudCI6InNpZGUifSwidHlwZSI6InVzZXIifQp7ImN3ZCI6Ilwvd29ya1wvcHJvamVjdCIsIm1lc3NhZ2UiOnsiY29udGVudCI6ImxvbmUg77+9In0sInR5cGUiOiJhc3Npc3RhbnQifQp7ImN3ZCI6Ilwvd29ya1wvcHJvamVjdCIsIm1lc3NhZ2UiOnsiY29udGVudCI6InBhaXIg8J+YgCJ9LCJ0eXBlIjoiYXNzaXN0YW50In0KeyJjd2QiOiJcL2Vsc2V3aGVyZSIsImxhcmdlIjoxMjM0NTY3ODkwMTIzNDU2Nzg5MCwibiI6MS4yNSwidHlwZSI6InByb2dyZXNzIiwiemVybyI6LTB9CnsiY3dkIjoiXC93b3JrXC9wcm9qZWN0IiwibiI6OS45OTk5OTk5OTk5OTk5OTk1ZS0wOCwibmlsIjpudWxsLCJubyI6ZmFsc2UsInR5cGUiOiJwcm9ncmVzcyIsInllcyI6dHJ1ZX0KeyJjd2QiOiJcL3dvcmtcL3Byb2plY3QiLCJuZXN0ZWQiOnsiYSI6e30sInoiOltdfSwidHlwZSI6InByb2dyZXNzIn0KeyJjd2QiOiJcL3dvcmtcL3Byb2plY3QiLCJzdW1tYXJ5Ijoia2VwdCIsInR5cGUiOiJzdW1tYXJ5In0KeyJjd2QiOiJcL3dvcmtcL3Byb2plY3QiLCJtZXNzYWdlIjp7ImNvbnRlbnQiOiJsYXN0XC9ubyBuZXdsaW5lIn0sInR5cGUiOiJhc3Npc3RhbnQifQo=")!
        XCTAssertEqual(actual, expected)
    }

    func testContinuingAddsChatToOtherAccountWithoutPrivateFields() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello"), #"{"type":"summary"}"#], lastActivity: 1_700_000_001_000, trusted: false)
        _ = try namespace(b, account: "acct-b", org: "org-b")

        let chats = ClaudeChats.scan([a, b])
        XCTAssertEqual(chats.count, 1)
        let transfer = try ClaudeChats.prepare(chat: chats[0], target: b, spaces: [a, b])
        XCTAssertEqual(transfer.kind, .add)
        try ClaudeChats.apply(transfer, backups: root.appendingPathComponent("Backups"))

        let ns = b.sessions.appendingPathComponent("acct-b/org-b")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ns.appendingPathComponent(chatID + ".json"))) as? [String: Any])
        XCTAssertEqual(Set(record.keys), ["cliSessionId", "createdAt", "cwd", "importedFrom", "isArchived", "lastActivityAt", "originCwd", "sessionId", "stagedTranscriptPath", "title", "permissionMode"])
        XCTAssertEqual(record["sessionId"] as? String, chatID)
        let staged = try XCTUnwrap(record["stagedTranscriptPath"] as? String)
        XCTAssertTrue(URL(fileURLWithPath: staged).resolvingSymlinksInPath().path
            .hasPrefix(ns.appendingPathComponent("imported-staging").resolvingSymlinksInPath().path))
        XCTAssertEqual(URL(fileURLWithPath: staged).lastPathComponent, cli + ".jsonl")

        let transcript = try String(contentsOfFile: staged, encoding: .utf8)
        let lines = transcript.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "Metadata lines without a working directory are dropped")
        XCTAssertFalse(transcript.contains("sessionId"))
        XCTAssertFalse(transcript.contains("agent-1"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: staged)[.posixPermissions] as? Int, 0o600)

        let after = ClaudeChats.scan([a, b])
        XCTAssertEqual(after[0].copies.count, 2)
        XCTAssertEqual(try ClaudeChats.prepare(chat: after[0], target: b, spaces: [a, b]).kind, .upToDate)
    }

    func testOlderCopyIsUpdatedAndDivergedCopyIsBackedUp() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello")], lastActivity: 1_700_000_001_000)
        _ = try namespace(b)
        let backups = root.appendingPathComponent("Backups")
        try ClaudeChats.apply(try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b]), backups: backups)

        // A continues the chat.
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello"), line("user", "more")], lastActivity: 1_700_000_009_000)
        let update = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b])
        XCTAssertEqual(update.kind, .update)
        try ClaudeChats.apply(update, backups: backups)
        XCTAssertEqual(try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b]).kind, .upToDate)

        // Both continue separately; B's copy is replaced only after a backup.
        let bChat = ClaudeChats.scan([b])[0]
        let bTranscript = try XCTUnwrap(try ClaudeChats.transcriptURL(for: bChat.newest, in: b))
        try Data((try String(contentsOf: bTranscript, encoding: .utf8) + line("user", "only in b") + "\n").utf8).write(to: bTranscript)
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello"), line("user", "more"), line("user", "only in a")],
                            lastActivity: 1_700_000_099_000)
        let diverged = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b])
        XCTAssertEqual(diverged.kind, .replaceDiverged)
        try ClaudeChats.apply(diverged, backups: backups)
        let saved = try FileManager.default.subpathsOfDirectory(atPath: backups.path)
        XCTAssertTrue(saved.contains { $0.hasSuffix(cli + ".jsonl") })
        XCTAssertTrue(saved.contains { $0.hasSuffix(chatID + ".json") })
    }

    func testPrimaryNamespaceIgnoresSchedulingOnlyFolders() throws {
        let b = space("B")
        let scheduling = try namespace(b, account: "old", org: "org")
        try Data("{}".utf8).write(to: scheduling.appendingPathComponent("scheduled-tasks.json"))
        let active = try namespace(b, account: "current", org: "org")
        try Data(#"{"sessionId":"local_x","cliSessionId":"x","cwd":"/w","isArchived":false}"#.utf8)
            .write(to: active.appendingPathComponent("local_x.json"))
        XCTAssertEqual(try ClaudeChats.primaryNamespace(in: b).resolvingSymlinksInPath().path, active.resolvingSymlinksInPath().path)

        let empty = space("C")
        _ = try namespace(empty, account: "one", org: "org")
        _ = try namespace(empty, account: "two", org: "org")
        XCTAssertThrowsError(try ClaudeChats.primaryNamespace(in: empty))
    }

    func testDeletedArchivedAndRemoteChatsAreHidden() throws {
        let a = space("A")
        let ns = try namespace(a)
        func write(_ id: String, _ extra: [String: Any] = [:]) throws {
            var record: [String: Any] = ["sessionId": id, "cliSessionId": UUID().uuidString, "cwd": "/w", "lastActivityAt": 1.0]
            record.merge(extra) { _, new in new }
            try JSONSerialization.data(withJSONObject: record).write(to: ns.appendingPathComponent(id + ".json"))
        }
        try write("local_keep")
        try write("local_gone")
        try Data().write(to: ns.appendingPathComponent("deleted_gone"))
        try write("local_archived", ["isArchived": true])
        try write("local_remote", ["sshConfig": ["host": "x"]])
        XCTAssertEqual(ClaudeChats.scan([a]).map(\.id), ["local_keep"])
    }

    func testInheritedSessionLinesAreStripped() throws {
        let data = Data((line("user", "hi") + "\n" + line("user", "x", sessionID: "someone-else") + "\n").utf8)
        XCTAssertFalse(String(decoding: try ClaudeChats.normalizedTranscript(data, cwds: [cwd]), as: UTF8.self).contains("sessionId"))
    }

    func testMalformedMessagesAreNotSilentlyDropped() throws {
        for invalid in ["{broken", #"{"type":"user","message":{"content":"lost"}}"#] {
            let data = Data((line("user", "hi") + "\n" + invalid + "\n").utf8)
            XCTAssertThrowsError(try ClaudeChats.normalizedTranscript(data, cwds: [cwd]))
        }
    }

    func testRecordIdentifiersCannotEscapeTheirFolders() throws {
        for key in ["sessionId", "cliSessionId"] {
            for value in ["local_x/../../outside", "..", "", "local_x\0bad"] {
                var record = ["sessionId": chatID, "cliSessionId": cli, "cwd": cwd]
                record[key] = value
                let data = try JSONSerialization.data(withJSONObject: record)
                XCTAssertNil(ClaudeChats.parseRecord(data, namespace: root, spaceID: UUID()))
            }
        }
    }

    func testHiddenTargetRecordsAndTombstonesAreNotOverwritten() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        let ns = try namespace(b)
        let record = ns.appendingPathComponent(chatID + ".json")
        try Data("{broken".utf8).write(to: record)
        XCTAssertThrowsError(try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b]))
        XCTAssertEqual(try Data(contentsOf: record), Data("{broken".utf8))
        try FileManager.default.removeItem(at: record)
        try Data().write(to: ns.appendingPathComponent("deleted_" + chatID.dropFirst(6)))
        XCTAssertThrowsError(try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b]))
    }

    func testAddDoesNotOverwriteARecordCreatedAfterPreparation() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        let ns = try namespace(b)
        let transfer = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b])
        let record = ns.appendingPathComponent(chatID + ".json")
        let data = Data("new target record".utf8)
        try data.write(to: record)
        XCTAssertThrowsError(try ClaudeChats.apply(transfer, backups: root.appendingPathComponent("Backups")))
        XCTAssertEqual(try Data(contentsOf: record), data)
    }

    func testCustomUserDataFolderIsScanned() throws {
        let custom = root.appendingPathComponent("custom data")
        let space = Space(name: "Custom", folder: root.appendingPathComponent("space").path,
                          arguments: LaunchText.join(["--user-data-dir", custom.path]))
        let folders = ClaudeChats.folders(for: space)
        XCTAssertEqual(folders.sessions.path, custom.appendingPathComponent("claude-code-sessions").path)
        try writeNativeChat(in: folders, lines: [line("user", "hi")], lastActivity: 100)
        XCTAssertEqual(ClaudeChats.scan([folders]).map(\.id), [chatID])
    }

    func testContinueURL() {
        XCTAssertEqual(ClaudeChats.continueURL(chatID: chatID)?.absoluteString, "claude://code/continue?session=\(chatID)")
    }

    func testBulkCarryoverCombinesBothAccountsAndRepeatsIncrementally() throws {
        let a = space("A")
        let b = space("B")
        let backups = root.appendingPathComponent("Backups")
        try writeNativeChat(in: a, lines: [line("user", "first")], lastActivity: 100)
        try writeNativeChat(in: a, lines: [line("user", "second", sessionID: "second")], lastActivity: 200,
                            chatID: "local_second", cliSessionID: "second")
        try writeNativeChat(in: b, lines: [line("user", "third", sessionID: "third")], lastActivity: 300,
                            chatID: "local_third", cliSessionID: "third")

        let toB = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(toB.transferred, 2)
        XCTAssertNil(toB.summary)
        let toA = ClaudeChats.syncAll(to: a, spaces: [a, b], backups: backups)
        XCTAssertEqual(toA.transferred, 1)
        XCTAssertNil(toA.summary)
        XCTAssertEqual(ClaudeChats.scan([a]).count, 3)
        XCTAssertEqual(ClaudeChats.scan([b]).count, 3)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path), "Unchanged chats need no backups or writes")

        try writeNativeChat(in: a, lines: [line("user", "first"), line("assistant", "continued")], lastActivity: 400)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testThirdAccountKeepsRecentChatOrderFromBothAccounts() throws {
        let a = space("A")
        let b = space("B")
        let c = space("Third account")
        _ = try namespace(c)
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, lastFocused: 500)
        try writeNativeChat(in: b, lines: [line("user", "hi"), line("assistant", "new")],
                            lastActivity: 200, lastFocused: 300)
        try writeNativeChat(in: b, lines: [line("user", "second", sessionID: "second")], lastActivity: 400,
                            chatID: "local_second", cliSessionID: "second")

        let result = ClaudeChats.syncAll(to: c, spaces: [a, b, c], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 2)
        XCTAssertNil(result.summary)
        let chats = ClaudeChats.scan([c])
        XCTAssertEqual(chats.map(\.id), [chatID, "local_second"], "Opening an older chat brings it above a newer message")
        XCTAssertEqual(chats[0].newest.lastActivityAt, 200, "Message selection still follows transcript freshness")
        XCTAssertEqual(chats[0].newest.lastFocusedAt, 500, "Recency comes from any of the three accounts")
        let transcript = try XCTUnwrap(try ClaudeChats.transcriptURL(for: chats[0].newest, in: c))
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("new"))
    }

    func testFocusOnlyDifferencesWriteNothing() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 200, lastFocused: 500)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        let before = try Data(contentsOf: recordURL(b))
        let prepared = try transfer(to: b, spaces: [a, b])
        XCTAssertEqual(prepared.kind, .upToDate)
        try ClaudeChats.apply(prepared, backups: backups)
        XCTAssertEqual(try Data(contentsOf: recordURL(b)), before)
        XCTAssertTrue(try savedFiles().isEmpty)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testNewMessagesKeepTargetsMoreRecentLastOpenedTime() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "new")],
                            lastActivity: 200, lastFocused: 300)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100, lastFocused: 900)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 1)
        XCTAssertNil(result.summary)
        XCTAssertEqual(ClaudeChats.scan([b])[0].newest.lastFocusedAt, 900)
        XCTAssertEqual(ClaudeChats.scan([b])[0].newest.lastActivityAt, 200)
    }

    func testAcceptedTrustAndBypassFollowNewCopiesAndMessageUpdates() throws {
        let a = space("A")
        let b = space("B")
        _ = try namespace(b)
        let backups = root.appendingPathComponent("Backups")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100,
                            permissionMode: "bypassPermissions", bypassChosen: true)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        let recordURL = try namespace(b).appendingPathComponent(chatID + ".json")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        XCTAssertEqual(record["resumeConfirmed"] as? Bool, true)
        XCTAssertEqual(record["permissionMode"] as? String, "bypassPermissions")
        XCTAssertEqual(record["bypassChosenInApp"] as? Bool, true)
        XCTAssertNil(record["spawnSeed"])
        XCTAssertNil(record["stagedTranscriptPath"])
        let native = b.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
        XCTAssertEqual(try Data(contentsOf: native), try ClaudeChats.normalizedTranscript(Data((line("user", "hi") + "\n").utf8), cwds: [cwd]))

        // Updating this approved chat must keep it resumable without another import prompt.
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "new")], lastActivity: 200,
                            permissionMode: "bypassPermissions", bypassChosen: true)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.transferred, 1)
        XCTAssertNil(result.summary)
        let updated = ClaudeChats.scan([b])[0].newest
        XCTAssertTrue(updated.approvals.trusted)
        XCTAssertTrue(updated.approvals.bypassChosenInApp)
        XCTAssertNil(updated.stagedTranscriptPath)
        XCTAssertTrue(try String(contentsOf: native, encoding: .utf8).contains("new"))
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testApprovalRepairPromotesStagingAndBacksUpNativeCollision() throws {
        let a = space("A")
        let b = space("B")
        _ = try namespace(b)
        let backups = root.appendingPathComponent("Backups")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, trusted: false)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        let original = ClaudeChats.scan([b])[0].newest
        let staged = try XCTUnwrap(original.stagedTranscriptPath)
        let native = b.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nativeBranch = Data((line("user", "different native branch") + "\n").utf8)
        try nativeBranch.write(to: native)
        // Trust must catch up even if the unconfirmed destination has newer activity metadata.
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 50,
                            permissionMode: "bypassPermissions", bypassChosen: true)

        let transfer = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b])
        XCTAssertEqual(transfer.kind, .updateMetadata)
        XCTAssertTrue(transfer.promoteTranscript)
        try ClaudeChats.apply(transfer, backups: backups)
        let updated = ClaudeChats.scan([b])[0].newest
        XCTAssertTrue(updated.approvals.trusted)
        XCTAssertTrue(updated.approvals.bypassChosenInApp)
        XCTAssertNil(updated.stagedTranscriptPath)
        XCTAssertEqual(try Data(contentsOf: native), try Data(contentsOf: URL(fileURLWithPath: staged)))
        XCTAssertEqual(updated.lastActivityAt, 100)
        let third = space("Third")
        _ = try namespace(third)
        XCTAssertEqual(ClaudeChats.syncAll(to: third, spaces: [a, b, third], backups: backups).transferred, 1)
        XCTAssertEqual(ClaudeChats.scan([third])[0].newest.lastActivityAt, 100)
        XCTAssertTrue(ClaudeChats.scan([third])[0].newest.approvals.bypassChosenInApp)
        let saved = try FileManager.default.subpathsOfDirectory(atPath: backups.path)
        let nativeBackup = try XCTUnwrap(saved.first { (try? Data(contentsOf: backups.appendingPathComponent($0))) == nativeBranch })
        XCTAssertEqual(try Data(contentsOf: backups.appendingPathComponent(nativeBackup)), nativeBranch)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testDestinationModeOnlyAppliesToSameProject() throws {
        let a = space("A")
        let b = space("B")
        let c = space("Different project")
        let backups = root.appendingPathComponent("Backups")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "new")], lastActivity: 200, permissionMode: "default")
        for destination in [b, c] {
            try writeNativeChat(in: destination, lines: [line("user", "hi")], lastActivity: 100,
                                permissionMode: "bypassPermissions", bypassChosen: true)
        }
        let differentRecord = try namespace(c).appendingPathComponent(chatID + ".json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: differentRecord)) as? [String: Any])
        record["cwd"] = "/other/project"
        try JSONSerialization.data(withJSONObject: record).write(to: differentRecord)
        let differentTranscript = c.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line("user", "hi").utf8)) as? [String: Any])
        entry["cwd"] = "/other/project"
        var transcript = try JSONSerialization.data(withJSONObject: entry)
        transcript.append(0x0A)
        try transcript.write(to: differentTranscript)

        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(ClaudeChats.scan([b])[0].newest.approvals.permissionMode, "bypassPermissions")
        try ClaudeChats.apply(try transfer(to: c, spaces: [a, c]), backups: backups)
        XCTAssertEqual(ClaudeChats.scan([c])[0].newest.approvals.permissionMode, "default")
        XCTAssertFalse(ClaudeChats.scan([c])[0].newest.approvals.bypassChosenInApp)
    }

    func testUnconfirmedImportsAndUnprovenModesDoNotGrantBypass() throws {
        let a = space("A")
        let b = space("B")
        _ = try namespace(b)
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100,
                            trusted: false, permissionMode: "bypassPermissions", bypassChosen: true)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 1)
        let imported = ClaudeChats.scan([b])[0].newest
        XCTAssertFalse(imported.approvals.trusted)
        XCTAssertNil(imported.approvals.permissionMode)
        XCTAssertFalse(imported.approvals.bypassChosenInApp)
        XCTAssertNotNil(imported.stagedTranscriptPath)

        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, permissionMode: "bypassPermissions")
        XCTAssertNil(ClaudeChats.scan([a])[0].newest.approvals.permissionMode)
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, permissionMode: "unknown-mode")
        XCTAssertNil(ClaudeChats.scan([a])[0].newest.approvals.permissionMode)
    }

    func testApprovalRepairRefusesAProjectChangedAfterPreparation() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 200,
                            permissionMode: "bypassPermissions", bypassChosen: true)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100, trusted: false)
        let transfer = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b])
        XCTAssertEqual(transfer.kind, .updateMetadata)
        let recordURL = try namespace(b).appendingPathComponent(chatID + ".json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        record["cwd"] = "/other/project"
        let changed = try JSONSerialization.data(withJSONObject: record)
        try changed.write(to: recordURL)
        XCTAssertThrowsError(try ClaudeChats.apply(transfer, backups: root.appendingPathComponent("Backups")))
        XCTAssertEqual(try Data(contentsOf: recordURL), changed)
    }

    func testNativeTranscriptPathEncodingAndSymlinkBoundary() throws {
        let config = root.appendingPathComponent("Config")
        let unicode = try ClaudeChats.nativeTranscriptURL(config: config, cwd: "/work/cafe\u{301}/😀", cliSessionID: cli)
        XCTAssertEqual(unicode.deletingLastPathComponent().lastPathComponent, "-work-caf----")
        XCTAssertThrowsError(try ClaudeChats.nativeTranscriptURL(config: config, cwd: "/" + String(repeating: "x", count: 201), cliSessionID: cli))
        XCTAssertThrowsError(try ClaudeChats.nativeTranscriptURL(config: config, cwd: cwd, cliSessionID: "../escape"))
        let projects = config.appendingPathComponent("projects")
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("-work-project"), withDestinationURL: outside)
        XCTAssertThrowsError(try ClaudeChats.nativeTranscriptURL(config: config, cwd: cwd, cliSessionID: cli))
    }

    func testBulkCarryoverFindsNativeContinuationBehindStaleStagingAndEqualTimestamps() throws {
        let a = space("A")
        let b = space("B")
        let backups = root.appendingPathComponent("Backups")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, trusted: false)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)

        // Claude keeps the imported record and staged path while its native transcript grows.
        // The record's timestamp and staged file can both lag behind this continuation.
        let native = b.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((line("user", "hi") + "\n" + line("assistant", "new in B") + "\n").utf8).write(to: native)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: native.path)

        let copy = try XCTUnwrap(ClaudeChats.scan([b]).first?.newest)
        XCTAssertEqual(try ClaudeChats.transcriptURL(for: copy, in: b)?.resolvingSymlinksInPath(), native.resolvingSymlinksInPath())
        let result = ClaudeChats.syncAll(to: a, spaces: [b, a], backups: backups)
        XCTAssertEqual(result.transferred, 1, "An equal timestamp cannot hide a longer copy in the other account")
        XCTAssertNil(result.summary)
        let updated = try XCTUnwrap(ClaudeChats.scan([a]).first?.newest)
        let transcript = try XCTUnwrap(try ClaudeChats.transcriptURL(for: updated, in: a))
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("new in B"))
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testPendingStagedImportStillWinsOverShorterNativeTranscript() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "more")], lastActivity: 200, trusted: false)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups")).transferred, 1)
        let updated = try XCTUnwrap(ClaudeChats.scan([b]).first?.newest)
        let transcript = try XCTUnwrap(try ClaudeChats.transcriptURL(for: updated, in: b))
        XCTAssertEqual(transcript.path, updated.stagedTranscriptPath)
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("more"))

        // Native metadata or divergent content doesn't prove a pending import was consumed.
        let native = b.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
        try Data((line("user", "different native branch") + "\n").utf8).write(to: native)
        XCTAssertEqual(try ClaudeChats.transcriptURL(for: updated, in: b)?.path, updated.stagedTranscriptPath)
    }

    func testLongerTranscriptWinsDespiteOlderActivityMetadata() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "hi"), line("assistant", "continued")], lastActivity: 100)
        let result = ClaudeChats.syncAll(to: a, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 1)
        XCTAssertNil(result.summary)
        let copy = try XCTUnwrap(ClaudeChats.scan([a]).first?.newest)
        let transcript = try XCTUnwrap(try ClaudeChats.transcriptURL(for: copy, in: a))
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("continued"))
    }

    func testEqualTimeDamagedTargetTranscriptIsBackedUpAndRepaired() throws {
        let a = space("A")
        try writeNativeChat(in: a, lines: [line("user", "healthy")], lastActivity: 100)
        for damage in ["missing", "corrupt"] {
            let b = space("B-" + damage)
            let backups = root.appendingPathComponent("Backups-" + damage)
            try writeNativeChat(in: b, lines: [line("user", "old")], lastActivity: 100)
            let native = b.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
            if damage == "missing" {
                try FileManager.default.removeItem(at: native)
            } else {
                try Data("{broken".utf8).write(to: native)
            }
            let result = ClaudeChats.syncAll(to: b, spaces: [b, a], backups: backups)
            XCTAssertEqual(result.transferred, 1)
            XCTAssertNil(result.summary)
            let saved = try FileManager.default.subpathsOfDirectory(atPath: backups.path)
            XCTAssertTrue(saved.contains { $0.hasSuffix(chatID + ".json") })
            if damage == "corrupt" {
                let path = try XCTUnwrap(saved.first { $0.hasSuffix(cli + ".jsonl") })
                XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent(path), encoding: .utf8), "{broken")
            }
        }
    }

    func testChatContinuedInBothAccountsIsLeftForContinueHere() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "only in A")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "hi"), line("assistant", "only in B")], lastActivity: 100)
        let original = try Data(contentsOf: native(b)), source = try Data(contentsOf: native(a))
        var cache = ChatSyncCache()
        for _ in 0..<2 {
            let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
            XCTAssertEqual(result.transferred, 0)
            XCTAssertEqual(result.issues.count, 1)
            XCTAssertTrue(result.notes.isEmpty)
            XCTAssertTrue(try XCTUnwrap(result.summary).contains("Continue Here"))
            XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 0)
            XCTAssertEqual(try Data(contentsOf: native(b)), original)
        }
        XCTAssertTrue(try savedFiles().isEmpty)
        try ClaudeChats.apply(try transfer(to: b, spaces: [a, b]), backups: backups)
        XCTAssertTrue(try savedFiles().contains { (try? Data(contentsOf: $0)) == original })
        XCTAssertEqual(try Data(contentsOf: native(a)), source)
    }

    func testBulkCarryoverContinuesAfterMissingAndCorruptTranscripts() throws {
        let a = space("A")
        let b = space("B")
        _ = try namespace(b)
        try writeNativeChat(in: a, lines: [line("user", "good")], lastActivity: 100)
        try writeNativeChat(in: a, lines: ["{broken"], lastActivity: 300,
                            chatID: "local_corrupt", cliSessionID: "corrupt", title: "Corrupt chat")
        try writeNativeChat(in: a, lines: [], lastActivity: 200,
                            chatID: "local_missing", cliSessionID: "missing", title: "Missing chat")
        try FileManager.default.removeItem(at: a.config.appendingPathComponent("projects/-work-project/missing.jsonl"))

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("Corrupt chat"))
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("Missing chat"))
        XCTAssertEqual(ClaudeChats.scan([b]).map(\.id), [chatID])
    }

    func testBulkCarryoverRespectsTargetArchivesAndDeletions() throws {
        let a = space("A")
        let b = space("B")
        let ns = try namespace(b)
        try writeNativeChat(in: a, lines: [line("user", "archived")], lastActivity: 100)
        try writeNativeChat(in: a, lines: [line("user", "deleted", sessionID: "deleted")], lastActivity: 200,
                            chatID: "local_deleted", cliSessionID: "deleted")
        let archived = try JSONSerialization.data(withJSONObject: ["sessionId": chatID, "cliSessionId": cli, "cwd": cwd, "isArchived": true])
        try archived.write(to: ns.appendingPathComponent(chatID + ".json"))
        try Data().write(to: ns.appendingPathComponent("deleted_deleted"))

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 0)
        XCTAssertNil(result.summary)
        XCTAssertEqual(try Data(contentsOf: ns.appendingPathComponent(chatID + ".json")), archived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ns.appendingPathComponent("local_deleted.json").path))
    }

    func testMissingDestinationNamespaceReportsOnceForAllChats() throws {
        let a = space("A")
        let b = space("New account")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        try writeNativeChat(in: a, lines: [line("user", "two", sessionID: "two")], lastActivity: 100,
                            chatID: "local_two", cliSessionID: "two")
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 0)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("Open Claude Code once in New account"))
    }

    func testUnsupportedSourceAndUnreadableTargetRecordsAreReported() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        let sourceNamespace = try namespace(a)
        try Data("{broken".utf8).write(to: sourceNamespace.appendingPathComponent("local_broken.json"))
        let targetRecord = try namespace(b).appendingPathComponent(chatID + ".json")
        let original = Data("{unreadable".utf8)
        try original.write(to: targetRecord)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 0)
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("unsupported format"))
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("destination"))
        XCTAssertEqual(try Data(contentsOf: targetRecord), original)
    }

    func testBulkCarryoverKeepsOneDestinationNamespaceForTheWholeBatch() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "shared"), line("assistant", "new")], lastActivity: 500)
        try writeNativeChat(in: a, lines: [line("user", "second", sessionID: "second")], lastActivity: 400,
                            chatID: "local_second", cliSessionID: "second")
        try writeNativeChat(in: b, lines: [line("user", "shared")], lastActivity: 100)
        try writeNativeChat(in: b, lines: [line("user", "current", sessionID: "current")], lastActivity: 100,
                            chatID: "local_current", cliSessionID: "current")
        let old = try namespace(b)
        let current = try namespace(b, account: "current")
        let anchor = current.appendingPathComponent("local_current.json")
        try FileManager.default.moveItem(at: old.appendingPathComponent("local_current.json"), to: anchor)
        let oldRecord = old.appendingPathComponent(chatID + ".json")
        let oldData = try Data(contentsOf: oldRecord)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldRecord.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: anchor.path)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 2)
        XCTAssertNil(result.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent(chatID + ".json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("local_second.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("local_second.json").path))
        XCTAssertEqual(try Data(contentsOf: oldRecord), oldData)
    }
}
