import Darwin
import Foundation

enum SettingsPrimaryPreparedPrior: Equatable, Sendable {
    case missing
    case current(bytes: Data, token: SettingsVersionToken)
}

struct SettingsPrimaryPreparedPublication: Equatable, Sendable {
    let prior: SettingsPrimaryPreparedPrior
    let targetDocument: SettingsDocument
    let targetBytes: Data
    let targetToken: SettingsVersionToken
}

indirect enum SettingsPrimaryPublicationFailure:
    Error,
    Equatable,
    Sendable
{
    case invalidRequest(String)
    case system(SettingsPrimaryMutationLockSystemFailure)
    case lockedRead(SettingsPrimaryLockedInspectionError)
    case compareAndSwapMismatch
    case writeNoProgress
    case publishedIdentityMismatch
    case displacedPriorMismatch
}

enum SettingsPrimaryPublicationResidual: Equatable, Sendable {
    case possiblePreservedPath(name: String)
    case displacedPrior(name: String, token: SettingsVersionToken)
}

struct SettingsPrimaryPublicationEvidence: Equatable, Sendable {
    let classification: SettingsPrimaryMutationClassification
    let targetProofEligible: Bool
    let failure: SettingsPrimaryPublicationFailure
    let classificationReadFailure: SettingsPrimaryLockedInspectionError?
    let closeFailures: [SettingsPrimaryMutationLockSystemFailure]
    let residual: SettingsPrimaryPublicationResidual?
}

enum SettingsPrimaryPublicationResult: Equatable, Sendable {
    case committed(residual: SettingsPrimaryPublicationResidual?)
    case failed(SettingsPrimaryPublicationEvidence)
}

enum SettingsPrimaryPublicationSystemCall: Sendable, Equatable {
    case createTemporary
    case inspectTemporary
    case setTemporaryMode
    case reinspectTemporary
    case inspectTemporaryPath
    case syncTemporary
    case renameMissing
    case renameCurrent
    case syncSettings
    case inspectPublishedPrimaryPath
    case openDisplacedPrior
    case inspectDisplacedPrior
    case inspectDisplacedPriorPath
    case closeTemporary
    case closeDisplacedPrior
}

enum SettingsPrimaryPublicationWriteDirective: Sendable, Equatable {
    case system
    case failure(Int32)
    case limit(Int)
    case zero
}

enum SettingsPrimaryPublicationBoundary: Sendable, Equatable {
    case afterTemporaryOpen
    case beforeCompareAndSwap
    case afterCompareAndSwap
    case beforeRename
    case afterRename
    case beforePostflight
}

struct SettingsPrimaryPublication: @unchecked Sendable {
    typealias SystemCallHook =
        @Sendable (SettingsPrimaryPublicationSystemCall) -> Int32?
    typealias WriteHook = @Sendable (
        Int32,
        Int,
        Int
    ) -> SettingsPrimaryPublicationWriteDirective
    typealias ACLHook =
        @Sendable (Int32) -> SettingsPrimaryACLDirective
    typealias BoundaryHook =
        @Sendable (SettingsPrimaryPublicationBoundary) -> Void
    typealias NameSource = @Sendable () -> UInt64
    typealias LockedRead = @Sendable () -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >

    static let temporaryPrefix = SettingsPublicationResidualNaming.prefix
    static let temporaryAttemptLimit = 8
    static let maximumConsecutiveInterrupts = 64

    private let systemCallHook: SystemCallHook
    private let writeHook: WriteHook
    private let aclHook: ACLHook
    private let boundaryHook: BoundaryHook
    private let nameSource: NameSource

    init(
        systemCallHook: @escaping SystemCallHook = { _ in nil },
        writeHook: @escaping WriteHook = { _, _, _ in .system },
        aclHook: @escaping ACLHook = { _ in .system },
        boundaryHook: @escaping BoundaryHook = { _ in },
        nameSource: @escaping NameSource = {
            UInt64.random(in: UInt64.min ... UInt64.max)
        }
    ) {
        self.systemCallHook = systemCallHook
        self.writeHook = writeHook
        self.aclHook = aclHook
        self.boundaryHook = boundaryHook
        self.nameSource = nameSource
    }

