import AppKit
import Foundation
import Observation

enum LibraryStoreInfrastructureError: LocalizedError {
    case ambiguousDurableActivity(Int)
    case startupRecoveryDidNotConverge

    var errorDescription: String? {
        switch self {
        case let .ambiguousDurableActivity(count):
            String(
                localized: "\(count) durable launch activity record(s) could not be reconciled safely."
            )
        case .startupRecoveryDidNotConverge:
            String(
                localized:
                    "Startup recovery did not reach a stable library state. Parallax stopped retrying to protect the library."
            )
        }
    }
}

enum LibraryImportStoreError: LocalizedError {
    case invalidImportFile
    case replacementUnavailable
    case staleImportSession
    case unresolvedConflict
    case conflictTargetRequired

    var errorDescription: String? {
        switch self {
        case .invalidImportFile:
            String(
                localized:
                    "Choose a regular JSON file within the supported import size limit."
            )
        case .replacementUnavailable:
            String(
                localized:
                    "Recoverable library replacement is unavailable because backup services are not ready."
            )
        case .staleImportSession:
            String(
                localized:
                    "The library changed after this import was reviewed. Start the import again."
            )
        case .unresolvedConflict:
            String(
                localized:
                    "The import still contains an unresolved conflict."
            )
        case .conflictTargetRequired:
            String(
                localized:
                    "Choose the exact existing application or profile for this conflict decision."
            )
        }
    }
}
