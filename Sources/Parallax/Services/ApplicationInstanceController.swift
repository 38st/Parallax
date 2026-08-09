import AppKit
import Foundation

struct WorkspaceApplicationProcess: Equatable, Sendable {
    let identity: WorkspaceProcessIdentity

    var process: ProcessStartIdentity { identity.process }
    var bundleURL: URL { identity.application.bundleURL }
    var bundleIdentifier: String? {
        identity.application.bundleIdentifier
    }

    init(
        process: ProcessStartIdentity,
        bundleURL: URL,
        bundleIdentifier: String?
    ) {
        identity = WorkspaceProcessIdentity(
            process: process,
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier
            )
        )
    }

    init(identity: WorkspaceProcessIdentity) {
        self.identity = identity
    }
}

struct ManagedApplicationInstance:
    Identifiable,
    Equatable,
    Sendable
{
    let processIdentity: WorkspaceProcessIdentity
    let requestID: UUID?
    let profileID: UUID?
    let profileStorageID: UUID?
    let profileName: String?
    let controlPresentation: ProcessAuthorityPresentation

    init(
        processIdentity: WorkspaceProcessIdentity,
        requestID: UUID?,
        profileID: UUID?,
        profileStorageID: UUID?,
        profileName: String?,
        controlPresentation: ProcessAuthorityPresentation? = nil
    ) {
        self.processIdentity = processIdentity
        self.requestID = requestID
        self.profileID = profileID
        self.profileStorageID = profileStorageID
        self.profileName = profileName
        let hasTrackedAttribution = requestID != nil
            && profileID != nil
            && profileStorageID != nil
            && profileName != nil
        self.controlPresentation = controlPresentation
            ?? (hasTrackedAttribution
                ? .verificationUnavailable
                : .outsideParallax)
    }

    var id: WorkspaceProcessIdentity { processIdentity }
    var process: ProcessStartIdentity { processIdentity.process }

    var processIdentifier: pid_t {
        processIdentity.processIdentifier
    }

    var displayName: String {
        profileName ?? String(localized: "Other instance")
    }

    var hasTrackedAttribution: Bool {
        requestID != nil
            && profileID != nil
            && profileStorageID != nil
            && profileName != nil
    }

    var isTrackedSpace: Bool { hasTrackedAttribution }

    var isActionable: Bool { controlPresentation.isActionable }

    var actionPresentation: ProcessAuthorityActionPresentation {
        ProcessAuthorityActionPresentation(
            canShow: isActionable,
            canQuit: isActionable,
            help: controlPresentation.actionHelp
        )
    }

    func presenting(
        _ presentation: ProcessAuthorityPresentation
    ) -> ManagedApplicationInstance {
        ManagedApplicationInstance(
            processIdentity: processIdentity,
            requestID: requestID,
            profileID: profileID,
            profileStorageID: profileStorageID,
            profileName: profileName,
            controlPresentation: presentation
        )
    }
}

struct ProcessAuthorityActionPresentation: Equatable, Sendable {
    let canShow: Bool
    let canQuit: Bool
    let help: String
}

enum ProcessAuthorityPresentation: Equatable, Sendable {
    case verifiedParallaxInstance
    case outsideParallax
    case verificationUnavailable

    var isActionable: Bool {
        self == .verifiedParallaxInstance
    }

    var detailLabel: String {
        switch self {
        case .verifiedParallaxInstance:
            String(localized: "Parallax space")
        case .outsideParallax:
            String(localized: "Outside Parallax · Informational only")
        case .verificationUnavailable:
            String(localized: "Process verification unavailable")
        }
    }

    var actionHelp: String {
        switch self {
        case .verifiedParallaxInstance:
            String(localized: "This exact process can be controlled by Parallax.")
        case .outsideParallax:
            String(localized: "This process was not opened and tracked by Parallax, so Show and Quit are unavailable.")
        case .verificationUnavailable:
            String(localized: "Parallax could not verify the exact process identity, so Show and Quit are unavailable.")
        }
    }
}

enum WorkspaceProcessOperationResult: Error, Equatable, Sendable {
    case accepted
    case noLongerRunning
    case identityChanged
    case applicationChanged
    case verificationUnavailable
    case requestRejected
}

