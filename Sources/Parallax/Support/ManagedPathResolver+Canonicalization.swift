import Darwin
import Foundation

extension ManagedPathResolver {
    func normalizedCanonicalURL(_ url: URL) -> URL {
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

    func canonicalDirectoryResolution(
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

    func isNotFound(_ error: Error) -> Bool {
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
