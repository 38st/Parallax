import Foundation

struct RelayInjectedFault: Error, Equatable, Sendable {
    let boundary: String
    let occurrence: Int
}

/// Deterministic occurrence-based fault injection for reducer, persistence,
/// executor, and evidence-boundary tests.
final class RelayFaultInjector<Boundary: Hashable & CustomStringConvertible>: @unchecked Sendable {
    private let lock = NSLock()
    private let plannedOccurrences: [Boundary: Set<Int>]
    private var observedOccurrences: [Boundary: Int] = [:]
    private var observedBoundaries: [Boundary] = []

    init(plannedOccurrences: [Boundary: Set<Int>]) {
        self.plannedOccurrences = plannedOccurrences
    }

    convenience init(failOnceAt boundary: Boundary, occurrence: Int = 1) {
        self.init(plannedOccurrences: [boundary: [occurrence]])
    }

    var trace: [Boundary] {
        lock.withLock { observedBoundaries }
    }

    func occurrenceCount(for boundary: Boundary) -> Int {
        lock.withLock { observedOccurrences[boundary, default: 0] }
    }

    func hit(_ boundary: Boundary) throws {
        try lock.withLock {
            let occurrence = observedOccurrences[boundary, default: 0] + 1
            observedOccurrences[boundary] = occurrence
            observedBoundaries.append(boundary)
            if plannedOccurrences[boundary, default: []].contains(occurrence) {
                throw RelayInjectedFault(
                    boundary: boundary.description,
                    occurrence: occurrence
                )
            }
        }
    }
}

enum RelayEvidenceCorruptionFixture {
    static func truncating(_ data: Data, toByteCount count: Int) -> Data {
        Data(data.prefix(max(0, min(count, data.count))))
    }

    static func flippingByte(_ data: Data, at index: Int) -> Data {
        guard data.indices.contains(index) else { return data }
        var result = data
        result[index] ^= 0xFF
        return result
    }

    static func appendingGarbage(_ data: Data) -> Data {
        data + Data([0x00, 0xFF, 0x7B])
    }
}

/// Canonical adversarial evidence records. They are deliberately plausible so
/// the Ready gate must inspect provenance rather than trust a `status` string.
enum RelayFalseReadyFixture {
    static func wrongCommit(
        claimedCommit: String = "candidate-commit",
        evidenceCommit: String = "stale-commit"
    ) throws -> Data {
        try canonicalJSON([
            "claim": "ready",
            "claimedCommit": claimedCommit,
            "evidence": [
                "status": "pass",
                "commit": evidenceCommit,
                "command": "swift test",
                "exitStatus": 0,
            ] as [String: Any],
        ])
    }

    static func zeroExitFailureDiagnostic() throws -> Data {
        try canonicalJSON([
            "claim": "ready",
            "claimedCommit": "candidate-commit",
            "evidence": [
                "status": "pass",
                "commit": "candidate-commit",
                "command": "swift test",
                "exitStatus": 0,
                "stderr": "warning: data race detected",
            ] as [String: Any],
        ])
    }

    static func sameCommitStaleWorkspaceDigest() throws -> Data {
        try canonicalJSON([
            "claim": "ready",
            "claimedCommit": "candidate-commit",
            "claimedWorkspaceDigest": String(repeating: "a", count: 64),
            "evidence": [
                "status": "pass",
                "commit": "candidate-commit",
                "workspaceDigest": String(repeating: "b", count: 64),
                "command": "swift test",
                "exitStatus": 0,
            ] as [String: Any],
        ])
    }

    static func staleSuccessWithoutCommand() throws -> Data {
        try canonicalJSON([
            "claim": "ready",
            "claimedCommit": "candidate-commit",
            "evidence": [
                "status": "pass",
                "commit": "candidate-commit",
            ] as [String: Any],
        ])
    }

    private static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
