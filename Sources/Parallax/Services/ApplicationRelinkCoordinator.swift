import Foundation

struct ApplicationRelinkRequest: Sendable, Equatable {
    let requestID: UUID
    let targetApplication: ManagedApplication
    let candidateURL: URL
    let otherApplications: [ManagedApplication]

    init(
        requestID: UUID = UUID(),
        targetApplication: ManagedApplication,
        candidateURL: URL,
        otherApplications: [ManagedApplication]
    ) {
        self.requestID = requestID
        self.targetApplication = targetApplication
        self.candidateURL = candidateURL
        self.otherApplications = otherApplications
    }
}

enum ApplicationRelinkStoredPathState: Sendable, Equatable {
    case missing
    case available
    case unhealthy
}

enum ApplicationRelinkIdentityComparison: Sendable, Equatable {
    case sameBundleAtNewCanonicalPath
    case sameBundleDifferentInstallation
    case differentBundle(expected: String, actual: String)
    case targetBundleIdentityUnavailable(actual: String)
    case candidateIdentityUnavailable
}

enum ApplicationRelinkBlocker: Sendable, Hashable {
    case storedApplicationStillAvailable
    case storedPathUnhealthy
    case candidateInvalid
    case targetBundleIdentityUnavailable
    case candidateIsDifferentApplication
    case conflictsWithStoredApplication
}

enum ApplicationRelinkConflictKind: Sendable, Equatable {
    case candidateCanonicalPathAlreadyStored
    case bundleIdentifierUsedByAnotherInstallation
}

struct ApplicationRelinkConflict: Sendable, Equatable {
    let applicationID: UUID
    let applicationName: String
    let storedPath: String
    let bundleIdentifier: String?
    let kind: ApplicationRelinkConflictKind
}

/// The proposal is an immutable value only. Persisting it still requires the
/// store to compare `originalApplication` with current shared state.
struct ApplicationRelinkProposal: Sendable, Equatable {
    let requestID: UUID
    let originalApplication: ManagedApplication
    let application: ManagedApplication
    let canonicalCandidateURL: URL
    let verifiedBundleIdentifier: String
}

struct ApplicationRelinkAssessment: Sendable, Equatable {
    let requestID: UUID
    let targetApplicationID: UUID
    let storedPathState: ApplicationRelinkStoredPathState
    let storedApplicationHealth: ApplicationHealthReport
    let candidateHealth: ApplicationHealthReport
    let identityComparison: ApplicationRelinkIdentityComparison
    let blockers: Set<ApplicationRelinkBlocker>
    let conflicts: [ApplicationRelinkConflict]
    let proposal: ApplicationRelinkProposal?

    var canRelink: Bool {
        proposal != nil
    }
}

/// Performs bundle and canonical-path inspection without writing to the
/// filesystem or retaining shared library state.
struct ApplicationRelinkCoordinator: Sendable {
    private let healthService: LaunchHealthService

    init(fileSystem: any FileSystem = LocalFileSystem()) {
        healthService = LaunchHealthService(fileSystem: fileSystem)
    }

    func assess(
        _ request: ApplicationRelinkRequest
    ) async -> ApplicationRelinkAssessment {
        await Task.detached {
            assessReadOnly(request)
        }.value
    }

