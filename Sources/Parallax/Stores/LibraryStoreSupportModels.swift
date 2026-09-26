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
