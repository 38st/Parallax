import Darwin
import Foundation

extension TrustedContainerFileStore {
    func openOptionalPinned(
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

    func requireDestination(
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

    func writeExactly(_ data: Data, descriptor: Int32) throws {
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

    func readExactly(
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

    func requirePath(
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

    func path(_ root: Int32, _ name: String, matches expected: stat)
        -> Bool
    {
        var actual = stat()
        return fstatat(root, name, &actual, AT_SYMLINK_NOFOLLOW) == 0
            && sameObject(actual, expected)
    }

    func validateDescriptor(
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

    func validateStatus(
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

    func validate(_ name: String) throws {
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

    func replacementTemporaryName(
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

    func replacementLockName(for name: String) throws -> String {
        let derived = ".\(name).replace.lock"
        guard derived.utf8.count <= 255 else {
            throw TrustedContainerFileStoreError.invalidName(derived)
        }
        try validate(derived)
        return derived
    }

    func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    func stableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameObject(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    func system(_ operation: String, _ code: Int32)
        -> TrustedContainerFileStoreError
    {
        .systemCall(operation: operation, code: code)
    }
}