    private func assessReadOnly(
        _ request: ApplicationRelinkRequest
    ) -> ApplicationRelinkAssessment {
        let target = request.targetApplication
        let storedHealth = healthService.inspectApplication(
            ApplicationHealthInput(
                applicationID: target.id,
                applicationURL: URL(
                    fileURLWithPath: target.appPath,
                    isDirectory: true
                ),
                expectedBundleIdentifier: target.bundleIdentifier
            )
        )
        let storedPathState: ApplicationRelinkStoredPathState
        if storedHealth.issues.contains(where: {
            $0.code == .applicationMissing
        }) {
            storedPathState = .missing
        } else if storedHealth.isHealthy {
            storedPathState = .available
        } else {
            storedPathState = .unhealthy
        }

        let candidateHealth = healthService.inspectApplication(
            ApplicationHealthInput(
                applicationID: target.id,
                applicationURL: request.candidateURL,
                expectedBundleIdentifier: nil
            )
        )
        var blockers: Set<ApplicationRelinkBlocker> = []
        switch storedPathState {
        case .missing:
            break
        case .available:
            blockers.insert(.storedApplicationStillAvailable)
        case .unhealthy:
            blockers.insert(.storedPathUnhealthy)
        }

        let comparison: ApplicationRelinkIdentityComparison
        if !candidateHealth.isHealthy {
            blockers.insert(.candidateInvalid)
            comparison = .candidateIdentityUnavailable
        } else if let expected = normalizedBundleIdentifier(
            target.bundleIdentifier
        ), let actual = candidateHealth.bundleIdentifier {
            if expected == actual {
                comparison = storedPathState == .missing
                    ? .sameBundleAtNewCanonicalPath
                    : .sameBundleDifferentInstallation
            } else {
                blockers.insert(.candidateIsDifferentApplication)
                comparison = .differentBundle(
                    expected: expected,
                    actual: actual
                )
            }
        } else if let actual = candidateHealth.bundleIdentifier {
            blockers.insert(.targetBundleIdentityUnavailable)
            comparison = .targetBundleIdentityUnavailable(actual: actual)
        } else {
            blockers.insert(.candidateInvalid)
            comparison = .candidateIdentityUnavailable
        }

        let conflicts = conflicts(
            for: request,
            candidateHealth: candidateHealth
        )
        if !conflicts.isEmpty {
            blockers.insert(.conflictsWithStoredApplication)
        }

        let proposal: ApplicationRelinkProposal?
        if blockers.isEmpty,
           comparison == .sameBundleAtNewCanonicalPath,
           let canonicalCandidateURL =
               candidateHealth.canonicalApplicationURL,
           let bundleIdentifier = candidateHealth.bundleIdentifier
        {
            proposal = ApplicationRelinkProposal(
                requestID: request.requestID,
                originalApplication: target,
                application: ManagedApplication(
                    id: target.id,
                    storageID: target.storageID,
                    displayName: target.displayName,
                    bundleIdentifier: target.bundleIdentifier,
                    appPath: canonicalCandidateURL.path,
                    preset: target.preset,
                    baseStoragePath: target.baseStoragePath,
                    profiles: target.profiles
                ),
                canonicalCandidateURL: canonicalCandidateURL,
                verifiedBundleIdentifier: bundleIdentifier
            )
        } else {
            proposal = nil
        }

        return ApplicationRelinkAssessment(
            requestID: request.requestID,
            targetApplicationID: target.id,
            storedPathState: storedPathState,
            storedApplicationHealth: storedHealth,
            candidateHealth: candidateHealth,
            identityComparison: comparison,
            blockers: blockers,
            conflicts: conflicts,
            proposal: proposal
        )
    }

    private func conflicts(
        for request: ApplicationRelinkRequest,
        candidateHealth: ApplicationHealthReport
    ) -> [ApplicationRelinkConflict] {
        guard
            candidateHealth.isHealthy,
            let candidateCanonicalURL =
                candidateHealth.canonicalApplicationURL,
            let candidateBundleIdentifier =
                candidateHealth.bundleIdentifier
        else {
            return []
        }

        var result: [ApplicationRelinkConflict] = []
        for application in request.otherApplications
        where application.id != request.targetApplication.id {
            let otherHealth = healthService.inspectApplication(
                ApplicationHealthInput(
                    applicationID: application.id,
                    applicationURL: URL(
                        fileURLWithPath: application.appPath,
                        isDirectory: true
                    ),
                    expectedBundleIdentifier: application.bundleIdentifier
                )
            )
            if otherHealth.canonicalApplicationURL
                == candidateCanonicalURL
            {
                result.append(
                    ApplicationRelinkConflict(
                        applicationID: application.id,
                        applicationName: application.displayName,
                        storedPath: application.appPath,
                        bundleIdentifier: application.bundleIdentifier,
                        kind: .candidateCanonicalPathAlreadyStored
                    )
                )
            }
            let otherBundleIdentifier =
                otherHealth.bundleIdentifier
                ?? normalizedBundleIdentifier(
                    application.bundleIdentifier
                )
            if otherBundleIdentifier == candidateBundleIdentifier {
                result.append(
                    ApplicationRelinkConflict(
                        applicationID: application.id,
                        applicationName: application.displayName,
                        storedPath: application.appPath,
                        bundleIdentifier: application.bundleIdentifier,
                        kind:
                            .bundleIdentifierUsedByAnotherInstallation
                    )
                )
            }
        }
        return result
    }

    private func normalizedBundleIdentifier(
        _ bundleIdentifier: String?
    ) -> String? {
        guard
            let value = bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
