import Foundation

@MainActor
final class NSWorkspaceApplicationProcessProvider:
    WorkspaceApplicationProcessProviding
{
    private let processInspector: any ProcessIdentityInspecting
    private let runtime: any WorkspaceApplicationProcessRuntime

    init(
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector(),
        runtime: any WorkspaceApplicationProcessRuntime =
            makeNSWorkspaceApplicationProcessRuntime()
    ) {
        self.processInspector = processInspector
        self.runtime = runtime
    }

    func runningProcesses() -> [WorkspaceApplicationProcess] {
        let rawByProcessIdentifier = Dictionary(
            grouping: runtime.runningApplications(),
            by: \.processIdentifier
        )
        return rawByProcessIdentifier.values.flatMap {
            applications -> [WorkspaceApplicationProcess] in
            var processIdentities: [ProcessStartIdentity] = []
            var applicationIdentities:
                [WorkspaceApplicationBundleIdentity] = []
            for application in applications {
                guard !application.isTerminated,
                      case .live(let first) = processInspector.inspect(
                          processIdentifier:
                              application.processIdentifier
                      ),
                      first.processIdentifier
                          == application.processIdentifier,
                      case .live(let second) = processInspector.inspect(
                          processIdentifier:
                              application.processIdentifier
                      ),
                      second == first,
                      let bundleURL = application.bundleURL,
                      let bundleIdentifier = application.bundleIdentifier,
                      !bundleIdentifier.isEmpty
                else {
                    // Any unverifiable duplicate for this PID makes the raw
                    // enumeration ambiguous; never salvage a preferred row.
                    return []
                }
                processIdentities.append(first)
                applicationIdentities.append(
                    WorkspaceApplicationBundleIdentity(
                        bundleURL: bundleURL,
                        bundleIdentifier: bundleIdentifier
                    )
                )
            }
            guard let process = processIdentities.first,
                  processIdentities.allSatisfy({ $0 == process }),
                  let application = applicationIdentities.first,
                  applicationIdentities.allSatisfy({
                      $0 == application
                  })
            else {
                return []
            }
            return [
                WorkspaceApplicationProcess(
                    identity: WorkspaceProcessIdentity(
                        process: process,
                        application: application
                    )
                )
            ]
        }
    }

    func requestTermination(
        of identity: WorkspaceProcessIdentity
    ) -> WorkspaceProcessOperationResult {
        switch resolve(identity) {
        case .failure(let result):
            return result
        case .success:
            break
        }
        switch resolve(identity) {
        case .failure(let result):
            return result
        case .success(let application):
            return application.requestTermination()
                ? .accepted
                : .requestRejected
        }
    }

    func requestActivation(
        of identity: WorkspaceProcessIdentity
    ) -> WorkspaceProcessOperationResult {
        let initial: any WorkspaceApplicationOperationHandle
        switch resolve(identity) {
        case .failure(let result):
            return result
        case .success(let application):
            initial = application
        }
        runtime.yieldActivation(to: initial)

        let coordinated: any WorkspaceApplicationOperationHandle
        switch resolve(identity) {
        case .failure(let result):
            return result
        case .success(let application):
            coordinated = application
        }
        if coordinated.requestCoordinatedActivation() {
            return .accepted
        }

        // Revalidate after the coordinated request failed, then once more at
        // the last possible boundary before the compatibility fallback.
        switch resolve(identity) {
        case .failure(let result):
            return result
        case .success:
            break
        }
        switch resolve(identity) {
        case .failure(let result):
            return result
        case .success(let fallback):
            return fallback.requestFallbackActivation()
                ? .accepted
                : .requestRejected
        }
    }

    private func resolve(
        _ identity: WorkspaceProcessIdentity
    ) -> Result<
        any WorkspaceApplicationOperationHandle,
        WorkspaceProcessOperationResult
    > {
        switch processInspector.inspect(
            processIdentifier: identity.processIdentifier
        ) {
        case .dead:
            return .failure(.noLongerRunning)
        case .ambiguous:
            return .failure(.verificationUnavailable)
        case .live(let current) where current != identity.process:
            return .failure(.identityChanged)
        case .live:
            break
        }
        let matchingApplications = runtime.runningApplications().filter {
            $0.processIdentifier == identity.processIdentifier
        }
        guard matchingApplications.count == 1,
              let application = matchingApplications.first
        else {
            if matchingApplications.isEmpty {
                return classifyMissingHandle(identity)
            }
            return .failure(.verificationUnavailable)
        }
        guard !application.isTerminated else {
            return .failure(.noLongerRunning)
        }
        guard application.processIdentifier == identity.processIdentifier else {
            return .failure(.identityChanged)
        }
        guard let bundleURL = application.bundleURL,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              WorkspaceApplicationBundleIdentity(
                  bundleURL: bundleURL,
                  bundleIdentifier: bundleIdentifier
              ) == identity.application
        else {
            return .failure(.applicationChanged)
        }
        switch processInspector.inspect(
            processIdentifier: identity.processIdentifier
        ) {
        case .dead:
            return .failure(.noLongerRunning)
        case .ambiguous:
            return .failure(.verificationUnavailable)
        case .live(let current) where current != identity.process:
            return .failure(.identityChanged)
        case .live:
            return .success(application)
        }
    }

    private func classifyMissingHandle(
        _ identity: WorkspaceProcessIdentity
    ) -> Result<
        any WorkspaceApplicationOperationHandle,
        WorkspaceProcessOperationResult
    > {
        switch processInspector.inspect(
            processIdentifier: identity.processIdentifier
        ) {
        case .dead:
            return .failure(.noLongerRunning)
        case .ambiguous:
            return .failure(.verificationUnavailable)
        case .live(let current) where current != identity.process:
            return .failure(.identityChanged)
        case .live:
            return .failure(.verificationUnavailable)
        }
    }
}
