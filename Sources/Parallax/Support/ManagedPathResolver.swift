import Foundation

struct ManagedPathResolver: Sendable {
    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
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
