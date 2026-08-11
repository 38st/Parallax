import Foundation

struct LibraryImportReplacementPlanBuilder {
    let repository: any LibraryRepositoryPersisting
    let validator: LibraryImportValidator
    let makePreviewID: () -> UUID

    func makeEvidence(
        importData: Data,
        expectedVersion: LibraryVersionToken?
    ) throws -> LibraryImportReplacementEvidence {
        let report = validator.validate(importData)
        guard
            report.isValid,
            let document = report.document
        else {
            throw LibraryImportReplacementError(.validationFailed)
        }
        let warnings = report.issues
            .filter { $0.severity == .warning }
            .map {
                LibraryImportReplacementWarning(
                    code: $0.code.rawValue,
                    severity: .warning,
                    path: $0.path,
                    message: $0.message
                )
            }
        return try makeEvidence(
            replacementApplications: document.applications,
            validationWarnings: warnings,
            expectedVersion: expectedVersion
        )
    }

    private func makeEvidence(
        replacementApplications: [ManagedApplication],
        validationWarnings: [LibraryImportReplacementWarning],
        expectedVersion: LibraryVersionToken?
    ) throws -> LibraryImportReplacementEvidence {
        let prior: LibraryImportReplacementPriorLibrary
        switch repository.load() {
        case .missing:
            prior = LibraryImportReplacementPriorLibrary(
                applications: [],
                version: .missing,
                bytes: try encodedEmptyLibrary()
            )
        case let .loaded(snapshot):
            prior = LibraryImportReplacementPriorLibrary(
                applications: snapshot.applications,
                version: snapshot.versionToken,
                bytes: snapshot.originalBytes
            )
        case .migrationRequired, .recoveryRequired, .readOnly:
            throw LibraryImportReplacementError(.libraryUnavailable)
        }
        if let expectedVersion,
           prior.version != expectedVersion
        {
            throw LibraryImportReplacementError(.invalidPreview)
        }

        let prepared = try repository.prepare(
            replacementApplications,
            expectedVersion: prior.version
        )
        let id = makePreviewID()
        let applicationCount = replacementApplications.count
        let profileCount = replacementApplications.reduce(into: 0) {
            $0 += $1.profiles.count
        }
        let integrity = LibraryImportReplacementIntegrity.digest(
            id: id,
            applicationCount: applicationCount,
            profileCount: profileCount,
            warnings: validationWarnings,
            expectedVersion: prior.version,
            priorBytes: prior.bytes,
            preparedCommit: prepared
        )
        return LibraryImportReplacementEvidence(
            id: id,
            applicationCount: applicationCount,
            profileCount: profileCount,
            validationWarnings: validationWarnings,
            expectedVersion: prior.version,
            priorApplications: prior.applications,
            priorLibraryBytes: prior.bytes,
            preparedCommit: prepared,
            integritySHA256: integrity
        )
    }

    private func encodedEmptyLibrary() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            LibraryDocument(
                revision: .initial,
                applications: []
            )
        )
    }
}
