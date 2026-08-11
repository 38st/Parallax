import Foundation

enum SettingsPrimaryPreparedPrior: Equatable, Sendable {
    case missing
    case current(bytes: Data, token: SettingsVersionToken)
}

struct SettingsPrimaryPreparedPublication: Equatable, Sendable {
    let prior: SettingsPrimaryPreparedPrior
    let targetDocument: SettingsDocument
    let targetBytes: Data
    let targetToken: SettingsVersionToken
}

indirect enum SettingsPrimaryPublicationFailure:
    Error,
    Equatable,
    Sendable
{
    case invalidRequest(String)
    case system(SettingsPrimaryMutationLockSystemFailure)
    case lockedRead(SettingsPrimaryLockedInspectionError)
    case compareAndSwapMismatch
    case writeNoProgress
    case publishedIdentityMismatch
    case displacedPriorMismatch
}

enum SettingsPrimaryPublicationResidual: Equatable, Sendable {
    case possiblePreservedPath(name: String)
    case displacedPrior(name: String, token: SettingsVersionToken)
}

struct SettingsPrimaryPublicationEvidence: Equatable, Sendable {
    let classification: SettingsPrimaryMutationClassification
    let targetProofEligible: Bool
    let failure: SettingsPrimaryPublicationFailure
    let classificationReadFailure: SettingsPrimaryLockedInspectionError?
    let closeFailures: [SettingsPrimaryMutationLockSystemFailure]
    let residual: SettingsPrimaryPublicationResidual?
}

enum SettingsPrimaryPublicationResult: Equatable, Sendable {
    case committed(residual: SettingsPrimaryPublicationResidual?)
    case failed(SettingsPrimaryPublicationEvidence)
}

enum SettingsPrimaryPublicationSystemCall: Sendable, Equatable {
    case createTemporary
    case inspectTemporary
    case setTemporaryMode
    case reinspectTemporary
    case inspectTemporaryPath
    case syncTemporary
    case renameMissing
    case renameCurrent
    case syncSettings
    case inspectPublishedPrimaryPath
    case openDisplacedPrior
    case inspectDisplacedPrior
    case inspectDisplacedPriorPath
    case closeTemporary
    case closeDisplacedPrior
}

enum SettingsPrimaryPublicationWriteDirective: Sendable, Equatable {
    case system
    case failure(Int32)
    case limit(Int)
    case zero
}

enum SettingsPrimaryPublicationBoundary: Sendable, Equatable {
    case afterTemporaryOpen
    case beforeCompareAndSwap
    case afterCompareAndSwap
    case beforeRename
    case afterRename
    case beforePostflight
}
