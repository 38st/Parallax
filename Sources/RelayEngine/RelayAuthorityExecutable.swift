import CryptoKit
import Darwin
import Foundation

public enum RelayExecutableIdentityError: Error, Sendable, Equatable {
    case invalidPath
    case symbolicLink
    case notRegularFile
    case notExecutable
    case inspectionFailed(code: Int32)
    case readFailed
}

/// An executable admitted by exact canonical path, filesystem identity, and
/// content digest. A stage capability names these values rather than a mutable
/// command name resolved through `PATH`.
public struct RelayExecutableIdentity: Sendable, Equatable, Hashable {
    public let canonicalURL: URL
    public let device: UInt64
    public let inode: UInt64
    public let sha256: String

    public init(inspecting executableURL: URL) throws {
        let standardized = executableURL.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw RelayExecutableIdentityError.invalidPath
        }

        var linkStatus = stat()
        guard lstat(standardized.path, &linkStatus) == 0 else {
            throw RelayExecutableIdentityError.inspectionFailed(code: errno)
        }
        guard (linkStatus.st_mode & S_IFMT) != S_IFLNK else {
            throw RelayExecutableIdentityError.symbolicLink
        }
        guard (linkStatus.st_mode & S_IFMT) == S_IFREG else {
            throw RelayExecutableIdentityError.notRegularFile
        }
        guard access(standardized.path, X_OK) == 0 else {
            throw RelayExecutableIdentityError.notExecutable
        }

        canonicalURL = standardized.resolvingSymlinksInPath()
        device = UInt64(linkStatus.st_dev)
        inode = UInt64(linkStatus.st_ino)
        sha256 = try Self.fileDigest(at: standardized)
    }

    public func matchesCurrentFile() -> Bool {
        guard let current = try? RelayExecutableIdentity(
            inspecting: canonicalURL
        ) else {
            return false
        }
        return current == self
    }

    private static func fileDigest(at url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw RelayExecutableIdentityError.readFailed
        }
        defer { try? handle.close() }

        var digest = SHA256()
        do {
            while true {
                let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
                guard !chunk.isEmpty else { break }
                digest.update(data: chunk)
            }
        } catch {
            throw RelayExecutableIdentityError.readFailed
        }
        return digest.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
