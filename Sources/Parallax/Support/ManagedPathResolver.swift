import Foundation

struct ManagedPathError: LocalizedError, Equatable {
    enum Code: String, Sendable {
        case emptyBaseRoot
        case relativeBaseRoot
        case nonFileBaseRoot
        case dotPathComponent
        case dotDotPathComponent
        case invalidBaseRoot
        case baseRootNotDirectory
        case ancestorNotDirectory
        case targetNotDirectory
        case baseRootUnavailable
        case outsideManagedRoot
        case rootIdentityChanged
        case invalidStorageComponent
        case reservedStorageComponent
        case invalidExternalPath
        case externalPathNotDirectory
    }

    let code: Code
    let path: String?

    init(_ code: Code, path: String? = nil) {
        self.code = code
        self.path = path
    }

    var errorDescription: String? {
        switch code {
        case .emptyBaseRoot:
            String(localized: "Choose an absolute folder for managed profile storage.")
        case .relativeBaseRoot:
            String(localized: "The managed profile storage folder must be an absolute path.")
        case .nonFileBaseRoot:
            String(localized: "The managed profile storage location must be a local or mounted file URL.")
        case .dotPathComponent:
            String(localized: "The managed profile storage path cannot contain a “.” component.")
        case .dotDotPathComponent:
            String(localized: "The managed profile storage path cannot contain a “..” component.")
        case .invalidBaseRoot:
            String(localized: "The managed profile storage path is invalid.")
        case .baseRootNotDirectory:
            String(localized: "The configured managed profile storage path is a file, not a folder.")
        case .ancestorNotDirectory:
            String(localized: "A parent of the managed profile storage path is a file, not a folder.")
        case .targetNotDirectory:
            String(localized: "The managed profile data target is a file, not a folder.")
        case .baseRootUnavailable:
            String(localized: "The managed profile storage volume is unavailable. Reconnect it before continuing.")
        case .outsideManagedRoot:
            String(localized: "The managed profile path resolves outside its approved storage folder.")
        case .rootIdentityChanged:
            String(localized: "The managed profile storage folder changed after it was inspected. Try the operation again.")
        case .invalidStorageComponent:
            String(localized: "The storage identifier is invalid.")
        case .reservedStorageComponent:
            String(localized: "The storage identifier uses a reserved Parallax directory name.")
        case .invalidExternalPath:
            String(localized: "The external isolation folder must be an absolute file path.")
        case .externalPathNotDirectory:
            String(localized: "The external isolation path is a file, not a folder.")
        }
    }
}

struct ManagedStorageComponent: Sendable, Hashable {
    static let reservedNamespaceNames = [
        ".parallax",
        "Applications",
        "Profiles",
        "Archives",
        "UserData",
        "CodexHome",
        "Transactions",
    ]

    let rawValue: String

    init(validating rawValue: String) throws {
        let normalized = rawValue
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        let reserved = Set(
            Self.reservedNamespaceNames.map {
                $0.precomposedStringWithCompatibilityMapping.lowercased()
            }
        )
        if reserved.contains(normalized) {
            throw ManagedPathError(.reservedStorageComponent, path: rawValue)
        }

        guard
            rawValue.count == 36,
            rawValue == rawValue.lowercased(),
            let uuid = UUID(uuidString: rawValue),
            uuid.uuidString.lowercased() == rawValue
        else {
            throw ManagedPathError(.invalidStorageComponent, path: rawValue)
        }
        self.rawValue = rawValue
    }

    init(uuid: UUID) {
        rawValue = uuid.uuidString.lowercased()
    }
}

struct ManagedPathValidationContext: Sendable, Equatable {
    let configuredBaseRootURL: URL
    let canonicalBaseRootURL: URL
    let identityAnchorURL: URL
    let identityAnchor: FileSystemObjectIdentity
}

protocol ManagedMutationPath: Sendable {
    var url: URL { get }
    var validationContext: ManagedPathValidationContext { get }
}

struct ManagedProfileRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedApplicationRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedApplicationArchiveRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedUserDataPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedCodexHomePath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedArchiveRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext

    func entry(
        timestamp: Date = Date(),
        nonce: UUID = UUID()
    ) -> ManagedArchiveEntryPath {
        let milliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
        let name = "\(milliseconds)-\(nonce.uuidString.lowercased())"
        return ManagedArchiveEntryPath(
            url: url.appendingPathComponent(name, isDirectory: true),
            validationContext: validationContext
        )
    }
}

