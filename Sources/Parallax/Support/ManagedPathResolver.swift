import Darwin
import Foundation

struct ManagedPathResolver: Sendable {
    let fileSystem: any FileSystem
    var enrollmentStore: StorageVolumeEnrollmentStore?

    private let mountsDirectory: URL
    private let mountCheck: @Sendable (URL) throws -> Bool

    init(
        fileSystem: any FileSystem,
        enrollmentStore: StorageVolumeEnrollmentStore? = nil,
        mountsDirectory: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        mountCheck: @escaping @Sendable (URL) throws -> Bool = Self.isMountPoint
    ) {
        self.fileSystem = fileSystem
        self.enrollmentStore = enrollmentStore
        self.mountsDirectory = mountsDirectory
        self.mountCheck = mountCheck
    }

    static func profileRootURL(
        baseRootURL: URL,
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> URL {
        let applicationComponent = ManagedStorageComponent(
            uuid: applicationStorageID
        )
        let profileComponent = ManagedStorageComponent(
            uuid: profileStorageID
        )
        return baseRootURL
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(
                applicationComponent.rawValue,
                isDirectory: true
            )
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(
                profileComponent.rawValue,
                isDirectory: true
            )
    }

    func resolveApplication(
        configuredBaseRoot: String,
        applicationStorageID: UUID
    ) throws -> ResolvedApplicationStoragePaths {
        // A profile resolution exercises the same canonical containment checks
        // for every fixed namespace without deriving any component from a
        // visible name. The sentinel is not persisted or published.
        let sentinelProfileID = UUID(
            uuid: (
                0, 0, 0, 0,
                0, 0,
                0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            )
        )
        let profilePaths = try resolve(
            configuredBaseRoot: configuredBaseRoot,
            applicationStorageID: applicationStorageID,
            profileStorageID: sentinelProfileID
        )
        let profileNamespace = profilePaths.profileRoot.url
            .deletingLastPathComponent()
        let applicationRootURL = profileNamespace
            .deletingLastPathComponent()
        let applicationArchiveRootURL = profilePaths.archiveRoot.url
            .deletingLastPathComponent()
        let context = profilePaths.profileRoot.validationContext
        let namespaceRoot = context.canonicalBaseRootURL
            .appendingPathComponent(".parallax", isDirectory: true)

        return ResolvedApplicationStoragePaths(
            applicationRoot: ManagedApplicationRootPath(
                url: applicationRootURL,
                validationContext: context
            ),
            applicationArchiveRoot: ManagedApplicationArchiveRootPath(
                url: applicationArchiveRootURL,
                validationContext: context
            ),
            canonicalBaseRootURL: context.canonicalBaseRootURL,
            namespaceRoot: namespaceRoot,
            validationContext: context
        )
    }

    func resolve(
        configuredBaseRoot: String,
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) throws -> ResolvedProfilePaths {
        let rootURL = try validatedAbsoluteFileURL(
            configuredBaseRoot,
            emptyCode: .emptyBaseRoot,
            relativeCode: .relativeBaseRoot,
            invalidCode: .invalidBaseRoot
        )
        return try resolve(
            validatedBaseRootURL: rootURL,
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID
        )
    }

    func resolve(
        baseRootURL: URL,
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) throws -> ResolvedProfilePaths {
        guard baseRootURL.isFileURL else {
            throw ManagedPathError(.nonFileBaseRoot, path: baseRootURL.absoluteString)
        }
        let rootURL = try validatedAbsoluteFileURL(
            baseRootURL.path,
            emptyCode: .emptyBaseRoot,
            relativeCode: .relativeBaseRoot,
            invalidCode: .invalidBaseRoot
        )
        return try resolve(
            validatedBaseRootURL: rootURL,
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID
        )
    }

    func resolveExternalPath(_ configuredPath: String) throws -> ExternalIsolationPath {
        let requestedURL = try validatedAbsoluteFileURL(
            configuredPath,
            emptyCode: .invalidExternalPath,
            relativeCode: .invalidExternalPath,
            invalidCode: .invalidExternalPath
        )
        let resolution = try canonicalDirectoryResolution(
            for: requestedURL,
            targetError: .externalPathNotDirectory,
            unavailableError: .invalidExternalPath
        )
        return ExternalIsolationPath(
            requestedURL: requestedURL,
            canonicalURL: resolution.url
        )
    }

    /// Revalidates the captured root identity and canonical containment directly
    /// before a managed mutation. There remains a narrow validation-to-operation
    /// race until FS-001 moves mutations to descriptor-relative filesystem APIs.
    func revalidateForMutation(_ path: any ManagedMutationPath) throws -> URL {
        let context = path.validationContext
        let currentRoot = try canonicalDirectoryResolution(
            for: context.configuredBaseRootURL,
            targetError: .baseRootNotDirectory,
            unavailableError: .baseRootUnavailable
        )
        try validateBaseRootAvailability(context.configuredBaseRootURL, resolution: currentRoot)
        if currentRoot.identityAnchorURL.path != currentRoot.url.path,
            let applicationID = applicationStorageID(for: path) {
            try enrollmentStore?.validateMissingRoot(context.configuredBaseRootURL, applicationStorageID: applicationID)
        }
        let currentAnchor: FileSystemItemAttributes
        do {
            currentAnchor = try fileSystem.attributesOfItem(at: context.identityAnchorURL)
        } catch {
            throw ManagedPathError(.rootIdentityChanged, path: context.identityAnchorURL.path)
        }
        guard
            currentAnchor.kind == .directory,
            currentAnchor.identity == context.identityAnchor
        else {
            throw ManagedPathError(.rootIdentityChanged, path: context.identityAnchorURL.path)
        }


        guard
            normalizedCanonicalURL(currentRoot.url).path
                == context.canonicalBaseRootURL.path
        else {
            throw ManagedPathError(.rootIdentityChanged, path: context.configuredBaseRootURL.path)
        }

        let currentTarget = try canonicalDirectoryResolution(
            for: path.url,
            targetError: .targetNotDirectory,
            unavailableError: .baseRootUnavailable
        )
        let configuredComponents = context.canonicalBaseRootURL.pathComponents
        let pathComponents = path.url.pathComponents
        guard
            pathComponents.count >= configuredComponents.count,
            Array(pathComponents.prefix(configuredComponents.count)) == configuredComponents
        else {
            throw ManagedPathError(.outsideManagedRoot, path: path.url.path)
        }
        var expectedCanonicalTarget = context.canonicalBaseRootURL
        for component in pathComponents.dropFirst(configuredComponents.count) {
            expectedCanonicalTarget.appendPathComponent(component, isDirectory: true)
        }
        let namespaceRoot = context.canonicalBaseRootURL
            .appendingPathComponent(".parallax", isDirectory: true)
        let normalizedCurrentTarget = normalizedCanonicalURL(currentTarget.url)
        guard
            contains(normalizedCurrentTarget, within: namespaceRoot),
            normalizedCurrentTarget.path == expectedCanonicalTarget.path
        else {
            throw ManagedPathError(
                .outsideManagedRoot,
                path: normalizedCurrentTarget.path
            )
        }
        try validateOwnedDirectories(to: path.url, baseRoot: context.canonicalBaseRootURL)
        return path.url
    }

    private func resolve(
        validatedBaseRootURL: URL,
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) throws -> ResolvedProfilePaths {
        let applicationComponent = ManagedStorageComponent(uuid: applicationStorageID)
        let profileComponent = ManagedStorageComponent(uuid: profileStorageID)
        let rootResolution = try canonicalDirectoryResolution(
            for: validatedBaseRootURL,
            targetError: .baseRootNotDirectory,
            unavailableError: .baseRootUnavailable
        )
        try validateBaseRootAvailability(validatedBaseRootURL, resolution: rootResolution)
        if rootResolution.identityAnchorURL.path != rootResolution.url.path {
            try enrollmentStore?.validateMissingRoot(validatedBaseRootURL, applicationStorageID: applicationStorageID)
        }
        guard let anchorIdentity = rootResolution.identityAnchor else {
            throw ManagedPathError(.baseRootUnavailable, path: validatedBaseRootURL.path)
        }

        let canonicalBaseRoot = normalizedCanonicalURL(rootResolution.url)
        let canonicalNamespaceRoot = canonicalBaseRoot
            .appendingPathComponent(".parallax", isDirectory: true)
        let namespaceRoot = canonicalNamespaceRoot
        let profileRootURL = Self.profileRootURL(
            baseRootURL: canonicalBaseRoot,
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID
        )
        let archiveRootURL = canonicalNamespaceRoot
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent(applicationComponent.rawValue, isDirectory: true)
            .appendingPathComponent(profileComponent.rawValue, isDirectory: true)

        let canonicalProfileRootURL = Self.profileRootURL(
            baseRootURL: canonicalBaseRoot,
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID
        )
        let canonicalArchiveRootURL = canonicalNamespaceRoot
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent(applicationComponent.rawValue, isDirectory: true)
            .appendingPathComponent(profileComponent.rawValue, isDirectory: true)
        let userDataURL = profileRootURL
            .appendingPathComponent("UserData", isDirectory: true)
        let codexHomeURL = profileRootURL
            .appendingPathComponent("CodexHome", isDirectory: true)
        let claudeConfigURL = userDataURL
            .appendingPathComponent("ClaudeConfig", isDirectory: true)
        let canonicalUserDataURL = canonicalProfileRootURL
            .appendingPathComponent("UserData", isDirectory: true)
        let canonicalCodexHomeURL = canonicalProfileRootURL
            .appendingPathComponent("CodexHome", isDirectory: true)
        let canonicalClaudeConfigURL = canonicalUserDataURL
            .appendingPathComponent("ClaudeConfig", isDirectory: true)
        _ = try validateManagedTarget(
            profileRootURL,
            baseRoot: canonicalBaseRoot,
            expectedCanonicalTarget: canonicalProfileRootURL
        )
        _ = try validateManagedTarget(
            archiveRootURL,
            baseRoot: canonicalBaseRoot,
            expectedCanonicalTarget: canonicalArchiveRootURL
        )
        _ = try validateManagedTarget(
            userDataURL,
            baseRoot: canonicalBaseRoot,
            expectedCanonicalTarget: canonicalUserDataURL
        )
        _ = try validateManagedTarget(
            codexHomeURL,
            baseRoot: canonicalBaseRoot,
            expectedCanonicalTarget: canonicalCodexHomeURL
        )
        _ = try validateManagedTarget(
            claudeConfigURL,
            baseRoot: canonicalBaseRoot,
            expectedCanonicalTarget: canonicalClaudeConfigURL
        )
        _ = try validateManagedTarget(
            namespaceRoot.appendingPathComponent("Transactions", isDirectory: true),
            baseRoot: canonicalBaseRoot,
            expectedCanonicalTarget: canonicalNamespaceRoot
                .appendingPathComponent("Transactions", isDirectory: true)
        )

        let context = ManagedPathValidationContext(
            configuredBaseRootURL: validatedBaseRootURL,
            canonicalBaseRootURL: canonicalBaseRoot,
            identityAnchorURL: rootResolution.identityAnchorURL,
            identityAnchor: anchorIdentity
        )
        return ResolvedProfilePaths(
            profileRoot: ManagedProfileRootPath(
                url: profileRootURL,
                validationContext: context
            ),
            userData: ManagedUserDataPath(
                url: userDataURL,
                validationContext: context
            ),
            codexHome: ManagedCodexHomePath(
                url: codexHomeURL,
                validationContext: context
            ),
            claudeConfig: ManagedClaudeConfigPath(
                url: claudeConfigURL,
                validationContext: context
            ),
            archiveRoot: ManagedArchiveRootPath(
                url: archiveRootURL,
                validationContext: context
            ),
            namespaceRoot: namespaceRoot,
            validationContext: context
        )
    }

    private func validateManagedTarget(
        _ target: URL,
        baseRoot: URL,
        expectedCanonicalTarget: URL
    ) throws -> URL {
        let resolution = try canonicalDirectoryResolution(
            for: target,
            targetError: .targetNotDirectory,
            unavailableError: .baseRootUnavailable
        )
        let normalized = normalizedCanonicalURL(resolution.url)
        guard
            contains(normalized, within: baseRoot),
            normalized.path == expectedCanonicalTarget.path
        else {
            throw ManagedPathError(.outsideManagedRoot, path: normalized.path)
        }
        try validateOwnedDirectories(to: target, baseRoot: baseRoot)
        return normalized
    }

    private func validateOwnedDirectories(to target: URL, baseRoot: URL) throws {
        var directory = baseRoot
        for component in target.pathComponents.dropFirst(baseRoot.pathComponents.count) {
            // Provider data may have its own modes; these checks cover the Parallax namespace.
            if ["UserData", "CodexHome", "FirefoxProfile", "Extensions"].contains(component) { break }
            directory.appendPathComponent(component, isDirectory: true)
            let attributes: FileSystemItemAttributes
            do {
                attributes = try fileSystem.attributesOfItem(at: directory)
            } catch {
                if isNotFound(error) { return }
                throw error
            }
            guard attributes.kind == .directory,
                  attributes.ownerID == geteuid()
            else {
                throw SecureManagedFileSystemError.unsafeDirectory(path: directory.path)
            }
            try SecureManagedFileSystem.validateOwnedDirectory(at: directory, expectedIdentity: attributes.identity)
        }
    }

    private func validateBaseRootAvailability(_ base: URL, resolution: DirectoryResolution) throws {
        guard resolution.identityAnchorURL.path != resolution.url.path else { return }
        let components = base.pathComponents
        let mounts = mountsDirectory.pathComponents
        guard components.starts(with: mounts), components.count > mounts.count else { return }
        let volume = mountsDirectory.appendingPathComponent(components[mounts.count], isDirectory: true)
        do {
            guard try mountCheck(volume) else {
                throw ManagedPathError(.baseRootUnavailable, path: base.path)
            }
        } catch {
            throw ManagedPathError(.baseRootUnavailable, path: base.path)
        }
    }

    static func isMountPoint(_ url: URL) throws -> Bool {
        var status = statfs()
        guard statfs(url.path, &status) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let mountedPath = withUnsafePointer(to: &status.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return URL(fileURLWithPath: mountedPath).standardizedFileURL.path == url.standardizedFileURL.path
    }

    private func validatedAbsoluteFileURL(
        _ originalPath: String,
        emptyCode: ManagedPathError.Code,
        relativeCode: ManagedPathError.Code,
        invalidCode: ManagedPathError.Code
    ) throws -> URL {
        guard !originalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManagedPathError(emptyCode, path: originalPath)
        }
        guard originalPath.hasPrefix("/") else {
            throw ManagedPathError(relativeCode, path: originalPath)
        }
        guard
            !originalPath.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw ManagedPathError(invalidCode, path: originalPath)
        }

        let components = originalPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        if components.contains(where: { $0 == "." }) {
            throw ManagedPathError(.dotPathComponent, path: originalPath)
        }
        if components.contains(where: { $0 == ".." }) {
            throw ManagedPathError(.dotDotPathComponent, path: originalPath)
        }
        return URL(fileURLWithPath: originalPath, isDirectory: true).standardizedFileURL
    }

    struct DirectoryResolution {
        let url: URL
        let identityAnchorURL: URL
        let identityAnchor: FileSystemObjectIdentity?
    }

    private func contains(_ target: URL, within root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

}