    func publish(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        readPrimary: @escaping LockedRead
    ) -> SettingsPrimaryPublicationResult {
        if let failure = validate(request) {
            return .failed(
                .init(
                    classification: .indeterminate,
                    targetProofEligible: false,
                    failure: failure,
                    classificationReadFailure: nil,
                    closeFailures: [],
                    residual: nil
                )
            )
        }

        let resources = PublicationResources()
        do {
            try createTemporary(
                request,
                settingsDescriptor: settingsDescriptor,
                resources: resources
            )
            try writeAll(
                request.targetBytes,
                descriptor: resources.descriptor
            )
            try verifyWrittenTemporary(
                request,
                settingsDescriptor: settingsDescriptor,
                resources: resources
            )
            try fullSync(
                resources.descriptor,
                call: .syncTemporary,
                operation: "synchronize settings publication temporary"
            )

            boundaryHook(.beforeCompareAndSwap)
            try verifyWrittenTemporary(
                request,
                settingsDescriptor: settingsDescriptor,
                resources: resources
            )
            let observed = readPrimary()
            guard exactPrior(observed, request: request) else {
                return finishFailure(
                    .compareAndSwapMismatch,
                    request: request,
                    resources: resources,
                    readPrimary: readPrimary
                )
            }
            boundaryHook(.afterCompareAndSwap)
            boundaryHook(.beforeRename)
            resources.effectPossible = true
            try publishTemporary(
                request,
                settingsDescriptor: settingsDescriptor,
                name: resources.name
            )
            boundaryHook(.afterRename)
            try verifyPublishedTarget(
                request,
                settingsDescriptor: settingsDescriptor,
                resources: resources
            )
            if case .current = request.prior {
                try openAndVerifyDisplacedPrior(
                    request,
                    settingsDescriptor: settingsDescriptor,
                    resources: resources
                )
                resources.swapProofComplete = true
            } else {
                resources.pathMovedToPrimary = true
            }
            try fullSync(
                settingsDescriptor,
                call: .syncSettings,
                operation: "synchronize Settings publication"
            )
            try verifyPublishedTarget(
                request,
                settingsDescriptor: settingsDescriptor,
                resources: resources
            )
            if case .current = request.prior {
                resources.swapProofComplete = false
                try verifyDisplacedPrior(
                    request,
                    settingsDescriptor: settingsDescriptor,
                    resources: resources
                )
                resources.swapProofComplete = true
            }

            boundaryHook(.beforePostflight)
            let postflight = readPrimary()
            guard exactTarget(postflight, request: request) else {
                return finishFailure(
                    postflightFailure(postflight),
                    request: request,
                    resources: resources,
                    readPrimary: readPrimary
                )
            }

            let closeFailures = closePublicationDescriptors(resources)
            guard closeFailures.isEmpty else {
                return .failed(
                    .init(
                        classification: .target,
                        targetProofEligible: true,
                        failure: .system(
                            .init(
                                operation:
                                    "finalize settings publication",
                                code: EIO
                            )
                        ),
                        classificationReadFailure: nil,
                        closeFailures: closeFailures,
                        residual: residual(
                            request,
                            resources: resources,
                            committed: true
                        )
                    )
                )
            }
            return .committed(
                residual: residual(
                    request,
                    resources: resources,
                    committed: true
                )
            )
        } catch let failure as SettingsPrimaryPublicationFailure {
            return finishFailure(
                failure,
                request: request,
                resources: resources,
                readPrimary: readPrimary
            )
        } catch {
            return finishFailure(
                .system(
                    .init(
                        operation: "unexpected settings publication",
                        code: EIO
                    )
                ),
                request: request,
                resources: resources,
                readPrimary: readPrimary
            )
        }
    }

