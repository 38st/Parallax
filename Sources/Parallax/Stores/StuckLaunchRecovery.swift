import Foundation

struct StuckLaunchRecord: Equatable, Sendable {
    let requestID: UUID
    let identity: ProfileActivityIdentity
    let directoryIdentity: SecureManagedItemIdentity
    let manifest: SecureManagedManifest
}

enum StuckLaunchRecoveryError: LocalizedError {
    case changedOrActive

    var errorDescription: String? {
        String(localized: "The launch record changed or the app may still be running. Quit the app and try again.")
    }
}
