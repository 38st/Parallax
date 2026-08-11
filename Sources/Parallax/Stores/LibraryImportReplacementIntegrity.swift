import Foundation

enum LibraryImportReplacementIntegrity {
    static func validate(
        _ evidence: LibraryImportReplacementEvidence
    ) throws {
        guard
            evidence.applicationCount
                == evidence.preparedCommit.applications.count,
            evidence.profileCount
                == evidence.preparedCommit.applications.reduce(into: 0, {
                    $0 += $1.profiles.count
                }),
            evidence.expectedVersion
                == evidence.preparedCommit.priorVersion,
            evidence.preparedCommit.targetVersion.primarySHA256
                == LibraryPersistence.sha256(
                    evidence.preparedCommit.targetBytes
                ),
            evidence.integritySHA256 == digest(
                id: evidence.id,
                applicationCount: evidence.applicationCount,
                profileCount: evidence.profileCount,
                warnings: evidence.validationWarnings,
                expectedVersion: evidence.expectedVersion,
                priorBytes: evidence.priorLibraryBytes,
                preparedCommit: evidence.preparedCommit
            )
        else {
            throw LibraryImportReplacementError(.invalidPreview)
        }
    }

    static func digest(
        id: UUID,
        applicationCount: Int,
        profileCount: Int,
        warnings: [LibraryImportReplacementWarning],
        expectedVersion: LibraryVersionToken,
        priorBytes: Data,
        preparedCommit: PreparedLibraryCommit
    ) -> String {
        var fields = [
            id.uuidString.lowercased(),
            String(applicationCount),
            String(profileCount),
            String(expectedVersion.revision.rawValue),
            expectedVersion.primarySHA256 ?? "",
            LibraryPersistence.sha256(priorBytes),
            String(preparedCommit.targetVersion.revision.rawValue),
            preparedCommit.targetVersion.primarySHA256 ?? "",
            LibraryPersistence.sha256(preparedCommit.targetBytes),
        ]
        fields.append(
            contentsOf: warnings.map {
                [$0.code, $0.severity.rawValue, $0.path, $0.message]
                    .joined(separator: "\u{1f}")
            }
        )
        return LibraryPersistence.sha256(
            Data(fields.joined(separator: "\n").utf8)
        )
    }
}