struct ManagedArchiveEntryPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedStagingRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ExternalIsolationPath: Sendable, Equatable {
    let url: URL
}

struct ResolvedProfilePaths: Sendable, Equatable {
    let profileRoot: ManagedProfileRootPath
    let userData: ManagedUserDataPath
    let codexHome: ManagedCodexHomePath
    let archiveRoot: ManagedArchiveRootPath

    private let namespaceRoot: URL
    private let validationContext: ManagedPathValidationContext

    init(
        profileRoot: ManagedProfileRootPath,
        userData: ManagedUserDataPath,
        codexHome: ManagedCodexHomePath,
        archiveRoot: ManagedArchiveRootPath,
        namespaceRoot: URL,
        validationContext: ManagedPathValidationContext
    ) {
        self.profileRoot = profileRoot
        self.userData = userData
        self.codexHome = codexHome
        self.archiveRoot = archiveRoot
        self.namespaceRoot = namespaceRoot
        self.validationContext = validationContext
    }

    func stagingRoot(transactionID: UUID) throws -> ManagedStagingRootPath {
        let component = ManagedStorageComponent(uuid: transactionID)
        return ManagedStagingRootPath(
            url: namespaceRoot
                .appendingPathComponent("Transactions", isDirectory: true)
                .appendingPathComponent(component.rawValue, isDirectory: true),
            validationContext: validationContext
        )
    }

    func archiveEntry(
        timestamp: Date = Date(),
        nonce: UUID = UUID()
    ) -> ManagedArchiveEntryPath {
        archiveRoot.entry(timestamp: timestamp, nonce: nonce)
    }
}

struct ResolvedApplicationStoragePaths: Sendable, Equatable {
    let applicationRoot: ManagedApplicationRootPath
    let applicationArchiveRoot: ManagedApplicationArchiveRootPath
    let canonicalBaseRootURL: URL

    private let namespaceRoot: URL
    private let validationContext: ManagedPathValidationContext

    init(
        applicationRoot: ManagedApplicationRootPath,
        applicationArchiveRoot: ManagedApplicationArchiveRootPath,
        canonicalBaseRootURL: URL,
        namespaceRoot: URL,
        validationContext: ManagedPathValidationContext
    ) {
        self.applicationRoot = applicationRoot
        self.applicationArchiveRoot = applicationArchiveRoot
        self.canonicalBaseRootURL = canonicalBaseRootURL
        self.namespaceRoot = namespaceRoot
        self.validationContext = validationContext
    }

    func stagingRoot(transactionID: UUID) -> ManagedStagingRootPath {
        ManagedStagingRootPath(
            url: namespaceRoot
                .appendingPathComponent("Transactions", isDirectory: true)
                .appendingPathComponent(
                    transactionID.uuidString.lowercased(),
                    isDirectory: true
                ),
            validationContext: validationContext
        )
    }
}

