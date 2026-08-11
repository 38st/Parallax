import Darwin
import Foundation

enum ProviderExecutableLocatorError: Error, Equatable {
    case missing(String)
    case noLongerTrusted(String)
}

/// A provider executable plus the trust root that authorized it. The same
/// validation is repeated immediately before `Process.run()` to narrow the
/// discovery-to-execution race.
struct TrustedProviderExecutable: Sendable, Equatable {
    let url: URL
    fileprivate let trustRoot: URL?
    fileprivate let currentUserID: uid_t
    fileprivate let allowsGroupWritableAncestors: Bool

    func revalidatedURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let validated = ProviderExecutableTrustPolicy.validate(
            url,
            beneath: trustRoot,
            allowsGroupWritableAncestors: allowsGroupWritableAncestors,
            fileManager: fileManager,
            currentUserID: currentUserID
        ) else {
            throw ProviderExecutableLocatorError.noLongerTrusted(url.path)
        }
        return validated
    }
}

private enum ProviderExecutableTrustPolicy {
    static func validate(
        _ candidate: URL,
        beneath trustRoot: URL?,
        allowsGroupWritableAncestors: Bool,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> URL? {
        guard
            let canonical = canonicalURL(candidate),
            trustedItem(
                canonical,
                expectedType: .typeRegular,
                executable: true,
                allowsGroupWrite: false,
                requiredGroupID: nil,
                fileManager: fileManager,
                currentUserID: currentUserID
            )
        else {
            return nil
        }

        guard
            let trustRoot,
            let canonicalRoot = canonicalURL(trustRoot),
            canonical.path.hasPrefix(canonicalRoot.path + "/"),
            let rootAttributes = try? fileManager.attributesOfItem(
                atPath: canonicalRoot.path
            ),
            let trustedGroupID =
                (rootAttributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value
        else {
            return nil
        }

        var directory = canonical.deletingLastPathComponent()
        while true {
            guard trustedItem(
                directory,
                expectedType: .typeDirectory,
                executable: false,
                allowsGroupWrite: allowsGroupWritableAncestors,
                requiredGroupID: trustedGroupID,
                fileManager: fileManager,
                currentUserID: currentUserID
            ) else {
                return nil
            }
            if directory == canonicalRoot { break }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { return nil }
            directory = parent
        }
        return canonical
    }

    private static func canonicalURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        guard let resolvedPath = realpath(url.path, nil) else { return nil }
        defer { free(resolvedPath) }
        return URL(fileURLWithPath: String(cString: resolvedPath))
    }

    private static func trustedItem(
        _ url: URL,
        expectedType: FileAttributeType,
        executable: Bool,
        allowsGroupWrite: Bool,
        requiredGroupID: gid_t?,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> Bool {
        guard
            let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
            ),
            attributes[.type] as? FileAttributeType == expectedType,
            !executable || fileManager.isExecutableFile(atPath: url.path),
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
            owner == 0 || owner == currentUserID,
            let permissions =
                (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
            permissions & (allowsGroupWrite ? 0o002 : 0o022) == 0
        else {
            return false
        }
        if permissions & 0o020 != 0 {
            guard
                allowsGroupWrite,
                let requiredGroupID,
                let groupID =
                    (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value,
                groupID == requiredGroupID
            else {
                return false
            }
        }
        return true
    }
}

/// Resolves provider tools only from explicit system installation roots. It
/// intentionally does not search `PATH`, `~/.local`, NVM, or other automatic
/// user-managed locations. Known Homebrew roots are a local-admin boundary:
/// group-writable ancestors are accepted only within that root, only for the
/// root's group, and never for the executable leaf. Parallax cannot defend
/// against another process already running as the same user or local admin.
struct ProviderExecutableLocator {
    private struct SearchLocation {
        let directory: URL
        let trustRoot: URL
        let allowsGroupWritableAncestors: Bool
    }

    private let fileManager: FileManager
    private let currentUserID: uid_t
    private let locations: [SearchLocation]

    init(
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid(),
        fixedDirectories: [URL]? = nil,
        homebrewRoots: [URL]? = nil
    ) {
        self.fileManager = fileManager
        self.currentUserID = currentUserID
        if fixedDirectories != nil || homebrewRoots != nil {
            let strictLocations = (fixedDirectories ?? []).map {
                SearchLocation(
                    directory: $0,
                    trustRoot: $0,
                    allowsGroupWritableAncestors: false
                )
            }
            let homebrewLocations = (homebrewRoots ?? []).map {
                SearchLocation(
                    directory: $0.appendingPathComponent("bin"),
                    trustRoot: $0,
                    allowsGroupWritableAncestors: true
                )
            }
            locations = strictLocations + homebrewLocations
        } else {
            locations = [
                SearchLocation(
                    directory: URL(fileURLWithPath: "/opt/homebrew/bin"),
                    trustRoot: URL(fileURLWithPath: "/opt/homebrew"),
                    allowsGroupWritableAncestors: true
                ),
                SearchLocation(
                    directory: URL(fileURLWithPath: "/usr/local/bin"),
                    trustRoot: URL(fileURLWithPath: "/usr/local"),
                    allowsGroupWritableAncestors: true
                ),
                SearchLocation(
                    directory: URL(fileURLWithPath: "/usr/bin"),
                    trustRoot: URL(fileURLWithPath: "/usr"),
                    allowsGroupWritableAncestors: false
                ),
            ]
        }
    }

    func locate(
        named name: String
    ) throws -> TrustedProviderExecutable {
        for location in locations {
            let candidate = location.directory.appendingPathComponent(
                name,
                isDirectory: false
            )
            if let validated = ProviderExecutableTrustPolicy.validate(
                candidate,
                beneath: location.trustRoot,
                allowsGroupWritableAncestors:
                    location.allowsGroupWritableAncestors,
                fileManager: fileManager,
                currentUserID: currentUserID
            ) {
                return TrustedProviderExecutable(
                    url: validated,
                    trustRoot: location.trustRoot,
                    currentUserID: currentUserID,
                    allowsGroupWritableAncestors:
                        location.allowsGroupWritableAncestors
                )
            }
        }

        throw ProviderExecutableLocatorError.missing(name)
    }
}
