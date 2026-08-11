import Darwin
import Foundation

enum TrustedParallaxContainerBoundary: Sendable, Equatable {
    case beforeValidation
    case afterValidation
}

enum TrustedParallaxContainerError: Error, Sendable, Equatable {
    case invalidURL(String)
    case unsafeContainer(String)
    case containerIdentityChanged(String)
    case systemCall(operation: String, code: Int32)
}

/// A descriptor-backed authority for the private Parallax support directory.
///
/// The path is retained only so every operation can prove that the directory
/// entry still names the pinned descriptor. Callers never receive the raw
/// descriptor and all child access remains descriptor-relative.
final class TrustedParallaxContainer: @unchecked Sendable {
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

    fileprivate func withValidatedRootDescriptor<T>(
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

enum TrustedContainerFileStoreBoundary: Sendable, Equatable {
    case afterDestinationPreflight
    case afterTemporaryCreation
    case beforeReplace
    case afterReplace
    case afterQuarantineSourceOpen
    case beforeQuarantine
    case afterQuarantine
}

enum TrustedContainerFileStoreError: Error, Sendable, Equatable {
    case invalidName(String)
    case invalidMaximumBytes(Int)
    case unsafeItem(String)
    case changedDuringRead(String)
    case inputTooLarge(actual: UInt64, maximum: Int)
    case lockTimedOut(name: String, timeout: TimeInterval)
    case cleanupRequired(name: String)
    case quarantineEvidenceMismatch(name: String)
    case systemCall(operation: String, code: Int32)
}

struct TrustedContainerFileResidual: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case retainedQuarantineSource
    }

    let name: String
    let reason: Reason

    var cleanupDescription: String {
        "A securely retained persistence residual requires cleanup (\(name))."
    }
}

/// Descriptor-relative access to bounded single-file stores in a trusted
/// Parallax container. The raw container descriptor never leaves this file.
struct TrustedContainerFileStore: Sendable {
    enum ReadResult: Sendable, Equatable {
        case missing
        case bytes(Data)
    }

    let container: TrustedParallaxContainer
    private let boundaryHook:
        @Sendable (TrustedContainerFileStoreBoundary) throws -> Void

    init(
        container: TrustedParallaxContainer,
        boundaryHook: @escaping @Sendable (
            TrustedContainerFileStoreBoundary
        ) throws -> Void = { _ in }
    ) {
        self.container = container
        self.boundaryHook = boundaryHook
    }

