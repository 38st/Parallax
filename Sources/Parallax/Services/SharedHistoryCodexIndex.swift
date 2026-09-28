import Foundation

enum SharedHistoryCodexIndex {
    /// Ask the provider to discover local rollouts. No login, turn, injection,
    /// resume, or model request is sent; each account keeps its own databases.
    static func refresh(_ home: URL) async throws {
        let executable = try AIAccountConnectionService.trustedExecutable(named: "codex")
        try await refresh(home, executable: executable)
    }

    static func refresh(_ home: URL, executable: TrustedProviderExecutable) async throws {
        let session = CodexAppServerSession(executable: executable, codexHome: home)
        defer { session.close() }
        try session.start()
        try session.sendInitialization()
        guard try await session.waitForResponse(id: 0, timeout: 15), session.response(id: 0)?["error"] == nil else {
            throw SharedHistoryError.indexFailed
        }
        var cursor: String?
        for id in 1...12 {
            var params: [String: Any] = ["limit": 200, "useStateDbOnly": false, "modelProviders": [], "sourceKinds": []]
            if let cursor { params["cursor"] = cursor }
            try session.send(["id": id, "method": "thread/list", "params": params])
            guard try await session.waitForResponse(id: id, timeout: 15),
                  let result = session.response(id: id)?["result"] as? [String: Any],
                  result["data"] is [[String: Any]] else { throw SharedHistoryError.indexFailed }
            cursor = result["nextCursor"] as? String
            if cursor == nil { return }
        }
        throw SharedHistoryError.indexFailed
    }
}