    private func validate(
        _ request: SettingsPrimaryPreparedPublication
    ) -> SettingsPrimaryPublicationFailure? {
        guard !request.targetBytes.isEmpty,
              request.targetBytes.count
                <= SettingsRepository.maximumPrimaryBytes
        else {
            return .invalidRequest("target byte bounds")
        }
        guard SettingsSourceSHA256(request.targetBytes)
                == request.targetToken.sourceSHA256,
              request.targetDocument.revision
                == request.targetToken.revision,
              request.targetDocument.schemaVersion
                == SettingsDocument.currentSchemaVersion,
              request.targetToken.revision.rawValue > 0
        else {
            return .invalidRequest("target token")
        }
        let codec = SettingsDocumentCodec()
        switch codec.decode(request.targetBytes) {
        case .current(let decoded):
            guard decoded == request.targetDocument,
                  (try? codec.encode(decoded)) == request.targetBytes
            else {
                return .invalidRequest("target canonical bytes")
            }
        default:
            return .invalidRequest("target document")
        }

        switch request.prior {
        case .missing:
            guard request.targetToken.revision.rawValue == 1 else {
                return .invalidRequest("missing target revision")
            }
        case .current(let bytes, let token):
            guard bytes.count <= SettingsRepository.maximumPrimaryBytes,
                  SettingsSourceSHA256(bytes) == token.sourceSHA256
            else {
                return .invalidRequest("prior token")
            }
            guard case .current(let document) =
                SettingsDocumentCodec().decode(bytes),
                document.revision == token.revision,
                token.revision.rawValue < UInt64.max,
                request.targetToken.revision.rawValue
                    == token.revision.rawValue + 1
            else {
                return .invalidRequest("prior document")
            }
        }
        return nil
    }

