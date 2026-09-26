import AppKit
import Foundation

/// A queued edit can be reached by the async worker and the termination flush.
/// The lock makes resolution exactly once, including its retained result.
final class SettingsPendingMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let mutation: SettingsMutation
    private var result: SettingsMutationCoordinatorResult?

    init(_ mutation: SettingsMutation) { self.mutation = mutation }

    func perform(using coordinator: SettingsMutationCoordinator) async -> SettingsMutationCoordinatorResult {
        resolve(using: coordinator)
    }

    func resolve(using coordinator: SettingsMutationCoordinator) -> SettingsMutationCoordinatorResult {
        lock.withLock {
            if let result { return result }
            let resolved = coordinator.applySynchronously(mutation)
            result = resolved
            return resolved
        }
    }
}

/// AppKit posts both notifications on the main thread. Tokens are retained
/// until the settings facade is released, including after its window closes.
final class SettingsLifecycleObservers: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]

    @MainActor
    init(resignKey: @escaping @MainActor @Sendable () -> Void,
         terminate: @escaping @MainActor @Sendable () -> Void) {
        tokens = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: nil
            ) { _ in MainActor.assumeIsolated { resignKey() } },
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in MainActor.assumeIsolated { terminate() } },
        ]
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
