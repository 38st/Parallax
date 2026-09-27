import Darwin
import Foundation

extension TrustedContainerFileStore {
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
            guard synchronizeFileDescriptor(temporary) == 0 else {
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
            guard synchronizeFileDescriptor(root) == 0 else {
                throw system("fsync trusted container directory", errno)
            }
            guard close(temporary) == 0 else {
                temporaryOpen = false
                throw system("close published trusted container file", errno)
            }
            temporaryOpen = false
        }
    }
}
