import Darwin
import Foundation

enum LaunchProcessProvenanceClassifier {
    static func classify(
        processIdentifier: pid_t,
        inspection: WorkspaceProcessIdentityInspection,
        preopenSnapshot: WorkspaceProcessSnapshot,
        launchBoundary: LaunchRequestTimeBoundary
    ) -> LaunchProcessProvenance {
        switch inspection {
        case .live(let identity):
            guard identity.process.isValidGettimeofdayTuple else {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .unverifiableIdentity
                )
            }
            guard identity.processIdentifier == processIdentifier else {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .processIdentifierMismatch
                )
            }
            guard preopenSnapshot.containsExpectedApplication(identity) else {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .unexpectedApplication
                )
            }
            if preopenSnapshot.processes.contains(identity) {
                return .preExisting(identity)
            }
            if preopenSnapshot.processes.contains(where: {
                $0.process == identity.process
                    && $0.application != identity.application
            }) {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .bundleIdentityChanged
                )
            }
            if preopenSnapshot.processes.contains(where: {
                $0.processIdentifier == processIdentifier
                    && $0.process != identity.process
            }) {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .processIdentifierReused
                )
            }
            guard launchBoundary.isStrictlyBefore(identity.process) else {
                return .indeterminate(
                    processIdentifier: processIdentifier,
                    reason: .processDidNotStartAfterLaunchBoundary
                )
            }
            // A same-user process can still start independently after this
            // boundary while Launch Services is handling the request. The
            // full returned identity check and process-local exact claim are
            // the remaining authority for that irreducible external race.
            // `.new` means the exact expected application identity was
            // verified after a complete pre-open snapshot and no process with
            // this PID existed in that snapshot.
            return .new(identity)
        case .exited:
            return .indeterminate(
                processIdentifier: processIdentifier,
                reason: .exitedBeforeVerification
            )
        case .indeterminate:
            return .indeterminate(
                processIdentifier: processIdentifier,
                reason: .unverifiableIdentity
            )
        }
    }
}

extension WorkspaceProcessSnapshot {
    fileprivate func containsExpectedApplication(
        _ identity: WorkspaceProcessIdentity
    ) -> Bool {
        guard identity.application.bundleURL == expectedApplication.bundleURL
        else {
            return false
        }
        guard
            let expectedIdentifier = expectedApplication.bundleIdentifier
        else {
            return false
        }
        return identity.application.bundleIdentifier == expectedIdentifier
    }
}

private extension ProcessStartIdentity {
    var isValidGettimeofdayTuple: Bool {
        processIdentifier > 0 && startTimeMicroseconds < 1_000_000
    }
}
