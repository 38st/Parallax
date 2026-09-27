import Darwin
import Foundation

enum TrustedContainerFileStoreBoundary: Sendable, Equatable {
    case beforeOpenFile(String, flags: Int32)
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
    let boundaryHook:
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
                O_CREAT | O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
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
            let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            try boundaryHook(.beforeOpenFile(name, flags: flags))
            let descriptor = openat(
                root,
                name,
                flags
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

    struct PinnedFile {
        let descriptor: Int32
        let status: stat
    }
}
