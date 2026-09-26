import Darwin
import Foundation

struct SettingsPrimaryPublication: Sendable {
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

    let systemCallHook: SystemCallHook
    let writeHook: WriteHook
    let aclHook: ACLHook
    let boundaryHook: BoundaryHook
    let nameSource: NameSource

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
                    postflightFailure(observed),
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

            if case .current = request.prior {
                // Publication is already durable. Cleanup cannot revoke that proof.
                do {
                    try verifyDisplacedPrior(
                        request, settingsDescriptor: settingsDescriptor, resources: resources
                    )
                    resources.cleanupPriorVerified = true
                    // Darwin has no unlink-by-descriptor. Remove only the verified
                    // name, then prove the pinned prior lost its last link.
                    try callStatus(.removeDisplacedPrior, operation: "remove verified prior settings") {
                        unlinkat(settingsDescriptor, resources.name, 0)
                    }
                    resources.cleanupPriorVerified = false
                    let removed = try metadata(
                        resources.displacedDescriptor, call: .inspectRemovedPrior,
                        operation: "verify displaced prior removal"
                    )
                    resources.displacedPriorRemoved = removed.linkCount == 0
                    if !resources.displacedPriorRemoved { resources.cleanupPriorVerified = false }
                } catch {
                    // Preserve any residual; a resurrected prior is harmless.
                }
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
}