    func withExclusiveLock<T>(
        named name: String,
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        _ body: () throws -> T
    ) throws -> T {
        try validate(name)
        precondition(timeout.isFinite && timeout >= 0)
        precondition(pollInterval.isFinite && pollInterval > 0)
        return try container.withValidatedRootDescriptor { root in
            let descriptor = openat(
                root,
                name,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard descriptor >= 0 else {
                throw system("open trusted container lock", errno)
            }
            defer { close(descriptor) }
            _ = try validateDescriptor(
                descriptor,
                name: name,
                tightenMode: true
            )
            let started = DispatchTime.now().uptimeNanoseconds
            let limit = UInt64(
                min(timeout * 1_000_000_000, Double(UInt64.max))
            )
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                if code == EINTR { continue }
                guard code == EWOULDBLOCK || code == EAGAIN else {
                    throw system("acquire trusted container lock", code)
                }
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = now >= started ? now - started : UInt64.max
                guard elapsed < limit else {
                    throw TrustedContainerFileStoreError.lockTimedOut(
                        name: name,
                        timeout: timeout
                    )
                }
                usleep(useconds_t(min(pollInterval * 1_000_000, 50_000)))
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            try requirePath(root, name, matches: descriptor)
            do {
                let value = try body()
                try requirePath(root, name, matches: descriptor)
                return value
            } catch {
                do {
                    try requirePath(root, name, matches: descriptor)
                } catch {
                    throw error
                }
                throw error
            }
        }
    }

    func read(named name: String, maximumBytes: Int) throws -> ReadResult {
        try validate(name)
        guard maximumBytes >= 0 else {
            throw TrustedContainerFileStoreError
                .invalidMaximumBytes(maximumBytes)
        }
        return try container.withValidatedRootDescriptor { root in
            var path = stat()
            guard fstatat(root, name, &path, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return .missing }
                throw system("inspect trusted container file", errno)
            }
            try validateStatus(path, name: name, exactMode: false)
            let descriptor = openat(
                root,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw system("open trusted container file", errno)
            }
            defer { close(descriptor) }
            let before = try validateDescriptor(
                descriptor,
                name: name,
                tightenMode: true
            )
            guard sameObject(path, before) else {
                throw TrustedContainerFileStoreError.changedDuringRead(name)
            }
            guard before.st_size >= 0 else {
                throw TrustedContainerFileStoreError.unsafeItem(name)
            }
            let announced = UInt64(before.st_size)
            guard announced <= UInt64(maximumBytes) else {
                throw TrustedContainerFileStoreError.inputTooLarge(
                    actual: announced,
                    maximum: maximumBytes
                )
            }
            var data = Data(count: Int(announced))
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    guard let base = buffer.baseAddress else { return }
                    let count = Darwin.read(
                        descriptor,
                        base.advanced(by: offset),
                        buffer.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        if count == 0 {
                            throw TrustedContainerFileStoreError
                                .changedDuringRead(name)
                        }
                        throw system("read trusted container file", errno)
                    }
                    offset += count
                }
            }
            var trailing: UInt8 = 0
            var trailingCount: Int
            repeat {
                trailingCount = Darwin.read(descriptor, &trailing, 1)
            } while trailingCount < 0 && errno == EINTR
            if trailingCount < 0 {
                throw system("read trusted container trailing byte", errno)
            }
            guard trailingCount == 0 else {
                throw TrustedContainerFileStoreError.changedDuringRead(name)
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0 else {
                throw system("reinspect trusted container file", errno)
            }
            try validateStatus(after, name: name, exactMode: true)
            guard stableFile(before, after),
                  Int64(data.count) == after.st_size
            else {
                throw TrustedContainerFileStoreError.changedDuringRead(name)
            }
            try requirePath(root, name, matches: descriptor)
            return .bytes(data)
        }
    }

    func replace(
        _ data: Data,
        named name: String,
        temporaryName explicitTemporaryName: String? = nil
    ) throws {
        try validate(name)
        let temporaryName = try replacementTemporaryName(
            for: name,
            explicit: explicitTemporaryName
        )
        let lockName = try replacementLockName(for: name)
        try validate(temporaryName)
        guard name != temporaryName,
              name != lockName,
              temporaryName != lockName
        else {
            throw TrustedContainerFileStoreError.invalidName(temporaryName)
        }
        return try withExclusiveLock(named: lockName) {
            try replaceLocked(
                data,
                named: name,
                temporaryName: temporaryName
            )
        }
    }

    private func replaceLocked(
        _ data: Data,
        named name: String,
        temporaryName: String
    ) throws {
        try container.withValidatedRootDescriptor { root in
            let expected = try openOptionalPinned(
                root: root,
                name: name,
                tightenMode: true
            )
            defer { if let expected { close(expected.descriptor) } }
            try boundaryHook(.afterDestinationPreflight)

            let existingTemporary = try openOptionalPinned(
                root: root,
                name: temporaryName,
                tightenMode: true,
                accessMode: O_RDWR
            )
            let temporary: Int32
            if let existingTemporary {
                temporary = existingTemporary.descriptor
            } else {
                temporary = openat(
                    root,
                    temporaryName,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
                guard temporary >= 0 else {
                    throw system(
                        "create trusted container temporary file",
                        errno
                    )
                }
            }
            var temporaryOpen = true
            let created: stat
            do {
                created = try validateDescriptor(
                    temporary,
                    name: temporaryName,
                    tightenMode: true
                )
            } catch {
                close(temporary)
                throw TrustedContainerFileStoreError.cleanupRequired(
                    name: temporaryName
                )
            }
            defer {
                if temporaryOpen { close(temporary) }
            }
            try boundaryHook(.afterTemporaryCreation)
            if existingTemporary != nil {
                guard ftruncate(temporary, 0) == 0,
                      lseek(temporary, 0, SEEK_SET) == 0
                else {
                    throw system(
                        "reset trusted container temporary file",
                        errno
                    )
                }
            }
            try writeExactly(data, descriptor: temporary)
            guard fsync(temporary) == 0 else {
                throw system("fsync trusted container temporary file", errno)
            }
            try boundaryHook(.beforeReplace)
            try requirePath(root, temporaryName, matches: temporary)
            try requireDestination(root: root, name: name, expected: expected)

            if let expected {
                guard renameatx_np(
                    root,
                    temporaryName,
                    root,
                    name,
                    UInt32(RENAME_SWAP)
                ) == 0 else {
                    throw system("swap trusted container file", errno)
                }
                try boundaryHook(.afterReplace)
                guard path(root, name, matches: created) else {
                    throw TrustedContainerFileStoreError.unsafeItem(name)
                }
                guard path(root, temporaryName, matches: expected.status) else {
                    throw TrustedContainerFileStoreError.unsafeItem(name)
                }
            } else {
                guard renameatx_np(
                    root,
                    temporaryName,
                    root,
                    name,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    throw system("publish trusted container file", errno)
                }
                try boundaryHook(.afterReplace)
                guard path(root, name, matches: created) else {
                    throw TrustedContainerFileStoreError.unsafeItem(name)
                }
            }
            try requirePath(root, name, matches: temporary)
            _ = try validateDescriptor(
                temporary,
                name: name,
                tightenMode: false
            )
            guard fsync(root) == 0 else {
                throw system("fsync trusted container directory", errno)
            }
            guard close(temporary) == 0 else {
                temporaryOpen = false
                throw system("close published trusted container file", errno)
            }
            temporaryOpen = false
        }
    }

    @discardableResult
    func quarantine(named name: String, as destinationName: String) throws
        -> TrustedContainerFileResidual?
    {
        try validate(name)
        try validate(destinationName)
        return try container.withValidatedRootDescriptor { root in
            guard let source = try openOptionalPinned(
                root: root,
                name: name,
                tightenMode: true
            ) else { return nil }
            defer { close(source.descriptor) }
            try boundaryHook(.afterQuarantineSourceOpen)
            try boundaryHook(.beforeQuarantine)
            let data = try readExactly(
                source: source.descriptor,
                sourceStatus: source.status,
                maximumBytes: 4 * 1_024 * 1_024
            )
            try requirePath(root, name, matches: source.descriptor)
            let destination = openat(
                root,
                destinationName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard destination >= 0 else {
                let code = errno
                guard code == EEXIST else {
                    throw system("create trusted quarantine copy", code)
                }
                guard let existing = try openOptionalPinned(
                    root: root,
                    name: destinationName,
                    tightenMode: true
                ) else {
                    throw TrustedContainerFileStoreError
                        .quarantineEvidenceMismatch(name: destinationName)
                }
                defer { close(existing.descriptor) }
                let existingData = try readExactly(
                    source: existing.descriptor,
                    sourceStatus: existing.status,
                    maximumBytes: 4 * 1_024 * 1_024
                )
                try requirePath(
                    root,
                    destinationName,
                    matches: existing.descriptor
                )
                guard existingData == data else {
                    throw TrustedContainerFileStoreError
                        .quarantineEvidenceMismatch(name: destinationName)
                }
                try boundaryHook(.afterQuarantine)
                let finalSourceData = try readExactly(
                    source: source.descriptor,
                    sourceStatus: source.status,
                    maximumBytes: 4 * 1_024 * 1_024
                )
                let finalEvidenceData = try readExactly(
                    source: existing.descriptor,
                    sourceStatus: existing.status,
                    maximumBytes: 4 * 1_024 * 1_024
                )
                guard finalSourceData == data,
                      finalEvidenceData == data
                else {
                    throw TrustedContainerFileStoreError
                        .quarantineEvidenceMismatch(name: destinationName)
                }
                try requirePath(
                    root,
                    destinationName,
                    matches: existing.descriptor
                )
                try requirePath(root, name, matches: source.descriptor)
                return TrustedContainerFileResidual(
                    name: name,
                    reason: .retainedQuarantineSource
                )
            }
            var destinationOpen = true
            defer { if destinationOpen { close(destination) } }
            _ = try validateDescriptor(
                destination,
                name: destinationName,
                tightenMode: true
            )
            try writeExactly(data, descriptor: destination)
            guard fsync(destination) == 0 else {
                throw system("fsync trusted quarantine copy", errno)
            }
            let writtenEvidenceStatus = try validateDescriptor(
                destination,
                name: destinationName,
                tightenMode: false
            )
            try boundaryHook(.afterQuarantine)
            let finalSourceData = try readExactly(
                source: source.descriptor,
                sourceStatus: source.status,
                maximumBytes: 4 * 1_024 * 1_024
            )
            let finalEvidenceData = try readExactly(
                source: destination,
                sourceStatus: writtenEvidenceStatus,
                maximumBytes: 4 * 1_024 * 1_024
            )
            guard finalSourceData == data,
                  finalEvidenceData == data
            else {
                throw TrustedContainerFileStoreError
                    .quarantineEvidenceMismatch(name: destinationName)
            }
            try requirePath(root, destinationName, matches: destination)
            _ = try validateDescriptor(
                destination,
                name: destinationName,
                tightenMode: false
            )
            guard fsync(root) == 0 else {
                throw system("fsync trusted container quarantine", errno)
            }
            try requirePath(root, name, matches: source.descriptor)
            guard close(destination) == 0 else {
                destinationOpen = false
                throw system("close trusted quarantine copy", errno)
            }
            destinationOpen = false
            return TrustedContainerFileResidual(
                name: name,
                reason: .retainedQuarantineSource
            )
        }
    }

    private struct PinnedFile {
        let descriptor: Int32
        let status: stat
    }

    private func openOptionalPinned(
        root: Int32,
        name: String,
        tightenMode: Bool,
        accessMode: Int32 = O_RDONLY
    ) throws -> PinnedFile? {
        var preflight = stat()
        guard fstatat(root, name, &preflight, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw system("inspect trusted container item", errno)
        }
        try validateStatus(preflight, name: name, exactMode: false)
        let descriptor = openat(
            root,
            name,
            accessMode | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw system("open trusted container item", errno)
        }
        do {
            let status = try validateDescriptor(
                descriptor,
                name: name,
                tightenMode: tightenMode
            )
            guard sameObject(preflight, status) else {
                throw TrustedContainerFileStoreError.unsafeItem(name)
            }
            try requirePath(root, name, matches: descriptor)
            return PinnedFile(descriptor: descriptor, status: status)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func requireDestination(
        root: Int32,
        name: String,
        expected: PinnedFile?
    ) throws {
        if let expected {
            try requirePath(root, name, matches: expected.descriptor)
            return
        }
        var status = stat()
        guard fstatat(root, name, &status, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT
        else {
            throw TrustedContainerFileStoreError.unsafeItem(name)
        }
    }

    private func writeExactly(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw system(
                        "write trusted container temporary file",
                        count < 0 ? errno : EIO
                    )
                }
                offset += count
            }
        }
    }

    private func readExactly(
        source: Int32,
        sourceStatus: stat,
        maximumBytes: Int
    ) throws -> Data {
        guard sourceStatus.st_size >= 0,
              UInt64(sourceStatus.st_size) <= UInt64(maximumBytes)
        else {
            throw TrustedContainerFileStoreError.inputTooLarge(
                actual: UInt64(max(0, sourceStatus.st_size)),
                maximum: maximumBytes
            )
        }
        var data = Data(count: Int(sourceStatus.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { return }
                let count = pread(
                    source,
                    base.advanced(by: offset),
                    buffer.count - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw TrustedContainerFileStoreError
                        .changedDuringRead("quarantine source")
                }
                offset += count
            }
        }
        var trailing: UInt8 = 0
        var trailingCount: Int
        repeat {
            trailingCount = pread(
                source,
                &trailing,
                1,
                off_t(data.count)
            )
        } while trailingCount < 0 && errno == EINTR
        guard trailingCount == 0 else {
            throw TrustedContainerFileStoreError
                .changedDuringRead("quarantine source")
        }
        var finalSource = stat()
        guard fstat(source, &finalSource) == 0,
              stableFile(sourceStatus, finalSource)
        else {
            throw TrustedContainerFileStoreError
                .changedDuringRead("quarantine source")
        }
        return data
    }

    private func requirePath(
        _ root: Int32,
        _ name: String,
        matches descriptor: Int32
    ) throws {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              path(root, name, matches: opened)
        else {
            throw TrustedContainerFileStoreError.unsafeItem(name)
        }
    }

    private func path(_ root: Int32, _ name: String, matches expected: stat)
        -> Bool
    {
        var actual = stat()
        return fstatat(root, name, &actual, AT_SYMLINK_NOFOLLOW) == 0
            && sameObject(actual, expected)
    }

    private func validateDescriptor(
        _ descriptor: Int32,
        name: String,
        tightenMode: Bool
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw system("inspect trusted container descriptor", errno)
        }
        try validateStatus(status, name: name, exactMode: false)
        if tightenMode, status.st_mode & 0o7777 != 0o600 {
            guard fchmod(descriptor, 0o600) == 0,
                  fstat(descriptor, &status) == 0
            else {
                throw system("secure trusted container file", errno)
            }
        }
        try validateStatus(status, name: name, exactMode: true)
        try TrustedParallaxContainer.validateNoExtendedACL(
            descriptor,
            item: name,
            operation: "inspect trusted container file ACL"
        )
        return status
    }

    private func validateStatus(
        _ status: stat,
        name: String,
        exactMode: Bool
    ) throws {
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & 0o7000 == 0,
              !exactMode || status.st_mode & 0o7777 == 0o600
        else {
            throw TrustedContainerFileStoreError.unsafeItem(name)
        }
    }

    private func validate(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains(":"),
              !name.contains("\0")
        else {
            throw TrustedContainerFileStoreError.invalidName(name)
        }
    }

    private func replacementTemporaryName(
        for name: String,
        explicit: String?
    ) throws -> String {
        if let explicit {
            try validate(explicit)
            return explicit
        }
        let derived = ".\(name).replace"
        guard derived.utf8.count <= 255 else {
            throw TrustedContainerFileStoreError.invalidName(derived)
        }
        return derived
    }

    private func replacementLockName(for name: String) throws -> String {
        let derived = ".\(name).replace.lock"
        guard derived.utf8.count <= 255 else {
            throw TrustedContainerFileStoreError.invalidName(derived)
        }
        try validate(derived)
        return derived
    }

    private func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func stableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameObject(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func system(_ operation: String, _ code: Int32)
        -> TrustedContainerFileStoreError
    {
        .systemCall(operation: operation, code: code)
    }
}
