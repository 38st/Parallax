import Darwin
import Foundation

extension SettingsPrimaryPublication {
    func createTemporary(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        resources: PublicationResources
    ) throws {
        var descriptor: Int32 = -1
        var selectedName = ""
        var finalCode = EEXIST
        for _ in 0 ..< Self.temporaryAttemptLimit {
            let name = SettingsPublicationResidualNaming.generatedName(
                nameSource()
            )
            let opened: Int32
            if let code = systemCallHook(.createTemporary) {
                opened = -1
                finalCode = code
            } else {
                opened = openat(
                    settingsDescriptor,
                    name,
                    O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                finalCode = opened < 0 ? errno : 0
            }
            if opened >= 0 {
                descriptor = opened
                selectedName = name
                break
            }
            guard finalCode == EEXIST else {
                throw system(
                    "create settings publication temporary",
                    finalCode
                )
            }
        }
        guard descriptor >= 0 else {
            throw system(
                "exhaust settings publication temporary names",
                finalCode
            )
        }
        resources.descriptor = descriptor
        resources.name = selectedName

        let opened = try metadata(
            descriptor,
            call: .inspectTemporary,
            operation: "inspect settings publication temporary"
        )
        guard opened.kind == .regularFile,
              opened.owner == geteuid(),
              opened.linkCount == 1
        else {
            throw SettingsPrimaryPublicationFailure
                .invalidRequest("created temporary identity")
        }
        resources.identity = opened
        boundaryHook(.afterTemporaryOpen)
        try callStatus(
            .setTemporaryMode,
            operation: "set settings publication temporary mode",
            retryInterruptions: true
        ) {
            fchmod(descriptor, 0o600)
        }
        let secured = try metadata(
            descriptor,
            call: .reinspectTemporary,
            operation: "reinspect settings publication temporary"
        )
        try validateTemporary(secured)
        try validateACL(descriptor)
        let path = try pathMetadata(
            settingsDescriptor,
            selectedName,
            call: .inspectTemporaryPath,
            operation: "inspect settings publication temporary path"
        )
        guard sameIdentity(secured, path) else {
            throw SettingsPrimaryPublicationFailure
                .invalidRequest("temporary path identity")
        }
        resources.identity = secured
        _ = request
    }

    func writeAll(
        _ bytes: Data,
        descriptor: Int32
    ) throws {
        var offset = 0
        var consecutiveInterrupts = 0
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw SettingsPrimaryPublicationFailure
                    .invalidRequest("empty target")
            }
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let directive = writeHook(descriptor, offset, remaining)
                let count: Int
                let code: Int32
                switch directive {
                case .system:
                    count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        remaining
                    )
                    code = count < 0 ? errno : 0
                case .failure(let injected):
                    count = -1
                    code = injected
                case .limit(let limit):
                    count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        min(remaining, max(1, limit))
                    )
                    code = count < 0 ? errno : 0
                case .zero:
                    count = 0
                    code = 0
                }
                if count < 0 {
                    if code == EINTR {
                        consecutiveInterrupts += 1
                        guard consecutiveInterrupts
                                <= Self.maximumConsecutiveInterrupts
                        else {
                            throw SettingsPrimaryPublicationFailure
                                .writeNoProgress
                        }
                        continue
                    }
                    throw system("write settings publication temporary", code)
                }
                guard count > 0 else {
                    throw system(
                        "write settings publication temporary",
                        EIO
                    )
                }
                consecutiveInterrupts = 0
                offset += count
            }
        }
    }

    func openAndVerifyDisplacedPrior(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        resources: PublicationResources
    ) throws {
        let descriptor: Int32
        if let code = systemCallHook(.openDisplacedPrior) {
            throw system("open displaced prior settings", code)
        } else {
            descriptor = openat(
                settingsDescriptor,
                resources.name,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw system("open displaced prior settings", errno)
            }
        }
        resources.displacedDescriptor = descriptor
        try verifyDisplacedPrior(
            request,
            settingsDescriptor: settingsDescriptor,
            resources: resources
        )
    }

    func exactDescriptorBytes(
        _ descriptor: Int32,
        expected: Data,
        token: SettingsVersionToken
    ) throws -> Bool {
        guard expected.count <= SettingsRepository.maximumPrimaryBytes else {
            return false
        }
        let result = SettingsExactPread.read(
            byteCount: expected.count,
            retryPolicy: .init(
                interruptedCode: EINTR,
                content: .retry(
                    maximumConsecutive: Self.maximumConsecutiveInterrupts
                ),
                trailingByte: .retry(
                    maximumConsecutive: Self.maximumConsecutiveInterrupts
                )
            ),
            read: { destination, offset, requested in
                if let code = systemCallHook(.readProof) {
                    return .failure(code: code)
                }
                let count = pread(
                    descriptor,
                    destination,
                    requested,
                    off_t(offset)
                )
                guard count >= 0 else {
                    return .failure(code: errno)
                }
                return .bytes(count)
            },
            trailingRead: { destination, offset, requested in
                if let code = systemCallHook(.readProofTrailing) {
                    return .failure(code: code)
                }
                let count = pread(
                    descriptor,
                    destination,
                    requested,
                    off_t(offset)
                )
                guard count >= 0 else {
                    return .failure(code: errno)
                }
                return .bytes(count)
            }
        )
        switch result {
        case .success(let actual):
            return actual == expected
                && SettingsSourceSHA256(actual) == token.sourceSHA256
        case .failure(.system(_, let code)),
             .failure(.interruptLimitExceeded(_, let code, _)):
            throw system("read publication proof descriptor", code)
        case .failure:
            return false
        }
    }

    func metadata(
        _ descriptor: Int32,
        call: SettingsPrimaryPublicationSystemCall,
        operation: String
    ) throws -> SettingsPrimaryFileMetadata {
        if let code = systemCallHook(call) {
            throw system(operation, code)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw system(operation, errno)
        }
        return SettingsPrimaryDescriptorSecurity.metadata(from: status)
    }

    func pathMetadata(
        _ parent: Int32,
        _ name: String,
        call: SettingsPrimaryPublicationSystemCall,
        operation: String
    ) throws -> SettingsPrimaryFileMetadata {
        if let code = systemCallHook(call) {
            throw system(operation, code)
        }
        var status = stat()
        guard fstatat(
            parent,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw system(operation, errno)
        }
        return SettingsPrimaryDescriptorSecurity.metadata(from: status)
    }

    func validateTemporary(
        _ metadata: SettingsPrimaryFileMetadata
    ) throws {
        guard metadata.kind == .regularFile,
              SettingsPrimaryDescriptorSecurity
                  .ownershipAndModeViolation(metadata) == nil,
              metadata.mode == 0o600,
              metadata.linkCount == 1
        else {
            throw SettingsPrimaryPublicationFailure
                .invalidRequest("unsafe temporary")
        }
    }

    func validateACL(_ descriptor: Int32) throws {
        let directive = aclHook(descriptor)
        let result = SettingsPrimaryDescriptorSecurity.extendedACL(
            descriptor: descriptor,
            directive: directive
        )
        switch result {
        case .absent:
            return
        case .present:
            throw SettingsPrimaryPublicationFailure
                .invalidRequest("temporary ACL")
        case .failure(let code):
            throw system("inspect publication temporary ACL", code)
        }
    }

    func callStatus(
        _ call: SettingsPrimaryPublicationSystemCall,
        operation: String,
        retryInterruptions: Bool = false,
        _ body: () -> Int32
    ) throws {
        var interruptions = 0
        while true {
            let code: Int32
            if let injected = systemCallHook(call) {
                code = injected
            } else {
                guard body() != 0 else { return }
                code = errno
            }
            guard retryInterruptions, code == EINTR,
                  interruptions < Self.maximumConsecutiveInterrupts
            else { throw system(operation, code) }
            interruptions += 1
        }
    }

    func fullSync(
        _ descriptor: Int32,
        call: SettingsPrimaryPublicationSystemCall,
        operation: String
    ) throws {
        do {
            try callStatus(call, operation: operation, retryInterruptions: true) {
                fcntl(descriptor, F_FULLFSYNC)
            }
        } catch SettingsPrimaryPublicationFailure.system(let failure)
            where [ENOTSUP, ENOTTY, EINVAL].contains(failure.code)
        {
            try callStatus(.syncFallback, operation: operation, retryInterruptions: true) {
                fsync(descriptor)
            }
        }
    }

    func sameIdentity(
        _ lhs: SettingsPrimaryFileMetadata,
        _ rhs: SettingsPrimaryFileMetadata?
    ) -> Bool {
        guard let rhs else {
            return false
        }
        return lhs.identity == rhs.identity
    }

    private func system(
        _ operation: String,
        _ code: Int32
    ) -> SettingsPrimaryPublicationFailure {
        .system(
            .init(operation: operation, code: code)
        )
    }
}

/// Deliberately unguarded: function-local scratch state. One instance is
/// created inside `publish` and reaches the private helpers of that same
/// synchronous call only as a plain parameter; no `@escaping` or `@Sendable`
/// closure captures it, so no second thread can observe it. Strict locality is
/// the whole invariant — capturing an instance anywhere would need a lock
/// instead.
final class PublicationResources: @unchecked Sendable {
    var descriptor: Int32 = -1
    var displacedDescriptor: Int32 = -1
    var name = ""
    var identity: SettingsPrimaryFileMetadata?
    var effectPossible = false
    var pathMovedToPrimary = false
    var swapProofComplete = false
    var displacedPriorRemoved = false
    var cleanupPriorVerified = false
}
