import Darwin
import Foundation

/// Operation labels remain diagnostic data; user-facing text is localized whole.
func systemCallFailureDescription(
    operation _: String,
    code: Int32
) -> String {
    switch code {
    case EIO:
        return String(localized: "Parallax could not read or write the storage data. Check the connection to the volume and try again.")
    case EACCES, EPERM:
        return String(localized: "Parallax does not have permission to access this folder or file.")
    case ENOSPC, EDQUOT:
        return String(localized: "There is not enough available storage space to complete the operation.")
    case EROFS:
        return String(localized: "The storage volume is read-only. Choose a writable volume or restore write access.")
    default:
        break
    }
    let errorCode: Int = Int(code)
    return String(
        localized: "Parallax could not complete the filesystem operation (error \(errorCode))."
    )
}

func filesystemErrorUserInfo(
    description: String?,
    operation: String? = nil,
    code: Int32? = nil
) -> [String: Any] {
    var info: [String: Any] = [:]
    if let description { info[NSLocalizedDescriptionKey] = description }
    if let operation, let code {
        let diagnostic = "\(operation) (errno \(code))"
        info[NSDebugDescriptionErrorKey] = diagnostic
        info[NSUnderlyingErrorKey] = NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSDebugDescriptionErrorKey: diagnostic]
        )
    }
    return info
}

enum TrustedParallaxContainerBoundary: Sendable, Equatable {
    case beforeValidation
    case afterValidation
}

enum TrustedParallaxContainerError: LocalizedError, CustomNSError, Sendable, Equatable {
    case invalidURL(String)
    case unsafeContainer(String)
    case containerIdentityChanged(String)
    case systemCall(operation: String, code: Int32)

    var errorUserInfo: [String: Any] {
        if case .systemCall(let operation, let code) = self {
            return filesystemErrorUserInfo(description: errorDescription, operation: operation, code: code)
        }
        return filesystemErrorUserInfo(description: errorDescription)
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            String(
                localized:
                    "The trusted Parallax container URL is invalid: \(path)."
            )
        case .unsafeContainer(let path):
            String(
                localized:
                    "The trusted Parallax container is not a private directory owned by the current user: \(path)."
            )
        case .containerIdentityChanged(let path):
            String(
                localized:
                    "The trusted Parallax container changed after it was validated: \(path)."
            )
        case .systemCall(let operation, let code):
            systemCallFailureDescription(operation: operation, code: code)
        }
    }
}

/// A descriptor-backed authority for the private Parallax support directory.
///
/// The path is retained only so every operation can prove that the directory
/// entry still names the pinned descriptor. Callers never receive the raw
/// descriptor and all child access remains descriptor-relative.
final class TrustedParallaxContainer: Sendable {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    static let directoryName = "Parallax"

    let url: URL

    private let descriptor: Int32
    private let identity: Identity
    private let boundaryHook:
        @Sendable (TrustedParallaxContainerBoundary) throws -> Void

