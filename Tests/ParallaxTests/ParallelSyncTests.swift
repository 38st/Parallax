import CryptoKit
import Darwin
import XCTest
@testable import Parallax

final class ParallelSyncTests: ChatFixture {
    private func spaces(at root: URL) throws -> [ClaudeChats.SpaceFolders] {
        try ["A", "B", "C"].enumerated().map { index, name in
            let id = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index + 1)")!
            let space = ClaudeChats.folders(for: Space(id: id, name: name, folder: root.appendingPathComponent(name).path))
            _ = try namespace(space)
            return space
        }
    }

    private func write(_ space: ClaudeChats.SpaceFolders, _ id: String, _ messages: [String],
                       activity: Double = 100, cli: String? = nil, cwd: String? = nil,
                       trusted: Bool = true, extra: [String: Any] = [:]) throws {
        let cli = cli ?? id
        let directory = cwd ?? self.cwd
        let lines = try messages.map { message in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line("user", message).utf8)) as? [String: Any])
            object["cwd"] = directory
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        var fields = extra
        fields["cwd"] = directory
        try writeNativeChat(in: space, lines: lines, lastActivity: activity, chatID: "local_" + id,
                            cliSessionID: cli, title: id, trusted: trusted, extra: fields)
        try editRecord(space, id: "local_" + id) { _ in } // Stable JSON bytes in both trees.
        if directory != self.cwd {
            let destination = try ClaudeChats.nativeTranscriptURL(config: space.config, cwd: directory, cliSessionID: cli)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: native(space, cli: cli)).write(to: destination)
            try FileManager.default.removeItem(at: native(space, cli: cli))
        }
    }

    private func stage(_ space: ClaudeChats.SpaceFolders, _ id: String, cli: String, cwd: String) throws {
        let native = try ClaudeChats.nativeTranscriptURL(config: space.config, cwd: cwd, cliSessionID: cli)
        let staged = try namespace(space).appendingPathComponent("imported-staging/seed-\(id)/\(cli).jsonl")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: native, to: staged)
        try editRecord(space, id: "local_" + id) {
            $0["importedFrom"] = "local-1p-code"
            $0["stagedTranscriptPath"] = staged.path
        }
    }

    private func scenario(at root: URL) throws -> [ClaudeChats.SpaceFolders] {
        let spaces = try spaces(at: root)
        let a = spaces[0], b = spaces[1], c = spaces[2]
        for i in 0..<72 {
            let id = String(format: "chat%02d", i)
            let messages = i % 6 == 1 ? [id, "more"] : [id]
            try write(a, id, messages, activity: Double(1_000 + i))
            switch i % 6 {
            case 1: try write(b, id, [id])
            case 2:
                try write(b, id, messages)
                try write(c, id, messages)
            case 3: try write(b, id, messages, trusted: false)
            case 4:
                try write(b, id, messages, extra: ["lastFocusedAt": 5_000 + i, "permissionMode": "plan"])
            case 5:
                try editRecord(a, id: "local_" + id) { $0["importedFrom"] = "local-1p-code" }
                try stage(a, id, cli: id, cwd: cwd)
            default: break
            }
        }
        try write(a, "own", ["common", "A branch"], activity: 8_000)
        try write(b, "own", ["common", "B branch"])
        try write(a, "replace", ["new branch"], activity: 8_001)
        try write(b, "replace", ["old branch"], cli: "old-cli")
        try write(a, "broken", ["placeholder"], activity: 8_002)
        try Data("{broken\n".utf8).write(to: native(a, cli: "broken"))
        try write(a, "deleted", ["deleted"])
        try Data().write(to: namespace(b).appendingPathComponent("deleted_deleted"))
        try write(a, "archived", ["archived"])
        try write(b, "archived", ["archived"], extra: ["isArchived": true])
        try write(a, "conflict", ["first"], activity: 8_003)
        let duplicate = a.config.appendingPathComponent("projects/duplicate/conflict.jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((line("user", "second") + "\n").utf8).write(to: duplicate)
        try write(a, "lineage", ["fork"], extra: ["forkedFromSessionId": "local_chat00", "forkedAtMessageUuid": "uuid-chat00"])
        try write(b, "lineage", ["fork"])
        try write(a, "newcwd", ["new folder"], cwd: "/work/new-project")

        // P changes the native input that Q prepared earlier in the same batch.
        try write(a, "P", ["shared", "continued"], activity: 100_000, cli: "shared")
        try write(a, "Q", ["shared", "continued"], activity: 99_999, cli: "shared")
        try write(b, "Q", ["shared"], cli: "shared")
        for (id, activity) in [("Pnew", 99_998.0), ("Qnew", 99_997.0)] {
            try write(a, id, ["shared new", "continued"], activity: activity, cli: "shared-new", cwd: "/work/shared-new")
        }
        try write(c, "Qnew", ["shared new"], cli: "shared-new", cwd: "/work/shared-new",
                  extra: ["resumeConfirmed": true])
        try stage(c, "Qnew", cli: "shared-new", cwd: "/work/shared-new")
        try FileManager.default.removeItem(at: c.config.appendingPathComponent("projects/-work-shared-new"))
        XCTAssertEqual(Array(ClaudeChats.scan(spaces).prefix(4).map(\.id)), ["local_P", "local_Q", "local_Pnew", "local_Qnew"])
        return spaces
    }

    private func relative(_ text: String, to root: URL) -> String {
        var text = text
        let paths = [root.path, root.resolvingSymlinksInPath().path].flatMap { [$0, "/private" + $0] }
        for path in Set(paths).sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: path.replacingOccurrences(of: "/", with: "\\/"), with: "<root>")
                .replacingOccurrences(of: path, with: "<root>")
        }
        return text
    }

    private func observed(_ transfer: ChatTransfer, root: URL) -> [String: String] {
        var values = [
            "chatID": transfer.chatID, "kind": String(describing: transfer.kind),
            "sourceSpace": transfer.source.spaceID.uuidString, "sourceSession": transfer.source.sessionID,
            "sourceCLI": transfer.source.cliSessionID,
            "transcript": SHA256.hash(data: transfer.transcript).map { String(format: "%02x", $0) }.joined(),
            "approvals": String(describing: transfer.approvals), "promote": String(transfer.promoteTranscript),
            "lineagePresent": String(transfer.lineage.present), "own": String(transfer.targetHasOwnMessages),
            "extends": String(transfer.extendsTarget),
        ]
        values["targetRecord"] = transfer.targetRecord.map { relative($0.path, to: root) }
        values["targetTranscript"] = transfer.targetTranscript.map { relative($0.path, to: root) }
        values["sourceTranscript"] = transfer.sourceTranscript.map { relative($0.path, to: root) }
        values["targetCwd"] = transfer.targetCwd
        values["focused"] = transfer.lastFocusedAt.map { String($0) }
        values["lineage"] = transfer.lineage.json?.base64EncodedString()
        return values
    }

    private func files(at root: URL) throws -> (files: [String: Data], backups: [String]) {
        var files: [String: Data] = [:]
        var backups: [String] = []
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(path)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = Data(relative(String(decoding: try Data(contentsOf: url), as: UTF8.self), to: root).utf8)
            if path.hasPrefix("Backups/") {
                let folder = url.deletingLastPathComponent().lastPathComponent
                let start = try XCTUnwrap(folder.range(of: "-local_")).upperBound
                let id = "local_" + folder[start...].dropLast(9)
                backups.append(id + "/" + url.lastPathComponent + ":" + data.base64EncodedString())
            } else { files[path] = data }
        }
        return (files, backups.sorted())
    }

    private func compareTrees(_ serial: URL, _ parallel: URL) throws {
        let a = try files(at: serial), b = try files(at: parallel)
        XCTAssertEqual(Set(a.files.keys), Set(b.files.keys))
        for path in a.files.keys.sorted() { XCTAssertEqual(a.files[path], b.files[path], path) }
        XCTAssertEqual(a.backups, b.backups)
    }

    func testParallelSyncMatchesSequential() throws {
        let serial = root.appendingPathComponent("serial"), parallel = root.appendingPathComponent("parallel")
        let trees = [try scenario(at: serial), try scenario(at: parallel)]
        let roots = [serial, parallel]
        var caches = [ChatSyncCache(), ChatSyncCache()]
        var sharedReads = [0, 0]
        for round in 0..<3 {
            if round == 1 {
                for spaces in trees {
                    for id in ["chat00", "chat01", "chat02"] { try append("appended", to: native(spaces[0], cli: id)) }
                    try editRecord(spaces[1], id: "local_chat04") { $0["lastFocusedAt"] = 9_000 }
                    try Data().write(to: namespace(spaces[2]).appendingPathComponent("deleted_chat06"))
                }
            }
            if round == 2 { caches = [ChatSyncCache(), ChatSyncCache()] }
            for target in 0..<3 {
                var results: [ClaudeChats.SyncResult] = []
                var observations: [[[String: String]]] = []
                for mode in 0..<2 {
                    let spaces = trees[mode], tree = roots[mode]
                    let shared = native(spaces[1], cli: "shared").resolvingSymlinksInPath()
                    let caller = Thread.current
                    var transfers: [[String: String]] = []
                    results.append(ClaudeChats.syncAll(to: spaces[target], spaces: spaces,
                        backups: tree.appendingPathComponent("Backups"), cache: &caches[mode], parallelism: mode == 0 ? 1 : 4,
                        read: { url in
                            if round == 0 && target == 1 && url == shared { sharedReads[mode] += 1 }
                            return try Data(contentsOf: url)
                        }, observe: { transfer in
                            XCTAssertTrue(Thread.current === caller)
                            transfers.append(self.observed(transfer, root: tree))
                        }))
                    observations.append(transfers)
                }
                let a = results[0], b = results[1]
                XCTAssertEqual(a.transferred, b.transferred); XCTAssertEqual(a.checked, b.checked)
                XCTAssertEqual(a.total, b.total); XCTAssertEqual(a.stopped, b.stopped)
                XCTAssertEqual(a.issues.map { relative($0, to: serial) }, b.issues.map { relative($0, to: parallel) })
                XCTAssertEqual(a.notes.map { relative($0, to: serial) }, b.notes.map { relative($0, to: parallel) })
                XCTAssertEqual(observations[0], observations[1])
                XCTAssertEqual(Set(caches[0].stamps.keys), Set(caches[1].stamps.keys))
                XCTAssertEqual(Set(caches[0].failed.keys), Set(caches[1].failed.keys))
                XCTAssertEqual(Set(caches[0].stamps.filter { $0.value.hasSuffix(":applied") }.keys),
                               Set(caches[1].stamps.filter { $0.value.hasSuffix(":applied") }.keys))
                if round == 0 {
                    XCTAssertGreaterThan(a.checked, 70)
                    if target == 1 {
                        XCTAssertEqual(observations[0].first { $0["chatID"] == "local_Q" }?["kind"], "upToDate")
                        XCTAssertFalse(a.notes.isEmpty)
                        XCTAssertEqual(a.issues.count, 3)
                    }
                    if target == 2 {
                        XCTAssertEqual(observations[0].first { $0["chatID"] == "local_Qnew" }?["kind"], "updateMetadata")
                    }
                }
                try compareTrees(serial, parallel)
            }
        }
        XCTAssertGreaterThan(sharedReads[0], 0)
        XCTAssertGreaterThan(sharedReads[1], sharedReads[0])
    }

    func testFailedApplyInvalidatesBatchStamps() throws {
        for workers in [1, 4] {
            let tree = root.appendingPathComponent("workers-\(workers)")
            let spaces = try spaces(at: tree)
            let a = spaces[0], b = spaces[1]
            for (id, activity) in [("P", 300.0), ("Q", 200.0)] {
                try write(a, id, ["shared", "continued"], activity: activity, cli: "shared")
                try write(b, id, ["shared"], cli: "shared")
            }
            let backups = tree.appendingPathComponent("Backups")
            try Data().write(to: backups) // A file blocks backup creation, so apply must fail.
            var cache = ChatSyncCache()
            var kinds: [ChatTransfer.Kind] = []
            let result = ClaudeChats.syncAll(to: b, spaces: spaces, backups: backups, cache: &cache,
                                            parallelism: workers, observe: { transfer in
                kinds.append(transfer.kind)
                if transfer.chatID == "local_P" {
                    // Change a shared input after prepare, before the failing apply.
                    do { try self.append("continued", to: self.native(b, cli: "shared")) }
                    catch { XCTFail("\(error)") }
                }
            })
            XCTAssertEqual(result.checked, 2)
            XCTAssertEqual(result.transferred, 0)
            XCTAssertEqual(result.issues.count, 1)
            XCTAssertEqual(kinds, [.update, .upToDate])
            XCTAssertTrue(cache.failed.isEmpty)
            XCTAssertTrue(cache.stamps.isEmpty)
        }
    }

    func testReadIsNeverCalledConcurrently() throws {
        let spaces = try spaces(at: root)
        for i in 0..<24 { try write(spaces[0], "chat\(i)", ["message \(i)"]) }
        let lock = NSLock()
        var inside = 0, maximum = 0
        let result = ClaudeChats.syncAll(to: spaces[1], spaces: spaces, backups: backups, parallelism: 4, read: { url in
            lock.withLock { inside += 1; maximum = max(maximum, inside) }
            defer { lock.withLock { inside -= 1 } }
            usleep(1_000)
            return try Data(contentsOf: url)
        })
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(inside, 0)
        XCTAssertEqual(result.transferred, 24)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testCancellationStopsBetweenChatsInBothModes() async throws {
        let serial = root.appendingPathComponent("serial"), parallel = root.appendingPathComponent("parallel")
        let limit = 5
        for (tree, workers) in [(serial, 1), (parallel, 4)] {
            let spaces = try spaces(at: tree)
            for i in 0..<20 { try write(spaces[0], "chat\(i)", ["message \(i)"], activity: Double(100 + i)) }
            let order = ClaudeChats.scan(spaces).map(\.id)
            let backups = tree.appendingPathComponent("Backups")
            let result = await Task.detached {
                ClaudeChats.syncAll(to: spaces[1], spaces: spaces, backups: backups, parallelism: workers, progress: { checked, _ in
                    if checked == limit { withUnsafeCurrentTask { $0?.cancel() } }
                })
            }.value
            XCTAssertTrue(result.stopped)
            XCTAssertEqual(result.checked, limit)
            XCTAssertEqual(result.transferred, limit)
            XCTAssertEqual(result.total, order.count)
            XCTAssertTrue(result.issues.isEmpty)
            let target = try namespace(spaces[1])
            for (index, id) in order.enumerated() {
                XCTAssertEqual(FileManager.default.fileExists(atPath: target.appendingPathComponent(id + ".json").path), index < limit)
                XCTAssertEqual(FileManager.default.fileExists(atPath: native(spaces[1], cli: String(id.dropFirst(6))).path), index < limit)
            }
        }
        try compareTrees(serial, parallel)
    }
}
