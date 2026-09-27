import AppKit
import Foundation

/// Weak session attribution shared by windows in this Parallax process. Every
/// control still verifies the full process identity through the owning session.
final class ProcessWideLaunchSupervision: @unchecked Sendable {
    private struct Entry { weak var launch: TrackedApplicationLaunch? }
    static let shared = ProcessWideLaunchSupervision()
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func register(_ launch: TrackedApplicationLaunch, requestID: UUID) {
        lock.withLock {
            entries = entries.filter { $0.value.launch != nil }
            entries[requestID] = Entry(launch: launch)
        }
    }
    func remove(requestID: UUID) { _ = lock.withLock { entries.removeValue(forKey: requestID) } }
    func snapshot() -> [UUID: TrackedApplicationLaunch] {
        lock.withLock { entries.compactMapValues(\.launch) }
    }
    func launch(requestID: UUID) -> TrackedApplicationLaunch? {
        lock.withLock { entries[requestID]?.launch }
    }
}
