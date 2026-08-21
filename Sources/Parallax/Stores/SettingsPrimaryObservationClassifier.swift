import Foundation

enum SettingsPrimaryInitialObservation: Equatable {
    case missing
    case bytes(Data)
    case unreadable(SettingsPrimaryLockedInspectionError)
}

/// Pure classification for observations made while holding the settings
/// mutation lock. Publication, migration, and cleanup paths must agree on
/// whether the primary still contains the prior value, the target value, or
/// neither.
enum SettingsPrimaryObservationClassifier {
    static func initialObservation(
        _ result: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >
    ) -> SettingsPrimaryInitialObservation {
        switch result {
        case .success(.missing):
            return .missing
        case .success(.bytes(let bytes)):
            return .bytes(bytes)
        case .failure(let error):
            return .unreadable(error)
        }
    }

    static func classify(
        _ result: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >,
        initial: SettingsPrimaryInitialObservation
    ) -> SettingsPrimaryMutationClassification {
        switch (initial, result) {
        case (.unreadable, _):
            return .indeterminate
        case (.missing, .success(.missing)):
            return .prior
        case (
            .bytes(let expected),
            .success(.bytes(let actual))
        ) where expected == actual:
            return .prior
        case (_, .success):
            return .neither
        case (_, .failure):
            return .indeterminate
        }
    }

    static func classify(
        _ result: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >,
        prepared: SettingsPrimaryPreparedPublication
    ) -> SettingsPrimaryMutationClassification {
        switch result {
        case .failure:
            return .indeterminate
        case .success(.missing):
            if case .missing = prepared.prior {
                return .prior
            }
            return .neither
        case .success(.bytes(let bytes)):
            if bytes == prepared.targetBytes,
               SettingsSourceSHA256(bytes)
                    == prepared.targetToken.sourceSHA256
            {
                return .target
            }
            if case .current(let priorBytes, let priorToken) =
                prepared.prior,
               bytes == priorBytes,
               SettingsSourceSHA256(bytes) == priorToken.sourceSHA256
            {
                return .prior
            }
            return .neither
        }
    }

    static func cleanupClassification(
        _ classification: SettingsPrimaryMutationClassification,
        targetProofEligible: Bool?,
        reclassify: () -> SettingsPrimaryMutationClassification
    ) -> SettingsPrimaryMutationClassification {
        guard classification == .indeterminate else {
            return classification
        }
        let fresh = reclassify()
        guard fresh == .target,
              targetProofEligible == false
        else {
            return fresh
        }
        return .neither
    }
}

/// Reacquires the same mutation lock used by both normal settings writes and
/// migration writes, preserving any classification observed before cleanup
/// itself fails.
struct SettingsPrimaryLockReclassifier: @unchecked Sendable {
    let mutationLock: SettingsPrimaryMutationLock

    func classify(
        _ prepared: SettingsPrimaryPreparedPublication
    ) -> SettingsPrimaryMutationClassification {
        var observed: SettingsPrimaryMutationClassification?
        do {
            return try mutationLock.withMutationLock { authority in
                let value = SettingsPrimaryObservationClassifier.classify(
                    authority.readPrimary(),
                    prepared: prepared
                )
                observed = value
                return value
            }
        } catch {
            return observed ?? .indeterminate
        }
    }
}
