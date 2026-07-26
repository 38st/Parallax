import Foundation
import Observation

struct LibraryChangeEvent: Equatable, Sendable {
    let sequence: UInt64
    let sourceSceneID: UUID
}

/// Process-local invalidation for window stores backed by the same durable
/// repository. Repository compare-and-swap remains the authority; this only
/// tells peer scenes to load its newly committed snapshot.
@Observable
@MainActor
final class LibraryChangeBroadcaster {
    private(set) var latestEvent: LibraryChangeEvent?
    private var nextSequence: UInt64 = 1

    func publish(sourceSceneID: UUID) {
        latestEvent = LibraryChangeEvent(
            sequence: nextSequence,
            sourceSceneID: sourceSceneID
        )
        nextSequence &+= 1
    }
}
