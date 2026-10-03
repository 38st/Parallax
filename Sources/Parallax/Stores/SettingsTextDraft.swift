import Foundation
import Observation

@MainActor
struct SettingsDraftScheduler {
    typealias Cancellation = @MainActor () -> Void
    let schedule: (Duration, @escaping @MainActor () -> Void) -> Cancellation

    static func continuous() -> SettingsDraftScheduler {
        SettingsDraftScheduler { delay, action in
            let task = Task { @MainActor in
                do { try await Task.sleep(for: delay) }
                catch { return }
                action()
            }
            return { task.cancel() }
        }
    }
}

/// Keeps uncommitted text visible while withholding settings authority.
/// The binding remains authoritative if another edit or recovery replaces it.
@Observable
@MainActor
final class SettingsTextDraft {
    private(set) var value: String
    private var baseline: String
    private let id = UUID()
    private let settings: AppSettings
    private let read: () -> String
    private let write: (String) -> Void
    private let normalize: (String) -> String?
    private let scheduler: SettingsDraftScheduler
    @ObservationIgnored private var cancellation: SettingsDraftScheduler.Cancellation?
    @ObservationIgnored private var generation = 0

    init(
        settings: AppSettings,
        read: @escaping () -> String,
        write: @escaping (String) -> Void,
        normalize: @escaping (String) -> String? = { $0 },
        scheduler: SettingsDraftScheduler? = nil
    ) {
        self.settings = settings
        self.read = read
        self.write = write
        self.normalize = normalize
        self.scheduler = scheduler ?? .continuous()
        let initial = read()
        value = initial
        baseline = initial
    }

    func edit(_ text: String) {
        guard value != text else { return }
        value = text
        cancelScheduledCommit()
        guard value != baseline else {
            settings.removePendingTextDraft(id: id)
            return
        }
        settings.registerPendingTextDraft(id: id) { [weak self] in self?.commit() }
        let scheduledGeneration = generation
        cancellation = scheduler.schedule(.milliseconds(400)) { [weak self] in
            guard let self, generation == scheduledGeneration else { return }
            commitIfSettled()
        }
    }

    /// The pause timer saves only text that needs no cleanup. Trimming or
    /// rejecting text mid-typing would rewrite the field under the cursor, so
    /// that waits for Return, focus loss, or another explicit commit.
    private func commitIfSettled() {
        guard read() != baseline || normalize(value) == value else { return }
        commit()
    }

    func synchronize() {
        let current = read()
        guard current != baseline else { return }
        cancelScheduledCommit()
        baseline = current
        if value != current { value = current }
        settings.removePendingTextDraft(id: id)
    }

    func commit() {
        cancelScheduledCommit()
        if read() == baseline, value != baseline, let normalized = normalize(value) {
            write(normalized)
        }
        baseline = read()
        if value != baseline { value = baseline }
        settings.removePendingTextDraft(id: id)
    }

    private func cancelScheduledCommit() {
        generation += 1
        cancellation?()
        cancellation = nil
    }
}