struct ManagedPathResolver: Sendable {
    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
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
        _ = resolution
        return ExternalIsolationPath(url: requestedURL)
    }

    /// Revalidates the captured root identity and canonical containment directly
    /// before a managed mutation. There remains a narrow validation-to-operation
    /// race until FS-001 moves mutations to descriptor-relative filesystem APIs.
    func revalidateForMutation(_ path: any ManagedMutationPath) throws -> URL {
        let context = path.validationContext
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

        let currentRoot = try canonicalDirectoryResolution(
            for: context.configuredBaseRootURL,
            targetError: .baseRootNotDirectory,
            unavailableError: .baseRootUnavailable
        )
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
        guard let anchorIdentity = rootResolution.identityAnchor else {
            throw ManagedPathError(.baseRootUnavailable, path: validatedBaseRootURL.path)
        }

        let canonicalBaseRoot = normalizedCanonicalURL(rootResolution.url)
        let canonicalNamespaceRoot = canonicalBaseRoot
            .appendingPathComponent(".parallax", isDirectory: true)
        let namespaceRoot = canonicalNamespaceRoot
        let profileRootURL = canonicalNamespaceRoot
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(applicationComponent.rawValue, isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileComponent.rawValue, isDirectory: true)
        let archiveRootURL = canonicalNamespaceRoot
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent(applicationComponent.rawValue, isDirectory: true)
            .appendingPathComponent(profileComponent.rawValue, isDirectory: true)

        let canonicalProfileRootURL = canonicalNamespaceRoot
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(applicationComponent.rawValue, isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileComponent.rawValue, isDirectory: true)
        let canonicalArchiveRootURL = canonicalNamespaceRoot
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent(applicationComponent.rawValue, isDirectory: true)
            .appendingPathComponent(profileComponent.rawValue, isDirectory: true)
        let userDataURL = profileRootURL
            .appendingPathComponent("UserData", isDirectory: true)
        let codexHomeURL = profileRootURL
            .appendingPathComponent("CodexHome", isDirectory: true)
        let canonicalUserDataURL = canonicalProfileRootURL
            .appendingPathComponent("UserData", isDirectory: true)
        let canonicalCodexHomeURL = canonicalProfileRootURL
            .appendingPathComponent("CodexHome", isDirectory: true)
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
        return normalized
    }

    private func normalizedCanonicalURL(_ url: URL) -> URL {
        let path = url.path
        for (physical, publicAlias) in [
            ("/private/var", "/var"),
            ("/private/tmp", "/tmp"),
            ("/private/etc", "/etc"),
        ] {
            if path == physical {
                return URL(fileURLWithPath: publicAlias, isDirectory: true)
            }
            let prefix = physical + "/"
            if path.hasPrefix(prefix) {
                return URL(
                    fileURLWithPath:
                        publicAlias + String(path.dropFirst(physical.count)),
                    isDirectory: true
                )
            }
        }
        return url.standardizedFileURL
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

    private struct DirectoryResolution {
        let url: URL
        let identityAnchorURL: URL
        let identityAnchor: FileSystemObjectIdentity?
    }

    private func canonicalDirectoryResolution(
        for requestedURL: URL,
        targetError: ManagedPathError.Code,
        unavailableError: ManagedPathError.Code
    ) throws -> DirectoryResolution {
        let requestedComponents = requestedURL.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var currentAttributes: FileSystemItemAttributes
        do {
            current = try fileSystem.canonicalURL(for: current)
            currentAttributes = try fileSystem.attributesOfItem(at: current)
        } catch {
            throw ManagedPathError(unavailableError, path: requestedURL.path)
        }
        guard currentAttributes.kind == .directory else {
            throw ManagedPathError(unavailableError, path: requestedURL.path)
        }

        let pathComponents = Array(requestedComponents.dropFirst())
        for (index, component) in pathComponents.enumerated() {
            let candidate = current.appendingPathComponent(component, isDirectory: true)
            do {
                let attributes = try fileSystem.attributesOfItem(at: candidate)
                let canonical: URL
                if attributes.kind == .symbolicLink {
                    do {
                        canonical = try fileSystem.canonicalURL(for: candidate)
                    } catch {
                        throw ManagedPathError(unavailableError, path: candidate.path)
                    }
                } else {
                    guard attributes.kind == .directory else {
                        throw ManagedPathError(
                            index == pathComponents.count - 1
                                ? targetError
                                : .ancestorNotDirectory,
                            path: candidate.path
                        )
                    }
                    do {
                        canonical = try fileSystem.canonicalURL(for: candidate)
                    } catch {
                        throw ManagedPathError(unavailableError, path: candidate.path)
                    }
                }

                let canonicalAttributes: FileSystemItemAttributes
                do {
                    canonicalAttributes = try fileSystem.attributesOfItem(at: canonical)
                } catch {
                    throw ManagedPathError(unavailableError, path: canonical.path)
                }
                guard canonicalAttributes.kind == .directory else {
                    throw ManagedPathError(
                        index == pathComponents.count - 1
                            ? targetError
                            : .ancestorNotDirectory,
                        path: canonical.path
                    )
                }
                current = canonical
                currentAttributes = canonicalAttributes
            } catch let error as ManagedPathError {
                throw error
            } catch {
                guard isNotFound(error) else {
                    throw ManagedPathError(unavailableError, path: candidate.path)
                }
                var resolved = current
                for missingComponent in pathComponents[index...] {
                    resolved.appendPathComponent(missingComponent, isDirectory: true)
                }
                return DirectoryResolution(
                    url: resolved,
                    identityAnchorURL: current,
                    identityAnchor: currentAttributes.identity
                )
            }
        }
        return DirectoryResolution(
            url: current,
            identityAnchorURL: current,
            identityAnchor: currentAttributes.identity
        )
    }

    private func contains(_ target: URL, within root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func isNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.fileNoSuchFile.rawValue
                || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
                || nsError.code == Int(ENOTDIR)
        }
        return false
    }
}
