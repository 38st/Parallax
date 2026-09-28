import Foundation

extension SharedHistoryService {
    static func forEachCodexConversation(
        _ participant: SharedHistoryParticipant,
        visit: (SharedHistoryConversation) throws -> Void
    ) throws {
        let sessions = try SecureManagedPath(["sessions"])
        if try participant.files.itemState(at: sessions) == .missing { return }
        var ids = Set<String>()
        var visited = 0
        func walk(_ path: SecureManagedPath, depth: Int) throws {
            guard depth <= 4 else { throw SharedHistoryError.unavailable }
            for name in try participant.files.directoryNames(at: path).sorted() {
                visited += 1
                guard visited <= 10_000 else { throw SharedHistoryError.unavailable }
                let child = try path.appending(name)
                guard case .present(let identity) = try participant.files.itemState(at: child) else {
                    throw SharedHistoryError.changed
                }
                if identity.kind == .directory { try walk(child, depth: depth + 1); continue }
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
                try autoreleasepool {
                    let data = try participant.files.readFile(at: child,
                        maximumBytes: ClaudeConversationCopyService.maximumTranscriptBytes)
                    let (id, normalized) = try codexTranscript(data)
                    guard name.hasSuffix(id + ".jsonl"), ids.count < 2_000,
                          ids.insert(id).inserted else { throw SharedHistoryError.unavailable }
                    try visit(SharedHistoryConversation(id: id, path: child, original: data, normalized: normalized, claude: nil))
                }
            }
        }
        try walk(sessions, depth: 0)
    }

    static func codexTranscript(_ data: Data) throws -> (String, Data) {
        guard data.last == 0x0A else { throw SharedHistoryError.unavailable }
        var result = Data()
        var id: String?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.count <= 16 * 1_024 * 1_024,
                  let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw SharedHistoryError.unavailable
            }
            if id == nil {
                guard record["type"] as? String == "session_meta",
                      let payload = record["payload"] as? [String: Any],
                      let sessionID = payload["id"] as? String, UUID(uuidString: sessionID) != nil,
                      let cwd = payload["cwd"] as? String, ClaudeConversationCopyService.validWorkingDirectory(cwd),
                      let source = payload["source"] as? String, ["cli", "vscode"].contains(source),
                      let version = payload["cli_version"] as? String,
                      ["0.153.2", "0.158.0-alpha.2.1"].contains(version) else {
                    throw SharedHistoryError.unavailable
                }
                id = sessionID
            }
            result.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            result.append(0x0A)
        }
        guard let id else { throw SharedHistoryError.unavailable }
        return (id, result)
    }
}
