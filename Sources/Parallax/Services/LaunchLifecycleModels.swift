import AppKit
import Foundation

protocol ApplicationLaunching {
    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws
}

protocol TrackedApplicationLaunching: ApplicationLaunching {
    @discardableResult
    func launchTracked(
        application: ManagedApplication,
        profile: LaunchProfile,
        requestID: UUID,
        activityRegistry: ProfileActivityRegistry,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void,
        eventHandler: @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch
}

extension TrackedApplicationLaunching {
    @discardableResult
    func launchTracked(
        application: ManagedApplication,
        profile: LaunchProfile,
        requestID: UUID,
        activityRegistry: ProfileActivityRegistry,
        eventHandler: @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        try launchTracked(
            application: application,
            profile: profile,
            requestID: requestID,
            activityRegistry: activityRegistry,
            concurrentLaunchPolicy: .deny,
            lifecycleHandler: { _ in },
            eventHandler: eventHandler
        )
    }
}

protocol PreparedApplicationLaunching: ApplicationLaunching {
    func launch(
        prepared: PreparedLaunch,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws
}

protocol PreparedTrackedApplicationLaunching:
    PreparedApplicationLaunching,
    TrackedApplicationLaunching
{
    @discardableResult
    func launchTracked(
        prepared: PreparedLaunch,
        activityRegistry: ProfileActivityRegistry,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void,
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch
}

extension PreparedTrackedApplicationLaunching {
    @discardableResult
    func launchTracked(
        prepared: PreparedLaunch,
        activityRegistry: ProfileActivityRegistry,
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        try launchTracked(
            prepared: prepared,
            activityRegistry: activityRegistry,
            concurrentLaunchPolicy: .deny,
            lifecycleHandler: { _ in },
            eventHandler: eventHandler
        )
    }
}

enum TrackedApplicationLaunchEvent: Equatable, Sendable {
    case requested(requestID: UUID)
    case running(requestID: UUID, processIdentifier: pid_t)
    case trackingDegraded(
        requestID: UUID,
        processIdentifier: pid_t,
        message: String
    )
    case terminated(requestID: UUID, processIdentifier: pid_t)
    case failed(requestID: UUID, message: String)
}

enum ProfileLaunchLifecycleState: Equatable, Sendable {
    case requested
    case launching
    case running(processIdentifier: pid_t)
    case runningDegraded(processIdentifier: pid_t, message: String)
    case terminating(processIdentifier: pid_t)
    case terminated(processIdentifier: pid_t)
    case failed(message: String)

    var isTerminal: Bool {
        switch self {
        case .terminated, .failed:
            true
        case .requested, .launching, .running, .runningDegraded, .terminating:
            false
        }
    }
}

enum ManagedProcessTerminationDisposition:
    String,
    Codable,
    Equatable,
    Sendable
{
    case expected
    case unexpected
}

enum ProfileLaunchOpeningDisposition: Equatable, Sendable {
    case pending
    case outcomeUnknownAfterError(message: String)
    case preExistingSingletonRefused(processIdentifier: pid_t)
    case provenanceIndeterminate(
        processIdentifier: pid_t,
        reason: LaunchProcessProvenanceIndeterminacy
    )
}

struct ProfileLaunchLifecycleSnapshot: Equatable, Sendable {
    let requestID: UUID
    let identity: ProfileActivityIdentity
    let state: ProfileLaunchLifecycleState
    let processIdentity: WorkspaceProcessIdentity?
    let openingDisposition: ProfileLaunchOpeningDisposition
    let terminationDisposition:
        ManagedProcessTerminationDisposition?

    init(
        requestID: UUID,
        identity: ProfileActivityIdentity,
        state: ProfileLaunchLifecycleState,
        processIdentity: WorkspaceProcessIdentity? = nil,
        openingDisposition: ProfileLaunchOpeningDisposition = .pending,
        terminationDisposition:
            ManagedProcessTerminationDisposition? = nil
    ) {
        self.requestID = requestID
        self.identity = identity
        self.state = state
        self.processIdentity = processIdentity
        self.openingDisposition = openingDisposition
        self.terminationDisposition = terminationDisposition
    }

    /// Integration boundary used by stores/scenes before presenting a
    /// request-scoped update. A removed or replaced logical/storage identity
    /// cannot match accidentally.
    func matches(
        application: ManagedApplication,
        profile: LaunchProfile
    ) -> Bool {
        application.id == identity.applicationID
            && application.storageID == identity.applicationStorageID
            && profile.id == identity.profileID
            && profile.storageID == identity.profileStorageID
            && application.profiles.contains {
                $0.id == identity.profileID
                    && $0.storageID == identity.profileStorageID
            }
    }
}

protocol RunningApplicationInstance: AnyObject, Sendable {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    var workspaceApplication: NSRunningApplication? { get }
    func requestActivation(of identity: WorkspaceProcessIdentity)
}

extension RunningApplicationInstance {
    var workspaceApplication: NSRunningApplication? { nil }
    func requestActivation(of identity: WorkspaceProcessIdentity) {}
}

struct WorkspaceVerifiedActivationRequester: Sendable {
    private let operation:
        @MainActor @Sendable (WorkspaceProcessIdentity) -> Void
    private let schedule:
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    init(
        operation:
            @escaping @MainActor @Sendable (WorkspaceProcessIdentity) -> Void = {
                identity in
                _ = NSWorkspaceApplicationProcessProvider()
                    .requestActivation(of: identity)
            },
        schedule:
            @escaping @Sendable (
                @escaping @MainActor @Sendable () -> Void
            ) -> Void = { operation in
                Task { @MainActor in operation() }
            }
    ) {
        self.operation = operation
        self.schedule = schedule
    }

    func requestActivation(of identity: WorkspaceProcessIdentity) {
        schedule {
            operation(identity)
        }
    }
}

protocol WorkspaceApplicationOpening: Sendable {
    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    )
}

protocol RunningApplicationTerminationObservation: AnyObject, Sendable {
    func cancel()
}

protocol RunningApplicationTerminationObserving: Sendable {
    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation
}

enum LaunchError: LocalizedError {
    case missingApplication(String)
    case applicationDidNotOpen(String)
    case preparationRequired
    case trackedLaunchRequired
    case launchProcessProvenanceUnavailable
    case launchTimeBoundaryUnavailable

    var errorDescription: String? {
        switch self {
        case .missingApplication(let path):
            String(localized: "The application could not be found at \(path).")
        case .applicationDidNotOpen(let path):
            String(localized: "The application at \(path) did not open.")
        case .preparationRequired:
            String(
                localized:
                    "The launch configuration must be validated before opening the application."
            )
        case .trackedLaunchRequired:
            String(
                localized:
                    "The launch configuration must be validated before opening the application."
            )
        case .launchProcessProvenanceUnavailable,
             .launchTimeBoundaryUnavailable:
            String(
                localized:
                    "The selected application is not healthy enough to launch."
            )
        }
    }
}

/// Retains the running-process observation and activity lease until a terminal
/// event. The observer callback also retains this handle, so callers do not
/// have to keep it alive merely to avoid prematurely clearing active state.
