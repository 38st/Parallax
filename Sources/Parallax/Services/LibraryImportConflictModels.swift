import Foundation

struct LibraryImportApplicationMatch {
    let index: Int
    var reasons: Set<LibraryImportConflictReason>
}

struct LibraryImportProfileLocation: Hashable {
    let applicationIndex: Int
    let profileIndex: Int
}

struct LibraryImportProfileMatch {
    let location: LibraryImportProfileLocation
    let reasons: Set<LibraryImportConflictReason>
}

/// Converts the compatibility API's optional profile identifier into a scope-
/// correct decision before any mutation occurs.
enum LibraryImportScopedDecision {
    enum Application {
        case keepExisting(applicationID: UUID)
        case useImported(applicationID: UUID)
        case keepBoth(
            renamedTo: String,
            identity: LibraryImportFreshApplicationIdentity
        )
        case skip
    }

    enum Profile {
        case keepExisting(applicationID: UUID, profileID: UUID)
        case useImported(applicationID: UUID, profileID: UUID)
        case keepBoth(
            renamedTo: String,
            identity: LibraryImportFreshProfileIdentity
        )
        case skip
    }

    static func application(
        _ resolution: LibraryImportConflictResolution
    ) throws -> Application {
        switch resolution {
        case .keepExisting(let applicationID, let profileID):
            guard profileID == nil else {
                throw LibraryImportConflictEngineError
                    .conflictResolutionDoesNotMatch
            }
            return .keepExisting(applicationID: applicationID)
        case .useImported(let applicationID, let profileID):
            guard profileID == nil else {
                throw LibraryImportConflictEngineError
                    .conflictResolutionDoesNotMatch
            }
            return .useImported(applicationID: applicationID)
        case .keepBoth(let keepBoth):
            guard case let .application(rename, identity) = keepBoth else {
                throw LibraryImportConflictEngineError.wrongKeepBothScope
            }
            return .keepBoth(renamedTo: rename, identity: identity)
        case .skip:
            return .skip
        }
    }

    static func profile(
        _ resolution: LibraryImportConflictResolution
    ) throws -> Profile {
        switch resolution {
        case .keepExisting(let applicationID, let profileID):
            guard let profileID else {
                throw LibraryImportConflictEngineError
                    .conflictResolutionDoesNotMatch
            }
            return .keepExisting(
                applicationID: applicationID,
                profileID: profileID
            )
        case .useImported(let applicationID, let profileID):
            guard let profileID else {
                throw LibraryImportConflictEngineError
                    .conflictResolutionDoesNotMatch
            }
            return .useImported(
                applicationID: applicationID,
                profileID: profileID
            )
        case .keepBoth(let keepBoth):
            guard case let .profile(rename, identity) = keepBoth else {
                throw LibraryImportConflictEngineError.wrongKeepBothScope
            }
            return .keepBoth(renamedTo: rename, identity: identity)
        case .skip:
            return .skip
        }
    }
}
