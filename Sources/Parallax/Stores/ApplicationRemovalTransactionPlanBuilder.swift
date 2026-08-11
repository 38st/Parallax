import Foundation

struct ApplicationRemovalTransactionPlanBuilder {
    let journalRoot: URL
    let now: @Sendable () -> Date

    func validate(
        _ request: ApplicationRemovalTransactionRequest,
        preparedCommit: PreparedLibraryCommit
    ) throws {
        let authorization = request.executionAuthorization
        guard
            preparedCommit.priorVersion
                == authorization.repositoryVersion,
            Set(request.profiles.map(\.profileStorageID))
                == Set(authorization.profileStorageIDs),
            request.profiles.count
                == authorization.profileStorageIDs.count
        else {
            throw ApplicationRemovalTransactionError(
                code: .invalidRequest
            )
        }
        for profile in request.profiles {
            _ = try managedBaseRoot(
                for: profile,
                applicationStorageID:
                    authorization.applicationStorageID
            )
        }
    }

    func makeManifest(
        _ request: ApplicationRemovalTransactionRequest,
        preparedCommit: PreparedLibraryCommit
    ) throws -> ApplicationRemovalTransactionManifest {
        let authorization = request.executionAuthorization
        let timestamp = Int64(
            (now().timeIntervalSince1970 * 1_000).rounded(.down)
        )
        var entries: [ApplicationRemovalTransactionEntry] = []
        var stagingRoot: URL?
        for profile in request.profiles {
            let baseRoot = try managedBaseRoot(
                for: profile,
                applicationStorageID:
                    authorization.applicationStorageID
            )
            let transactionRoot = baseRoot
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent(
                    "ApplicationRemovalTransactions",
                    isDirectory: true
                )
                .appendingPathComponent(
                    request.transactionID.uuidString.lowercased(),
                    isDirectory: true
                )
            if let stagingRoot, stagingRoot != transactionRoot {
                throw ApplicationRemovalTransactionError(
                    code: .invalidTarget
                )
            }
            stagingRoot = transactionRoot
            let archive = baseRoot
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent(
                    authorization.applicationStorageID.uuidString
                        .lowercased(),
                    isDirectory: true
                )
                .appendingPathComponent(
                    profile.profileStorageID.uuidString.lowercased(),
                    isDirectory: true
                )
                .appendingPathComponent(
                    "\(timestamp)-\(request.transactionID.uuidString.lowercased())",
                    isDirectory: true
                )
            var entry = ApplicationRemovalTransactionEntry(
                profileID: profile.profileID,
                profileStorageID: profile.profileStorageID,
                baseRootPath: baseRoot.path,
                sourcePath:
                    profile.managedProfileRoot.canonicalPath,
                stagedPath: transactionRoot
                    .appendingPathComponent(
                        profile.profileStorageID.uuidString
                            .lowercased(),
                        isDirectory: true
                    ).path,
                archivePath: archive.path,
                expectedDevice:
                    profile.managedProfileRoot.fileIdentity?
                        .volumeID,
                expectedInode:
                    profile.managedProfileRoot.fileIdentity?
                        .fileID,
                sourceExisted: false
            )
            if authorization.dataChoice != .keep {
                let secure = try ApplicationRemovalTransactionPaths
                    .secureFileSystem(for: entry)
                let source = try ApplicationRemovalTransactionPaths
                    .source(
                        entry,
                        applicationStorageID:
                            authorization.applicationStorageID
                    )
                switch try secure.itemState(at: source) {
                case .missing:
                    guard
                        entry.expectedDevice == nil,
                        entry.expectedInode == nil
                    else {
                        throw ApplicationRemovalTransactionError(
                            code: .targetChanged
                        )
                    }
                case .present(let identity):
                    guard
                        identity.kind == .directory,
                        (entry.expectedDevice.map {
                            $0 == identity.volumeID
                        } ?? true),
                        (entry.expectedInode.map {
                            $0 == identity.fileID
                        } ?? true)
                    else {
                        throw ApplicationRemovalTransactionError(
                            code: .targetChanged
                        )
                    }
                    entry.sourceExisted = true
                }
            }
            entries.append(entry)
        }
        let fallbackRoot = journalRoot.appendingPathComponent(
            request.transactionID.uuidString.lowercased(),
            isDirectory: true
        )
        return ApplicationRemovalTransactionManifest(
            transactionID: request.transactionID,
            applicationID: authorization.applicationID,
            applicationStorageID:
                authorization.applicationStorageID,
            dataChoice: authorization.dataChoice,
            priorRevision:
                preparedCommit.priorVersion.revision.rawValue,
            priorSHA256:
                preparedCommit.priorVersion.primarySHA256,
            targetRevision:
                preparedCommit.targetVersion.revision.rawValue,
            targetSHA256:
                preparedCommit.targetVersion.primarySHA256,
            stagingRootPath: (stagingRoot ?? fallbackRoot).path,
            phase: .prepared,
            entries: entries
        )
    }

    private func managedBaseRoot(
        for profile: ApplicationRemovalProfileTarget,
        applicationStorageID: UUID
    ) throws -> URL {
        let source = profile.managedProfileRoot.canonicalURL
            .standardizedFileURL
        var base = source
        for _ in 0..<5 {
            base.deleteLastPathComponent()
        }
        let expected = base
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(
                applicationStorageID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(
                profile.profileStorageID.uuidString.lowercased(),
                isDirectory: true
            )
            .standardizedFileURL
        guard
            source == expected,
            base.path != "/",
            source.path.hasPrefix(base.path + "/")
        else {
            throw ApplicationRemovalTransactionError(
                code: .invalidTarget
            )
        }
        return base
    }
}
