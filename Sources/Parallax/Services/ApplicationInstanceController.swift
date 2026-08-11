import Foundation

@MainActor
protocol WorkspaceApplicationProcessProviding: AnyObject {
    func runningProcesses() -> [WorkspaceApplicationProcess]
    func requestTermination(
        of identity: WorkspaceProcessIdentity
    ) -> WorkspaceProcessOperationResult
    func requestActivation(
        of identity: WorkspaceProcessIdentity
    ) -> WorkspaceProcessOperationResult
}

@MainActor
protocol ApplicationInstanceControlling: AnyObject {
    func instances(
        for application: ManagedApplication,
        trackedProcesses: [ProfileRunningProcess]
    ) -> [ManagedApplicationInstance]

    func requestQuit(
        _ instance: ManagedApplicationInstance,
        from application: ManagedApplication
    ) throws

    func requestActivate(
        _ instance: ManagedApplicationInstance,
        from application: ManagedApplication
    ) throws
}

@MainActor
final class ApplicationInstanceController:
    ApplicationInstanceControlling
{
    private let processProvider:
        any WorkspaceApplicationProcessProviding

    init() {
        processProvider = NSWorkspaceApplicationProcessProvider()
    }

    init(
        processProvider:
            any WorkspaceApplicationProcessProviding
    ) {
        self.processProvider = processProvider
    }

    func instances(
        for application: ManagedApplication,
        trackedProcesses: [ProfileRunningProcess]
    ) -> [ManagedApplicationInstance] {
        guard let expectedApplication = expectedIdentity(for: application)
        else {
            // Historical records without a bundle identifier cannot be safely
            // associated with live processes. Relinking supplies that identity.
            return []
        }
        let trackedByProcess = Dictionary(
            grouping: trackedProcesses,
            by: \.process
        )

        let unambiguousProcesses = Dictionary(
            grouping: processProvider.runningProcesses(),
            by: \.process
        ).values.compactMap { matches in
            guard let first = matches.first,
                  matches.allSatisfy({
                      $0.identity.application
                          == first.identity.application
                  })
            else {
                return Optional<WorkspaceApplicationProcess>.none
            }
            return first
        }.filter { $0.identity.application == expectedApplication }

        return unambiguousProcesses
            .map { running in
                let attribution = verifiedAttribution(
                    trackedByProcess[running.process] ?? [],
                    application: application
                )
                return ManagedApplicationInstance(
                    processIdentity: running.identity,
                    attribution: attribution.map {
                        TrackedProcessAttribution(
                            requestID: $0.tracked.requestID,
                            profileID: $0.profile.id,
                            profileStorageID: $0.profile.storageID,
                            profileName: $0.profile.name
                        )
                    }
                )
            }
            .sorted {
                if $0.process.startTimeSeconds
                    != $1.process.startTimeSeconds
                {
                    return $0.process.startTimeSeconds
                        < $1.process.startTimeSeconds
                }
                if $0.process.startTimeMicroseconds
                    != $1.process.startTimeMicroseconds
                {
                    return $0.process.startTimeMicroseconds
                        < $1.process.startTimeMicroseconds
                }
                return $0.processIdentifier < $1.processIdentifier
            }
    }

    func requestQuit(
        _ instance: ManagedApplicationInstance,
        from application: ManagedApplication
    ) throws {
        try validateAuthority(instance, application: application)
        try translate(
            processProvider.requestTermination(
                of: instance.processIdentity
            ),
            action: .quit,
            processIdentifier: instance.processIdentifier
        )
    }

    func requestActivate(
        _ instance: ManagedApplicationInstance,
        from application: ManagedApplication
    ) throws {
        try validateAuthority(instance, application: application)
        try translate(
            processProvider.requestActivation(
                of: instance.processIdentity
            ),
            action: .activation,
            processIdentifier: instance.processIdentifier
        )
    }

    private func expectedIdentity(
        for application: ManagedApplication
    ) -> WorkspaceApplicationBundleIdentity? {
        guard let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else {
            return nil
        }
        return WorkspaceApplicationBundleIdentity(
            bundleURL: URL(fileURLWithPath: application.appPath),
            bundleIdentifier: bundleIdentifier
        )
    }

    private func verifiedAttribution(
        _ candidates: [ProfileRunningProcess],
        application: ManagedApplication
    ) -> (tracked: ProfileRunningProcess, profile: LaunchProfile)? {
        let matches = candidates.compactMap { tracked -> (
            ProfileRunningProcess,
            LaunchProfile
        )? in
            guard tracked.identity.applicationID == application.id,
                  tracked.identity.applicationStorageID
                    == application.storageID,
                  let profile = application.profiles.first(where: {
                      $0.id == tracked.identity.profileID
                          && $0.storageID
                            == tracked.identity.profileStorageID
                  })
            else {
                return nil
            }
            return (tracked, profile)
        }
        guard matches.count == 1, let match = matches.first else {
            return nil
        }
        return (match.0, match.1)
    }

    private func validateAuthority(
        _ instance: ManagedApplicationInstance,
        application: ManagedApplication
    ) throws {
        guard let expected = expectedIdentity(for: application) else {
            throw ApplicationInstanceControllerError
                .applicationIdentityUnavailable
        }
        guard instance.processIdentity.application == expected else {
            throw ApplicationInstanceControllerError
                .applicationIdentityChanged(instance.processIdentifier)
        }
        guard instance.isActionable,
              let attribution = instance.attribution,
              application.profiles.contains(where: {
                  $0.id == attribution.profileID
                      && $0.storageID == attribution.profileStorageID
              })
        else {
            throw ApplicationInstanceControllerError
                .unmanagedInstance(instance.processIdentifier)
        }
    }

    private enum OperationAction {
        case activation
        case quit
    }

    private func translate(
        _ result: WorkspaceProcessOperationResult,
        action: OperationAction,
        processIdentifier: pid_t
    ) throws {
        switch result {
        case .accepted:
            return
        case .noLongerRunning:
            throw ApplicationInstanceControllerError
                .instanceNoLongerRunning
        case .identityChanged:
            throw ApplicationInstanceControllerError
                .processIdentityChanged(processIdentifier)
        case .applicationChanged:
            throw ApplicationInstanceControllerError
                .applicationIdentityChanged(processIdentifier)
        case .verificationUnavailable:
            throw ApplicationInstanceControllerError
                .verificationUnavailable(processIdentifier)
        case .requestRejected:
            switch action {
            case .activation:
                throw ApplicationInstanceControllerError
                    .activationRequestRejected(processIdentifier)
            case .quit:
                throw ApplicationInstanceControllerError
                    .quitRequestRejected(processIdentifier)
            }
        }
    }
}
