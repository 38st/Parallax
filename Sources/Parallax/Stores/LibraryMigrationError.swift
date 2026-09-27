import Foundation
import Darwin

enum LibraryMigrationError: LocalizedError, Equatable {
    case sourceChanged
    case recoveryConflict
    case invalidJournal
    case unsupportedSourceItem(String)

    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            String(localized: "Legacy profile data changed while it was being migrated.")
        case .recoveryConflict:
            String(localized: "Migration recovery found library data that matches neither the original nor the committed version.")
        case .invalidJournal:
            String(localized: "The migration recovery journal is invalid.")
        case let .unsupportedSourceItem(path):
            String(localized: "The legacy profile contains an unsupported filesystem item at \(path).")
        }
    }
}
