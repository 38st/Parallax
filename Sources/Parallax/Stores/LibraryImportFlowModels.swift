import AppKit
import Foundation
import Observation

enum LibraryExportSensitivePolicy: Equatable, Sendable {
    case omit
    case redact
    case include
}

enum LibraryPortableExportKind: String, Sendable {
    case libraryMetadata
    case settingsAndTemplates
    case portableConfiguration
}

enum LibraryImportConflictChoice: Sendable {
    case keepExisting
    case useImported
    case keepBoth
    case skip
}

struct LibraryImportSummary: Equatable, Sendable {
    let applicationCount: Int
    let profileCount: Int
    let warnings: [String]

    var message: String {
        var lines = [
            String(
                localized:
                    "\(LocalizedCount.applications(applicationCount)), \(LocalizedCount.profiles(profileCount))."
            ),
            String(
                localized:
                    "Import changes library metadata only. Existing profile data is preserved."
            ),
        ]
        lines.append(contentsOf: warnings)
        return lines.joined(separator: "\n")
    }
}

struct LibraryImportConflictTarget: Identifiable, Equatable, Sendable {
    var id: String {
        [
            applicationID.uuidString.lowercased(),
            profileID?.uuidString.lowercased() ?? "",
        ].joined(separator: ":")
    }

    let applicationID: UUID
    let profileID: UUID?
    let label: String
}

struct LibraryImportConflictPrompt: Equatable, Sendable {
    let sessionID: UUID
    let conflictID: LibraryImportConflictID
    let message: String
    let targets: [LibraryImportConflictTarget]
}

struct PreparedLibraryImport: Equatable, Sendable {
    let sessionID: UUID
    let sourceSHA256: String
    let expectedVersion: LibraryVersionToken?
    let applications: [ManagedApplication]
    let canonicalApplications: [LibraryImportApplication]
    let warnings: [String]

    init(
        sessionID: UUID = UUID(),
        sourceSHA256: String,
        expectedVersion: LibraryVersionToken?,
        applications: [ManagedApplication],
        canonicalApplications: [LibraryImportApplication],
        warnings: [String]
    ) {
        self.sessionID = sessionID
        self.sourceSHA256 = sourceSHA256
        self.expectedVersion = expectedVersion
        self.applications = applications
        self.canonicalApplications = canonicalApplications
        self.warnings = warnings
    }

    var summary: LibraryImportSummary {
        LibraryImportSummary(
            applicationCount: applications.count,
            profileCount: applications.reduce(into: 0) {
                $0 += $1.profiles.count
            },
            warnings: warnings
        )
    }
}

struct LibraryImportMergeSession: Equatable, Sendable {
    let preparedImport: PreparedLibraryImport
    let resolutions:
        [LibraryImportConflictID: LibraryImportConflictResolution]
    let conflict: LibraryImportConflict
    let projectedApplications: [ManagedApplication]
}

enum LibraryImportFlowState: Equatable, Sendable {
    case idle
    case choosing(PreparedLibraryImport)
    case resolving(LibraryImportMergeSession)

    var preparedImport: PreparedLibraryImport? {
        switch self {
        case .idle:
            nil
        case .choosing(let preparedImport):
            preparedImport
        case .resolving(let session):
            session.preparedImport
        }
    }
}

enum LibraryImportFlowPhase: Equatable, Sendable {
    case idle
    case choosing
    case resolving
}