    private func createTemporary(
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
            operation: "set settings publication temporary mode"
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

    private func writeAll(
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

    private func verifyWrittenTemporary(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        resources: PublicationResources
    ) throws {
        let descriptor = try metadata(
            resources.descriptor,
            call: .reinspectTemporary,
            operation: "verify written settings publication temporary"
        )
        try validateTemporary(descriptor)
        guard descriptor.size == Int64(request.targetBytes.count),
              sameIdentity(descriptor, resources.identity),
              try exactDescriptorBytes(
                  resources.descriptor,
                  expected: request.targetBytes,
                  token: request.targetToken
              )
        else {
            throw SettingsPrimaryPublicationFailure
                .invalidRequest("written temporary metadata")
        }
        try validateACL(resources.descriptor)
        let path = try pathMetadata(
            settingsDescriptor,
            resources.name,
            call: .inspectTemporaryPath,
            operation: "verify written settings publication temporary path"
        )
        guard descriptor == path else {
            throw SettingsPrimaryPublicationFailure
                .invalidRequest("written temporary path")
        }
        resources.identity = descriptor
    }

    private func publishTemporary(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        name: String
    ) throws {
        switch request.prior {
        case .missing:
            try callStatus(
                .renameMissing,
                operation: "publish missing settings primary"
            ) {
                renameatx_np(
                    settingsDescriptor,
                    name,
                    settingsDescriptor,
                    SettingsPrimaryLocation.fileName,
                    UInt32(RENAME_EXCL)
                )
            }
        case .current:
            try callStatus(
                .renameCurrent,
                operation: "publish current settings primary"
            ) {
                renameatx_np(
                    settingsDescriptor,
                    name,
                    settingsDescriptor,
                    SettingsPrimaryLocation.fileName,
                    UInt32(RENAME_SWAP)
                )
            }
        }
    }

    private func verifyPublishedTarget(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        resources: PublicationResources
    ) throws {
        let descriptor = try metadata(
            resources.descriptor,
            call: .reinspectTemporary,
            operation: "verify published target descriptor"
        )
        try validateTemporary(descriptor)
        try validateACL(resources.descriptor)
        guard descriptor.size == Int64(request.targetBytes.count),
              sameIdentity(descriptor, resources.identity),
              try exactDescriptorBytes(
                  resources.descriptor,
                  expected: request.targetBytes,
                  token: request.targetToken
              )
        else {
            throw SettingsPrimaryPublicationFailure
                .publishedIdentityMismatch
        }
        let path = try pathMetadata(
            settingsDescriptor,
            SettingsPrimaryLocation.fileName,
            call: .inspectPublishedPrimaryPath,
            operation: "verify published primary target path"
        )
        guard descriptor == path else {
            throw SettingsPrimaryPublicationFailure
                .publishedIdentityMismatch
        }
    }

    private func openAndVerifyDisplacedPrior(
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

    private func verifyDisplacedPrior(
        _ request: SettingsPrimaryPreparedPublication,
        settingsDescriptor: Int32,
        resources: PublicationResources
    ) throws {
        guard case .current(let priorBytes, let priorToken) =
            request.prior,
            resources.displacedDescriptor >= 0
        else {
            throw SettingsPrimaryPublicationFailure
                .displacedPriorMismatch
        }
        let descriptor = try metadata(
            resources.displacedDescriptor,
            call: .inspectDisplacedPrior,
            operation: "inspect displaced prior settings"
        )
        try validateTemporary(descriptor)
        try validateACL(resources.displacedDescriptor)
        let path = try pathMetadata(
            settingsDescriptor,
            resources.name,
            call: .inspectDisplacedPriorPath,
            operation: "inspect displaced prior settings path"
        )
        guard descriptor == path,
              descriptor.size == Int64(priorBytes.count),
              try exactDescriptorBytes(
                  resources.displacedDescriptor,
                  expected: priorBytes,
                  token: priorToken
              )
        else {
            throw SettingsPrimaryPublicationFailure
                .displacedPriorMismatch
        }
    }

    private func finishFailure(
        _ primary: SettingsPrimaryPublicationFailure,
        request: SettingsPrimaryPreparedPublication,
        resources: PublicationResources,
        readPrimary: @escaping LockedRead
    ) -> SettingsPrimaryPublicationResult {
        let closeFailures = closePublicationDescriptors(resources)
        let observed = readPrimary()
        var classification = classify(observed, request: request)
        if case .current = request.prior,
           resources.effectPossible,
           !resources.swapProofComplete,
           classification == .target
        {
            classification = .neither
        }
        let readFailure: SettingsPrimaryLockedInspectionError?
        if case .failure(let failure) = observed {
            readFailure = failure
        } else {
            readFailure = nil
        }
        return .failed(
            .init(
                classification: classification,
                targetProofEligible: targetProofEligible(
                    request,
                    resources: resources
                ),
                failure: primary,
                classificationReadFailure: readFailure,
                closeFailures: closeFailures,
                residual: residual(
                    request,
                    resources: resources,
                    committed: false
                )
            )
        )
    }

    private func closePublicationDescriptors(
        _ resources: PublicationResources
    ) -> [SettingsPrimaryMutationLockSystemFailure] {
        var failures: [SettingsPrimaryMutationLockSystemFailure] = []
        if resources.displacedDescriptor >= 0 {
            failures.append(
                contentsOf: closeDescriptor(
                    &resources.displacedDescriptor,
                    call: .closeDisplacedPrior,
                    operation: "close displaced prior settings"
                )
            )
        }
        failures.append(
            contentsOf: closeDescriptor(
                &resources.descriptor,
                call: .closeTemporary,
                operation: "close settings publication target"
            )
        )
        return failures
    }

    private func closeDescriptor(
        _ storedDescriptor: inout Int32,
        call: SettingsPrimaryPublicationSystemCall,
        operation: String
    ) -> [SettingsPrimaryMutationLockSystemFailure] {
        guard storedDescriptor >= 0 else {
            return []
        }
        let descriptor = storedDescriptor
        storedDescriptor = -1
        let injected = systemCallHook(call)
        let result = Darwin.close(descriptor)
        if let code = injected {
            return [
                .init(
                    operation: operation,
                    code: code
                ),
            ]
        }
        guard result != 0 else {
            return []
        }
        return [
            .init(
                operation: operation,
                code: errno
            ),
        ]
    }

    private func residual(
        _ request: SettingsPrimaryPreparedPublication,
        resources: PublicationResources,
        committed: Bool
    ) -> SettingsPrimaryPublicationResidual? {
        guard !resources.name.isEmpty else {
            return nil
        }
        if committed,
           case .current(_, let token) = request.prior,
           resources.swapProofComplete
        {
            return .displacedPrior(
                name: resources.name,
                token: token
            )
        }
        if resources.pathMovedToPrimary,
           case .missing = request.prior
        {
            return nil
        }
        return .possiblePreservedPath(name: resources.name)
    }

    private func targetProofEligible(
        _ request: SettingsPrimaryPreparedPublication,
        resources: PublicationResources
    ) -> Bool {
        switch request.prior {
        case .missing:
            return resources.pathMovedToPrimary
        case .current:
            return resources.swapProofComplete
        }
    }

    private func exactDescriptorBytes(
        _ descriptor: Int32,
        expected: Data,
        token: SettingsVersionToken
    ) throws -> Bool {
        guard expected.count <= SettingsRepository.maximumPrimaryBytes else {
            return false
        }
        var actual = Data(count: expected.count)
        let byteCount = actual.count
        var offset = 0
        var interrupts = 0
        while offset < byteCount {
            let count: Int = actual.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else {
                    return 0
                }
                return pread(
                    descriptor,
                    base.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if count < 0 {
                if errno == EINTR {
                    interrupts += 1
                    guard interrupts <= Self.maximumConsecutiveInterrupts
                    else {
                        return false
                    }
                    continue
                }
                throw system("read publication proof descriptor", errno)
            }
            guard count > 0 else {
                return false
            }
            interrupts = 0
            offset += count
        }
        var extra: UInt8 = 0
        let trailing = pread(
            descriptor,
            &extra,
            1,
            off_t(expected.count)
        )
        guard trailing == 0,
              actual == expected,
              SettingsSourceSHA256(actual) == token.sourceSHA256
        else {
            return false
        }
        return true
    }

    private func exactPrior(
        _ observed: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >,
        request: SettingsPrimaryPreparedPublication
    ) -> Bool {
        switch (request.prior, observed) {
        case (.missing, .success(.missing)):
            return true
        case (
            .current(let expected, _),
            .success(.bytes(let actual))
        ):
            return expected == actual
        default:
            return false
        }
    }

    private func exactTarget(
        _ observed: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >,
        request: SettingsPrimaryPreparedPublication
    ) -> Bool {
        guard case .success(.bytes(let bytes)) = observed else {
            return false
        }
        return bytes == request.targetBytes
            && SettingsSourceSHA256(bytes)
                == request.targetToken.sourceSHA256
    }

    private func classify(
        _ observed: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >,
        request: SettingsPrimaryPreparedPublication
    ) -> SettingsPrimaryMutationClassification {
        if exactTarget(observed, request: request) {
            return .target
        }
        if exactPrior(observed, request: request) {
            return .prior
        }
        switch observed {
        case .success:
            return .neither
        case .failure:
            return .indeterminate
        }
    }

    private func postflightFailure(
        _ observed: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >
    ) -> SettingsPrimaryPublicationFailure {
        switch observed {
        case .failure(let error):
            return .lockedRead(error)
        case .success:
            return .compareAndSwapMismatch
        }
    }

    private func metadata(
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

    private func pathMetadata(
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

    private func validateTemporary(
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

    private func validateACL(_ descriptor: Int32) throws {
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

    private func callStatus(
        _ call: SettingsPrimaryPublicationSystemCall,
        operation: String,
        _ body: () -> Int32
    ) throws {
        if let code = systemCallHook(call) {
            throw system(operation, code)
        }
        let result = body()
        guard result == 0 else {
            throw system(operation, errno)
        }
    }

    private func fullSync(
        _ descriptor: Int32,
        call: SettingsPrimaryPublicationSystemCall,
        operation: String
    ) throws {
        try callStatus(call, operation: operation) {
            fcntl(descriptor, F_FULLFSYNC)
        }
    }

    private func sameIdentity(
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

private final class PublicationResources: @unchecked Sendable {
    var descriptor: Int32 = -1
    var displacedDescriptor: Int32 = -1
    var name = ""
    var identity: SettingsPrimaryFileMetadata?
    var effectPossible = false
    var pathMovedToPrimary = false
    var swapProofComplete = false
}
