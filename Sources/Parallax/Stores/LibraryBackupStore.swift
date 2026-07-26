import Foundation

enum LibraryRecoveryArtifactKind: String, Codable, Sendable {
    case backup
    case quarantine
}

enum LibraryRecoveryArtifactContent: String, Codable, Sendable {
    case currentLibrary
    case legacyMigrationSource
    case unvalidatedQuarantine
}

enum LibraryBackupReason: String, Codable, Sendable {
    case migration
    case importReplacement
    case destructiveRewrite
    case corruptPrimary
    case manual
}

enum LibraryRecoveryArtifactProblem: String, Sendable, Equatable {
    case invalidMetadata
    case missingPayload
    case hashMismatch
    case invalidLibrary
}

struct LibraryRecoveryArtifact: Sendable, Equatable {
    let id: UUID
    let kind: LibraryRecoveryArtifactKind
    let reason: LibraryBackupReason
    let content: LibraryRecoveryArtifactContent
    let createdAt: Date
    let libraryURL: URL
    let byteCount: Int
    let sha256: String
}

struct LibraryRecoveryInspection: Sendable, Equatable {
    let artifact: LibraryRecoveryArtifact
    let problem: LibraryRecoveryArtifactProblem?

    var isVerified: Bool {
        problem == nil
    }

    var isRestorable: Bool {
        isVerified
            && artifact.kind == .backup
            && artifact.content == .currentLibrary
    }
}

struct LibraryRestorePreparation: Sendable, Equatable {
    let artifact: LibraryRecoveryArtifact
    let bytes: Data
}

struct LibraryPrimaryRestorePreparation: Sendable, Equatable {
    let restore: LibraryRestorePreparation
    let preservedPrimary: LibraryRecoveryArtifact?
}

struct LibraryStartOverPreparation: Sendable, Equatable {
    let quarantine: LibraryRecoveryArtifact
    let originalSHA256: String
    let emptyLibraryBytes: Data
}

enum LibraryBackupStoreError: LocalizedError, Equatable {
    case invalidRecoveryRoot
    case invalidArtifact
    case invalidMetadata
    case missingPayload
    case hashMismatch
    case invalidLibrary
    case notRestorable
    case noVerifiedBackup
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .invalidRecoveryRoot:
            String(localized: "The library recovery folder is not a safe directory.")
        case .invalidArtifact:
            String(localized: "The selected recovery artifact does not belong to this library.")
        case .invalidMetadata:
            String(localized: "The recovery artifact metadata is invalid.")
        case .missingPayload:
            String(localized: "The recovery artifact no longer contains a library file.")
        case .hashMismatch:
            String(localized: "The recovery artifact failed integrity verification.")
        case .invalidLibrary:
            String(localized: "Only a structurally valid, supported library can be stored as a last-known-good backup.")
        case .notRestorable:
            String(localized: "The selected artifact is preserved for migration or inspection and cannot replace the current library.")
        case .noVerifiedBackup:
            String(localized: "No verified library backup is available.")
        case .destinationExists:
            String(localized: "The recovery export destination already exists.")
        }
    }
}

/// Owns exact-byte metadata backups and corrupt-library quarantine artifacts.
///
/// Each artifact is assembled in a private sibling staging directory, synced,
/// and published with one rename. Preparing a restore only returns verified
/// bytes; the caller remains responsible for a separately coordinated primary
/// library replacement.
struct LibraryBackupStore {
    private struct ArtifactMetadata: Codable, Sendable {
        static let currentVersion = 2

        let version: Int
        let id: UUID
        let kind: LibraryRecoveryArtifactKind
        let reason: LibraryBackupReason
        let content: LibraryRecoveryArtifactContent
        let createdAt: Date
        let byteCount: Int
        let sha256: String
    }

    private static let payloadName = "library.json"
    private static let metadataName = "metadata.json"