enum ApplicationInstanceControllerError: LocalizedError {
    case instanceNoLongerRunning
    case processIdentityChanged(pid_t)
    case applicationIdentityChanged(pid_t)
    case verificationUnavailable(pid_t)
    case applicationIdentityUnavailable
    case unmanagedInstance(pid_t)
    case activationRequestRejected(pid_t)
    case quitRequestRejected(pid_t)

    var errorDescription: String? {
        switch self {
        case .instanceNoLongerRunning:
            String(localized: "This app instance is no longer running.")
        case .processIdentityChanged(let processIdentifier):
            String(
                localized:
                    "Parallax did not send the request because process \(processIdentifier) changed."
            )
        case .applicationIdentityChanged(let processIdentifier):
            String(
                localized:
                    "Parallax did not send the request because process \(processIdentifier) no longer belongs to this app."
            )
        case .verificationUnavailable(let processIdentifier):
            String(
                localized:
                    "Parallax did not send the request because it could not verify process \(processIdentifier)."
            )
        case .applicationIdentityUnavailable:
            String(
                localized:
                    "Parallax cannot verify this app because its bundle identifier is missing. Relink the app before controlling its processes."
            )
        case .unmanagedInstance(let processIdentifier):
            String(
                localized:
                    "Parallax did not send the request because process \(processIdentifier) is not an exact instance opened and tracked by Parallax."
            )
        case .activationRequestRejected:
            String(
                localized:
                    "The verified app instance did not accept the request to come forward."
            )
        case .quitRequestRejected:
            String(
                localized:
                    "The verified app instance did not accept the quit request."
            )
        }
    }
}

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
                    requestID: attribution?.tracked.requestID,
                    profileID: attribution?.profile.id,
                    profileStorageID: attribution?.profile.storageID,
                    profileName: attribution?.profile.name
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
              let profileID = instance.profileID,
              let profileStorageID = instance.profileStorageID,
              application.profiles.contains(where: {
                  $0.id == profileID
                      && $0.storageID == profileStorageID
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

@MainActor
protocol WorkspaceApplicationOperationHandle: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleURL: URL? { get }
    var bundleIdentifier: String? { get }
    var isTerminated: Bool { get }
    func requestTermination() -> Bool
    func requestCoordinatedActivation() -> Bool
    func requestFallbackActivation() -> Bool
}

@MainActor
protocol WorkspaceApplicationProcessRuntime: AnyObject {
    func runningApplications() -> [any WorkspaceApplicationOperationHandle]
    func yieldActivation(to application: any WorkspaceApplicationOperationHandle)
}

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
            NSWorkspaceApplicationProcessRuntime()
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

@MainActor
private final class NSWorkspaceApplicationProcessRuntime:
    WorkspaceApplicationProcessRuntime
{
    func runningApplications() -> [any WorkspaceApplicationOperationHandle] {
        NSWorkspace.shared.runningApplications.map {
            NSWorkspaceApplicationOperationHandle(application: $0)
        }
    }

    func yieldActivation(
        to application: any WorkspaceApplicationOperationHandle
    ) {
        guard let application = application
            as? NSWorkspaceApplicationOperationHandle
        else {
            return
        }
        NSApp.yieldActivation(to: application.application)
    }
}

@MainActor
private final class NSWorkspaceApplicationOperationHandle:
    WorkspaceApplicationOperationHandle
{
    let application: NSRunningApplication

    init(application: NSRunningApplication) {
        self.application = application
    }

    var processIdentifier: pid_t { application.processIdentifier }
    var bundleURL: URL? { application.bundleURL }
    var bundleIdentifier: String? { application.bundleIdentifier }
    var isTerminated: Bool { application.isTerminated }

    func requestTermination() -> Bool { application.terminate() }

    func requestCoordinatedActivation() -> Bool {
        application.activate(
            from: NSRunningApplication.current,
            options: [.activateAllWindows]
        )
    }

    func requestFallbackActivation() -> Bool {
        application.activate(options: [.activateAllWindows])
    }
}
