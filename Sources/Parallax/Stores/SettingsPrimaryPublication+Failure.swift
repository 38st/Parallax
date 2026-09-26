import Darwin
import Foundation

extension SettingsPrimaryPublication {
    func finishFailure(
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

    func closePublicationDescriptors(
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
        let outcome = SettingsDescriptorClose.descriptor(descriptor) {
            systemCallHook(call)
        }
        guard case .failure(let code) = outcome else {
            return []
        }
        return [
            .init(
                operation: operation,
                code: code
            ),
        ]
    }

    func residual(
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

    func exactPrior(
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

    func exactTarget(
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

    func postflightFailure(
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
}