    init(
        adoptingValidatedContainer handle: FileHandle,
        url: URL,
        boundaryHook: @escaping @Sendable (
            TrustedParallaxContainerBoundary
        ) throws -> Void = { _ in }
    ) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw TrustedParallaxContainerError.invalidURL(url.path)
        }
        let duplicate = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw Self.system("duplicate trusted Parallax container", errno)
        }
        descriptor = duplicate
        self.url = url.standardizedFileURL
        self.boundaryHook = boundaryHook
        do {
            identity = try Self.validate(
                descriptor: duplicate,
                path: self.url.path
            )
        } catch {
            close(duplicate)
            throw error
        }
    }

    /// Compatibility construction for isolated stores and tests. Production
    /// obtains the capability from the settings mutation authority instead.
    static func establish(
        applicationSupportURL: URL,
        boundaryHook: @escaping @Sendable (
            TrustedParallaxContainerBoundary
        ) throws -> Void = { _ in }
    ) throws -> TrustedParallaxContainer {
        guard applicationSupportURL.isFileURL,
              applicationSupportURL.path.hasPrefix("/")
        else {
            throw TrustedParallaxContainerError.invalidURL(
                applicationSupportURL.path
            )
        }
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        let requestedPath = applicationSupportURL.standardizedFileURL.path
        var requestedStatus = stat()
        guard lstat(requestedPath, &requestedStatus) == 0,
              requestedStatus.st_mode & S_IFMT == S_IFDIR
        else {
            throw TrustedParallaxContainerError.unsafeContainer(requestedPath)
        }
        guard let resolved = realpath(requestedPath, nil) else {
            throw system("canonicalize Application Support", errno)
        }
        defer { free(resolved) }
        let canonicalSupportPath = String(cString: resolved)
        let support = open(
            canonicalSupportPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard support >= 0 else {
            throw system("open Application Support", errno)
        }
        defer { close(support) }
        var supportStatus = stat()
        var canonicalStatus = stat()
        guard fstat(support, &supportStatus) == 0,
              lstat(canonicalSupportPath, &canonicalStatus) == 0,
              sameObject(requestedStatus, supportStatus),
              sameObject(supportStatus, canonicalStatus)
        else {
            throw TrustedParallaxContainerError
                .containerIdentityChanged(requestedPath)
        }

        if mkdirat(support, directoryName, 0o700) != 0, errno != EEXIST {
            throw system("create Parallax container", errno)
        }
        let container = openat(
            support,
            directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard container >= 0 else {
            throw system("open Parallax container", errno)
        }
        defer { close(container) }
        guard fchmod(container, 0o700) == 0 else {
            throw system("secure Parallax container", errno)
        }
        return try TrustedParallaxContainer(
            adoptingValidatedContainer: FileHandle(
                fileDescriptor: container,
                closeOnDealloc: false
            ),
            url: URL(fileURLWithPath: canonicalSupportPath)
                .appendingPathComponent(
                directoryName,
                isDirectory: true
            ),
            boundaryHook: boundaryHook
        )
    }

    deinit {
        close(descriptor)
    }

    func validate() throws {
        try withValidatedRootDescriptor { _ in () }
    }

    func withValidatedRootDescriptor<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        try boundaryHook(.beforeValidation)
        let before = try Self.validate(
            descriptor: descriptor,
            path: url.path
        )
        guard before == identity else {
            throw TrustedParallaxContainerError.containerIdentityChanged(
                url.path
            )
        }
        try boundaryHook(.afterValidation)
        do {
            let value = try body(descriptor)
            try validatePostflight()
            return value
        } catch {
            do {
                try validatePostflight()
            } catch {
                throw error
            }
            throw error
        }
    }

    private func validatePostflight() throws {
        let after = try Self.validate(
            descriptor: descriptor,
            path: url.path
        )
        guard after == identity else {
            throw TrustedParallaxContainerError.containerIdentityChanged(
                url.path
            )
        }
    }

    private static func validate(
        descriptor: Int32,
        path: String
    ) throws -> Identity {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else {
            throw system("inspect trusted Parallax container", errno)
        }
        guard descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_uid == geteuid(),
              descriptorStatus.st_mode & 0o7777 == 0o700
        else {
            throw TrustedParallaxContainerError.unsafeContainer(path)
        }
        try validateNoExtendedACL(
            descriptor,
            item: path,
            operation: "inspect trusted Parallax container ACL"
        )

        var pathStatus = stat()
        guard lstat(path, &pathStatus) == 0 else {
            throw TrustedParallaxContainerError.containerIdentityChanged(path)
        }
        guard pathStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_dev == descriptorStatus.st_dev,
              pathStatus.st_ino == descriptorStatus.st_ino,
              pathStatus.st_uid == descriptorStatus.st_uid,
              pathStatus.st_mode & 0o7777
                == descriptorStatus.st_mode & 0o7777
        else {
            throw TrustedParallaxContainerError.containerIdentityChanged(path)
        }
        return Identity(
            device: descriptorStatus.st_dev,
            inode: descriptorStatus.st_ino
        )
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    static func validateNoExtendedACL(
        _ descriptor: Int32,
        item: String,
        operation: String
    ) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let code = errno
            if code == ENOENT { return }
            throw system(operation, code)
        }
        var entry: acl_entry_t?
        errno = 0
        let entryStatus = acl_get_entry(
            acl,
            ACL_FIRST_ENTRY.rawValue,
            &entry
        )
        let entryError = errno
        errno = 0
        let freeStatus = acl_free(UnsafeMutableRawPointer(acl))
        let freeError = errno
        guard freeStatus == 0 else {
            throw system(operation, freeError)
        }
        if entryStatus == -1, entryError == EINVAL { return }
        if entryStatus == 0 {
            throw TrustedParallaxContainerError.unsafeContainer(item)
        }
        throw system(operation, entryError)
    }

    private static func system(
        _ operation: String,
        _ code: Int32
    ) -> TrustedParallaxContainerError {
        .systemCall(operation: operation, code: code)
    }
}
