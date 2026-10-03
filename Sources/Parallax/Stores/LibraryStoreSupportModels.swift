import AppKit
import Foundation
import Observation

enum BackgroundStorageRelocationResult: Sendable {
    case succeeded(StorageRelocationOutcome)
    case failed(code: StorageRelocationError.Code?, message: String)
}

struct PendingApplicationRelink {
    let proposal: ApplicationRelinkProposal
    let baselineVersion: LibraryVersionToken
}

struct StagedProfileKeychainSecret: Equatable, Sendable {
    let profile: LaunchProfile
    let reference: EnvironmentSecretReference
}

struct PendingProfileEditingDraft: Equatable, Sendable {
    let applicationID: ManagedApplication.ID
    let draft: LaunchProfile
    let baseline: LaunchProfile
    let baselineVersion: LibraryVersionToken
    let stagedKeychainReferences: Set<EnvironmentSecretReference>
    let pendingKeychainDeletionReferences: Set<EnvironmentSecretReference>
}

extension ManagedApplicationEditField {
    var localizedLabel: String {
        switch self {
        case .displayName: String(localized: "Application name")
        case .bundleIdentifier: String(localized: "Bundle identifier")
        case .appPath: String(localized: "Application path")
        case .preset: String(localized: "Preset")
        }
    }
}

extension LaunchProfileEditField {
    var localizedLabel: String {
        switch self {
        case .name: String(localized: "Name")
        case .argumentsText: String(localized: "Arguments")
        case .environmentText: String(localized: "Environment")
        case .notes: String(localized: "Notes")
        case .isolationOwnership: String(localized: "Isolation ownership")
        case .childEnvironmentPolicy: String(localized: "Child environment policy")
        case .sensitiveEnvironmentKeys: String(localized: "Sensitive environment keys")
        }
    }
}

enum LibraryLocalizedList {
    static func string(
        from values: [String],
        bundle: Bundle = PackagedRuntimeResources.bundle
    ) -> String {
        let formatter = ListFormatter()
        // An explicitly resolved .lproj bundle stores its strings directly;
        // preferredLocalizations describes sub-bundles, not that language.
        let localization = bundle.bundleURL.pathExtension == "lproj"
            ? bundle.bundleURL.deletingPathExtension().lastPathComponent
            : bundle.preferredLocalizations.first ?? "en"
        formatter.locale = Locale(identifier: localization)
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }
}

typealias LibraryReloadRetryScheduler = @MainActor (
    _ delay: Duration,
    _ action: @escaping @MainActor @Sendable () -> Void
) -> (@MainActor () -> Void)

enum LibraryReloadRetry {
    @MainActor
    static func schedule(
        after delay: Duration,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor () -> Void {
        let task = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}

final class LibraryReloadActivationObservation {
    private let observers: [any NSObjectProtocol]

    init(action: @escaping @MainActor @Sendable () -> Void) {
        observers = [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in action() }
            }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