    private let fileSystem: any FileSystem
    private let recoveryRoot: URL
    private let retentionLimit: Int
    private let now: () -> Date
    private let makeIdentifier: () -> UUID

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        recoveryRoot: URL,
        retentionLimit: Int = 5,
        now: @escaping () -> Date = Date.init,
        makeIdentifier: @escaping () -> UUID = UUID.init
    ) {
        precondition(retentionLimit > 0, "Backup retention must be positive")
        self.fileSystem = fileSystem
        self.recoveryRoot = recoveryRoot.standardizedFileURL
        self.retentionLimit = retentionLimit
        self.now = now
        self.makeIdentifier = makeIdentifier
    }

    func createBackup(
        of bytes: Data,
        reason: LibraryBackupReason
    ) throws -> LibraryRecoveryArtifact {
        let content = try classifyBackup(bytes, reason: reason)
        let artifact = try publish(
            bytes,
            kind: .backup,
            reason: reason,
            content: content,
            date: now(),
            id: makeIdentifier()
        )
        try pruneBackups()
        return artifact
    }

    /// Copies a primary into quarantine. The source is deliberately not moved
    /// or removed so recovery UI can preserve the original failure evidence.
    func quarantineFile(at primaryURL: URL) throws -> LibraryRecoveryArtifact {
        try quarantine(stableBytes(at: primaryURL))
    }

    func quarantine(_ bytes: Data) throws -> LibraryRecoveryArtifact {
        try publish(
            bytes,
            kind: .quarantine,
            reason: .corruptPrimary,
            content: .unvalidatedQuarantine,
            date: now(),
            id: makeIdentifier()
        )
    }

    func inspectArtifacts(
        kind: LibraryRecoveryArtifactKind? = nil
    ) throws -> [LibraryRecoveryInspection] {
        let kinds = kind.map { [$0] } ?? [.backup, .quarantine]
        var inspections: [LibraryRecoveryInspection] = []
        for artifactKind in kinds {
            let root = try kindRoot(artifactKind, create: false)
            guard fileSystem.fileExists(at: root) else { continue }
            try requireDirectory(root)
            for bundleURL in try fileSystem.contentsOfDirectory(at: root) {
                guard !bundleURL.lastPathComponent.hasPrefix(".staging-") else {
                    continue
                }
                guard
                    let inspection = try inspectBundle(
                        at: bundleURL,
                        expectedKind: artifactKind
                    )
                else {
                    continue
                }
                inspections.append(inspection)
            }
        }
        return inspections.sorted {
            if $0.artifact.createdAt != $1.artifact.createdAt {
                return $0.artifact.createdAt > $1.artifact.createdAt
            }
            return $0.artifact.id.uuidString > $1.artifact.id.uuidString
        }
    }

    func prepareRestore(
        from artifact: LibraryRecoveryArtifact
    ) throws -> LibraryRestorePreparation {
        guard
            artifact.kind == .backup,
            artifact.content == .currentLibrary
        else {
            throw LibraryBackupStoreError.notRestorable
        }
        let verified = try verifiedArtifact(
            at: artifact.libraryURL.deletingLastPathComponent(),
            expectedKind: .backup,
            expectedID: artifact.id
        )
        return LibraryRestorePreparation(
            artifact: verified.artifact,
            bytes: verified.bytes
        )
    }

    func prepareLatestBackupRestore() throws -> LibraryRestorePreparation {
        for inspection in try inspectArtifacts(kind: .backup)
        where inspection.isRestorable {
            do {
                return try prepareRestore(from: inspection.artifact)
            } catch {
                continue
            }
        }
        throw LibraryBackupStoreError.noVerifiedBackup
    }

    /// Captures the exact, stable primary bytes for a pre-save backup. Invalid,
    /// legacy, and unsupported documents are rejected rather than mislabeled as
    /// last known good.
    func backupCurrentPrimary(
        at primaryURL: URL,
        reason: LibraryBackupReason
    ) throws -> LibraryRecoveryArtifact {
        try createBackup(
            of: stableBytes(at: primaryURL),
            reason: reason
        )
    }

    /// Verifies the restore source first, then preserves the exact current
    /// primary without replacing or deleting it. Valid current bytes become a
    /// backup; every other readable primary is quarantined.
    func preparePrimaryRestore(
        from artifact: LibraryRecoveryArtifact,
        replacing primaryURL: URL
    ) throws -> LibraryPrimaryRestorePreparation {
        let restore = try prepareRestore(from: artifact)
        let preservedPrimary: LibraryRecoveryArtifact?
        if fileSystem.fileExists(at: primaryURL) {
            let bytes = try stableBytes(at: primaryURL)
            if (try? LibraryPersistence.decodeCurrentDocument(from: bytes)) != nil {
                preservedPrimary = try createBackup(
                    of: bytes,
                    reason: .destructiveRewrite
                )
            } else {
                preservedPrimary = try quarantine(bytes)
            }
        } else {
            preservedPrimary = nil
        }
        return LibraryPrimaryRestorePreparation(
            restore: restore,
            preservedPrimary: preservedPrimary
        )
    }

    /// Preserves a failed primary exactly and prepares an empty supported v2
    /// document. The caller must still obtain destructive authorization and
    /// perform the primary replacement transaction.
    func prepareQuarantineAndStartOver(
        primaryAt primaryURL: URL
    ) throws -> LibraryStartOverPreparation {
        let bytes = try stableBytes(at: primaryURL)
        let artifact = try quarantine(bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let emptyLibraryBytes = try encoder.encode(
            LibraryDocument(
                revision: .initial,
                applications: []
            )
        )
        return LibraryStartOverPreparation(
            quarantine: artifact,
            originalSHA256: LibraryPersistence.sha256(bytes),
            emptyLibraryBytes: emptyLibraryBytes
        )
    }

    @discardableResult
    func export(
        _ artifact: LibraryRecoveryArtifact,
        to destinationURL: URL
    ) throws -> URL {
        let verified = try verifiedArtifact(
            at: artifact.libraryURL.deletingLastPathComponent(),
            expectedKind: artifact.kind,
            expectedID: artifact.id
        )
        let destination = destinationURL.standardizedFileURL
        guard !fileSystem.fileExists(at: destination) else {
            throw LibraryBackupStoreError.destinationExists
        }
        let parent = destination.deletingLastPathComponent()
        if fileSystem.fileExists(at: parent) {
            try requireDirectory(parent)
        } else {
            try fileSystem.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try requireDirectory(parent)
            try fileSystem.setPOSIXPermissions(0o700, at: parent)
        }
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(makeIdentifier().uuidString).tmp",
            isDirectory: false
        )
        do {
            try fileSystem.writeData(verified.bytes, to: temporary)
            try fileSystem.setPOSIXPermissions(0o600, at: temporary)
            try fileSystem.synchronize(at: temporary)
            try fileSystem.moveItem(at: temporary, to: destination)
            try fileSystem.synchronize(at: parent)
        } catch {
            if fileSystem.fileExists(at: temporary) {
                try? fileSystem.removeItem(at: temporary)
            }
            throw error
        }
        guard try fileSystem.readData(at: destination) == verified.bytes else {
            throw LibraryBackupStoreError.hashMismatch
        }
        return destination
    }

    private func publish(
        _ bytes: Data,
        kind: LibraryRecoveryArtifactKind,
        reason: LibraryBackupReason,
        content: LibraryRecoveryArtifactContent,
        date: Date,
        id: UUID
    ) throws -> LibraryRecoveryArtifact {
        let root = try kindRoot(kind, create: true)
        let name = bundleName(kind: kind, date: date, id: id)
        let finalBundle = root.appendingPathComponent(name, isDirectory: true)
        guard !fileSystem.fileExists(at: finalBundle) else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let staging = root.appendingPathComponent(
            ".staging-\(id.uuidString.lowercased())",
            isDirectory: true
        )
        guard !fileSystem.fileExists(at: staging) else {
            throw LibraryBackupStoreError.invalidArtifact
        }

        let metadata = ArtifactMetadata(
            version: ArtifactMetadata.currentVersion,
            id: id,
            kind: kind,
            reason: reason,
            content: content,
            createdAt: date,
            byteCount: bytes.count,
            sha256: LibraryPersistence.sha256(bytes)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataBytes = try encoder.encode(metadata)
        let payloadURL = staging.appendingPathComponent(
            Self.payloadName,
            isDirectory: false
        )
        let metadataURL = staging.appendingPathComponent(
            Self.metadataName,
            isDirectory: false
        )

        do {
            try fileSystem.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            try fileSystem.setPOSIXPermissions(0o700, at: staging)
            try fileSystem.writeData(bytes, to: payloadURL)
            try fileSystem.setPOSIXPermissions(0o600, at: payloadURL)
            try fileSystem.writeData(metadataBytes, to: metadataURL)
            try fileSystem.setPOSIXPermissions(0o600, at: metadataURL)
            try fileSystem.synchronize(at: payloadURL)
            try fileSystem.synchronize(at: metadataURL)
            try fileSystem.synchronize(at: staging)
            try fileSystem.moveItem(at: staging, to: finalBundle)
            try fileSystem.synchronize(at: root)
        } catch {
            if fileSystem.fileExists(at: staging) {
                try? fileSystem.removeItem(at: staging)
            }
            throw error
        }

        let verified = try verifiedArtifact(
            at: finalBundle,
            expectedKind: kind,
            expectedID: id
        )
        return verified.artifact
    }

    private func inspectBundle(
        at bundleURL: URL,
        expectedKind: LibraryRecoveryArtifactKind
    ) throws -> LibraryRecoveryInspection? {
        guard
            let metadata = try? readMetadata(at: bundleURL),
            metadata.kind == expectedKind,
            bundleURL.lastPathComponent == bundleName(
                kind: metadata.kind,
                date: metadata.createdAt,
                id: metadata.id
            )
        else {
            return nil
        }
        let artifact = makeArtifact(metadata: metadata, bundleURL: bundleURL)
        guard (try? hasExpectedBundleContents(bundleURL)) == true else {
            return LibraryRecoveryInspection(
                artifact: artifact,
                problem: .invalidMetadata
            )
        }
        let payload = artifact.libraryURL
        guard fileSystem.fileExists(at: payload) else {
            return LibraryRecoveryInspection(
                artifact: artifact,
                problem: .missingPayload
            )
        }
        guard
            (try? fileSystem.attributesOfItem(at: payload).kind) == .regularFile,
            let bytes = try? fileSystem.readData(at: payload)
        else {
            return LibraryRecoveryInspection(
                artifact: artifact,
                problem: .missingPayload
            )
        }
        let matches = bytes.count == metadata.byteCount
            && LibraryPersistence.sha256(bytes) == metadata.sha256
        let problem: LibraryRecoveryArtifactProblem?
        if !matches {
            problem = .hashMismatch
        } else if !isValidContent(bytes, metadata: metadata) {
            problem = .invalidLibrary
        } else {
            problem = nil
        }
        return LibraryRecoveryInspection(
            artifact: artifact,
            problem: problem
        )
    }

    private func verifiedArtifact(
        at bundleURL: URL,
        expectedKind: LibraryRecoveryArtifactKind,
        expectedID: UUID
    ) throws -> (
        artifact: LibraryRecoveryArtifact,
        bytes: Data
    ) {
        try requireOwnedBundle(
            bundleURL,
            expectedKind: expectedKind
        )
        let metadata = try readMetadata(at: bundleURL)
        guard
            metadata.version == ArtifactMetadata.currentVersion,
            metadata.kind == expectedKind,
            metadata.id == expectedID,
            bundleURL.lastPathComponent == bundleName(
                kind: metadata.kind,
                date: metadata.createdAt,
                id: metadata.id
            )
        else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        guard try hasExpectedBundleContents(bundleURL) else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        let artifact = makeArtifact(metadata: metadata, bundleURL: bundleURL)
        guard fileSystem.fileExists(at: artifact.libraryURL) else {
            throw LibraryBackupStoreError.missingPayload
        }
        let attributes = try fileSystem.attributesOfItem(at: artifact.libraryURL)
        guard attributes.kind == .regularFile else {
            throw LibraryBackupStoreError.missingPayload
        }
        let bytes = try fileSystem.readData(at: artifact.libraryURL)
        guard
            bytes.count == metadata.byteCount,
            LibraryPersistence.sha256(bytes) == metadata.sha256
        else {
            throw LibraryBackupStoreError.hashMismatch
        }
        guard isValidContent(bytes, metadata: metadata) else {
            throw LibraryBackupStoreError.invalidLibrary
        }
        return (artifact, bytes)
    }

    private func readMetadata(at bundleURL: URL) throws -> ArtifactMetadata {
        let attributes = try fileSystem.attributesOfItem(at: bundleURL)
        guard attributes.kind == .directory else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        let metadataURL = bundleURL.appendingPathComponent(
            Self.metadataName,
            isDirectory: false
        )
        guard fileSystem.fileExists(at: metadataURL) else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        let metadataAttributes = try fileSystem.attributesOfItem(at: metadataURL)
        guard metadataAttributes.kind == .regularFile else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        do {
            let metadata = try JSONDecoder().decode(
                ArtifactMetadata.self,
                from: fileSystem.readData(at: metadataURL)
            )
            guard metadata.version == ArtifactMetadata.currentVersion else {
                throw LibraryBackupStoreError.invalidMetadata
            }
            return metadata
        } catch let error as LibraryBackupStoreError {
            throw error
        } catch {
            throw LibraryBackupStoreError.invalidMetadata
        }
    }

    private func makeArtifact(
        metadata: ArtifactMetadata,
        bundleURL: URL
    ) -> LibraryRecoveryArtifact {
        LibraryRecoveryArtifact(
            id: metadata.id,
            kind: metadata.kind,
            reason: metadata.reason,
            content: metadata.content,
            createdAt: metadata.createdAt,
            libraryURL: bundleURL.appendingPathComponent(
                Self.payloadName,
                isDirectory: false
            ),
            byteCount: metadata.byteCount,
            sha256: metadata.sha256
        )
    }

    private func pruneBackups() throws {
        let backupRoot = try kindRoot(.backup, create: true)
        let bundles = try fileSystem.contentsOfDirectory(at: backupRoot)
            .compactMap { bundleURL -> (URL, ArtifactMetadata)? in
                guard
                    !bundleURL.lastPathComponent.hasPrefix(".staging-"),
                    let metadata = try? readMetadata(at: bundleURL),
                    metadata.kind == .backup,
                    bundleURL.lastPathComponent == bundleName(
                        kind: metadata.kind,
                        date: metadata.createdAt,
                        id: metadata.id
                    ),
                    let inspection = try? inspectBundle(
                        at: bundleURL,
                        expectedKind: .backup
                    ),
                    inspection.isVerified
                else {
                    return nil
                }
                return (bundleURL, metadata)
            }
            .sorted {
                if $0.1.createdAt != $1.1.createdAt {
                    return $0.1.createdAt > $1.1.createdAt
                }
                return $0.1.id.uuidString > $1.1.id.uuidString
            }
        for expired in bundles.dropFirst(retentionLimit) {
            try requireOwnedBundle(expired.0, expectedKind: .backup)
            try fileSystem.removeItem(at: expired.0)
        }
        try fileSystem.synchronize(at: backupRoot)
    }

    private func bundleName(
        kind: LibraryRecoveryArtifactKind,
        date: Date,
        id: UUID
    ) -> String {
        let timestamp = Int64(
            (date.timeIntervalSince1970 * 1_000).rounded(.down)
        )
        let suffix = kind == .backup ? "backup" : "quarantine"
        return "\(timestamp)-\(id.uuidString.lowercased()).\(suffix)"
    }

    private func requireOwnedBundle(
        _ bundleURL: URL,
        expectedKind: LibraryRecoveryArtifactKind
    ) throws {
        let expectedRoot = try kindRoot(expectedKind, create: false)
        let suppliedParent = bundleURL.standardizedFileURL
            .deletingLastPathComponent()
        guard suppliedParent == expectedRoot.standardizedFileURL else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let attributes = try fileSystem.attributesOfItem(at: bundleURL)
        guard attributes.kind == .directory else {
            throw LibraryBackupStoreError.invalidArtifact
        }
    }

    private func hasExpectedBundleContents(_ bundleURL: URL) throws -> Bool {
        let contents = try fileSystem.contentsOfDirectory(at: bundleURL)
        guard contents.count == 2 else { return false }
        return Set(contents.map(\.lastPathComponent))
            == [Self.payloadName, Self.metadataName]
    }

    private func kindRoot(
        _ kind: LibraryRecoveryArtifactKind,
        create: Bool
    ) throws -> URL {
        guard recoveryRoot.isFileURL, recoveryRoot.path.hasPrefix("/") else {
            throw LibraryBackupStoreError.invalidRecoveryRoot
        }
        if create {
            try ensureDirectory(recoveryRoot)
        } else if fileSystem.fileExists(at: recoveryRoot) {
            try requireDirectory(recoveryRoot)
        }
        let component = kind == .backup ? "Backups" : "Quarantine"
        let root = recoveryRoot.appendingPathComponent(component, isDirectory: true)
        if create {
            try ensureDirectory(root)
        }
        return root
    }

    private func ensureDirectory(_ url: URL) throws {
        if fileSystem.fileExists(at: url) {
            try requireDirectory(url)
        } else {
            try fileSystem.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            try requireDirectory(url)
        }
        try fileSystem.setPOSIXPermissions(0o700, at: url)
    }

    private func requireDirectory(_ url: URL) throws {
        let attributes = try fileSystem.attributesOfItem(at: url)
        guard attributes.kind == .directory else {
            throw LibraryBackupStoreError.invalidRecoveryRoot
        }
    }

    private func classifyBackup(
        _ bytes: Data,
        reason: LibraryBackupReason
    ) throws -> LibraryRecoveryArtifactContent {
        do {
            switch try LibraryPersistence.decodeLibrary(from: bytes) {
            case .current:
                return .currentLibrary
            case .migrationRequired where reason == .migration:
                return .legacyMigrationSource
            case .migrationRequired:
                throw LibraryBackupStoreError.invalidLibrary
            }
        } catch let error as LibraryBackupStoreError {
            throw error
        } catch {
            throw LibraryBackupStoreError.invalidLibrary
        }
    }

    private func isValidContent(
        _ bytes: Data,
        metadata: ArtifactMetadata
    ) -> Bool {
        switch (metadata.kind, metadata.content) {
        case (.quarantine, .unvalidatedQuarantine):
            return true
        case (.backup, .currentLibrary):
            return (try? LibraryPersistence.decodeCurrentDocument(from: bytes))
                != nil
        case (.backup, .legacyMigrationSource):
            guard metadata.reason == .migration else { return false }
            guard
                case .migrationRequired = try? LibraryPersistence.decodeLibrary(
                    from: bytes
                )
            else {
                return false
            }
            return true
        default:
            return false
        }
    }

    private func stableBytes(at url: URL) throws -> Data {
        let before = try fileSystem.attributesOfItem(at: url)
        guard before.kind == .regularFile else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let bytes = try fileSystem.readData(at: url)
        let middle = try fileSystem.attributesOfItem(at: url)
        guard
            middle.kind == .regularFile,
            before.identity == middle.identity,
            before.size == middle.size,
            middle.size == UInt64(bytes.count)
        else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let confirmation = try fileSystem.readData(at: url)
        let after = try fileSystem.attributesOfItem(at: url)
        guard
            after.kind == .regularFile,
            before.identity == after.identity,
            before.size == after.size,
            after.size == UInt64(confirmation.count),
            bytes == confirmation
        else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        return bytes
    }
}
