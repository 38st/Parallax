import Darwin
import Foundation

extension TrustedContainerFileStore {
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
}
