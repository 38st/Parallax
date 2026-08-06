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

struct ProfileLaunchLifecycleSnapshot: Equatable, Sendable {
    let requestID: UUID
    let identity: ProfileActivityIdentity
    let state: ProfileLaunchLifecycleState
    let terminationDisposition:
        ManagedProcessTerminationDisposition?

    init(
        requestID: UUID,
        identity: ProfileActivityIdentity,
        state: ProfileLaunchLifecycleState,
        terminationDisposition:
            ManagedProcessTerminationDisposition? = nil
    ) {
        self.requestID = requestID
        self.identity = identity
        self.state = state
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
}

extension RunningApplicationInstance {
    var workspaceApplication: NSRunningApplication? { nil }
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
        }
    }
}

/// Retains the running-process observation and activity lease until a terminal
/// event. The observer callback also retains this handle, so callers do not
/// have to keep it alive merely to avoid prematurely clearing active state.
final class TrackedApplicationLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryLock = NSLock()
    private let requestID: UUID
    private let identity: ProfileActivityIdentity
    private let activityRegistry: ProfileActivityRegistry
    private let eventHandler:
        @Sendable (TrackedApplicationLaunchEvent) -> Void
    private let lifecycleHandler:
        @Sendable (ProfileLaunchLifecycleSnapshot) -> Void
    private var activityLease: ProfileActivityLease?
    private var terminationObservation:
        (any RunningApplicationTerminationObservation)?
    private var runningInstance: (any RunningApplicationInstance)?
    private var isInstallingTerminationObservation = false
    private var pendingObservedTermination: pid_t?
    private var terminationWasRequested = false
    private var lifecycleBeforeTerminationRequest:
        ProfileLaunchLifecycleSnapshot?
    private var terminal = false
    private var latestEvent: TrackedApplicationLaunchEvent
    private var latestLifecycle: ProfileLaunchLifecycleSnapshot

    fileprivate init(
        requestID: UUID,
        identity: ProfileActivityIdentity,
        activityRegistry: ProfileActivityRegistry,
        activityLease: ProfileActivityLease,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void,
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) {
        self.requestID = requestID
        self.identity = identity
        self.activityRegistry = activityRegistry
        self.activityLease = activityLease
        self.lifecycleHandler = lifecycleHandler
        self.eventHandler = eventHandler
        latestEvent = .requested(requestID: requestID)
        latestLifecycle = ProfileLaunchLifecycleSnapshot(
            requestID: requestID,
            identity: identity,
            state: .requested
        )
    }

    var currentEvent: TrackedApplicationLaunchEvent {
        lock.withLock { latestEvent }
    }

    var currentLifecycle: ProfileLaunchLifecycleSnapshot {
        lock.withLock { latestLifecycle }
    }

    /// The production handle returned by `NSWorkspace`, retained until the
    /// process reaches a terminal state.
    var runningApplication: NSRunningApplication? {
        lock.withLock { runningInstance?.workspaceApplication }
    }

    fileprivate func didRequest() {
        deliveryLock.withLock {
            eventHandler(.requested(requestID: requestID))
            lifecycleHandler(currentLifecycle)
        }
    }

    fileprivate func didBeginOpening() {
        deliverLifecycle(.launching)
    }

    /// Records that a caller requested process termination. It does not itself
    /// terminate the process; the retained process handle and observer remain
    /// authoritative until the termination notification arrives.
    @discardableResult
    func noteTerminationRequested() -> Bool {
        let processIdentifier = lock.withLock {
            guard
                !terminal,
                let runningInstance
            else {
                return Optional<pid_t>.none
            }
            switch latestLifecycle.state {
            case .running, .runningDegraded:
                lifecycleBeforeTerminationRequest = latestLifecycle
                terminationWasRequested = true
                return runningInstance.processIdentifier
            case .requested, .launching, .terminating,
                 .terminated, .failed:
                return nil
            }
        }
        guard let processIdentifier else { return false }
        deliverLifecycle(
            .terminating(processIdentifier: processIdentifier)
        )
        return true
    }

    /// Marks the quit as intentional before invoking the operation that can
    /// synchronously deliver a termination notification. If the operation is
    /// rejected, the prior running lifecycle is restored.
    func performTerminationRequest(
        _ request: () throws -> Void
    ) throws {
        let marked = noteTerminationRequested()
        do {
            try request()
        } catch {
            if marked {
                cancelTerminationRequest()
            }
            throw error
        }
    }

    private func cancelTerminationRequest() {
        deliveryLock.withLock {
            let restored = lock.withLock {
                guard
                    !terminal,
                    terminationWasRequested,
                    let prior = lifecycleBeforeTerminationRequest,
                    case .terminating = latestLifecycle.state
                else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                terminationWasRequested = false
                lifecycleBeforeTerminationRequest = nil
                latestLifecycle = prior
                return prior
            }
            if let restored {
                lifecycleHandler(restored)
            }
        }
    }

    fileprivate func didOpen(
        _ application: any RunningApplicationInstance,
        observer: any RunningApplicationTerminationObserving
    ) {
        if application.isTerminated {
            didTerminate(processIdentifier: application.processIdentifier)
            return
        }

        let retained = lock.withLock {
            guard !terminal else { return false }
            runningInstance = application
            return true
        }
        guard retained else { return }
        let terminationObservedDuringInstallation = observeTermination(
            of: application,
            observer: observer
        )
        guard !application.isTerminated else {
            didTerminate(processIdentifier: application.processIdentifier)
            return
        }
        if terminationObservedDuringInstallation {
            // Compatibility event only. The identity-rich lifecycle does not
            // report durable running when termination won the observation
            // installation race.
            reportLegacyRunningEvent(
                processIdentifier: application.processIdentifier
            )
            didTerminate(processIdentifier: application.processIdentifier)
            return
        }

        do {
            try activityRegistry.recordRunningProcess(
                requestID: requestID,
                processIdentifier: application.processIdentifier
            )
        } catch ProfileActivityRegistryError.processExitedBeforeRegistration {
            didTerminate(processIdentifier: application.processIdentifier)
            return
        } catch let error as DurableLaunchActivityStoreError {
            if case .processAlreadyTracked = error {
                didFail(error)
            } else {
                didEnterDegradedTracking(
                    processIdentifier: application.processIdentifier,
                    error: error
                )
            }
            return
        } catch {
            didEnterDegradedTracking(
                processIdentifier: application.processIdentifier,
                error: error
            )
            return
        }

        let runningEvent = TrackedApplicationLaunchEvent.running(
            requestID: requestID,
            processIdentifier: application.processIdentifier
        )
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                latestEvent = runningEvent
                let lifecycle = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: .running(
                        processIdentifier: application.processIdentifier
                    )
                )
                latestLifecycle = lifecycle
                return lifecycle
            }
            guard let lifecycle else { return }
            lifecycleHandler(lifecycle)
            eventHandler(runningEvent)
        }
    }

    private func didEnterDegradedTracking(
        processIdentifier: pid_t,
        error: Error
    ) {
        let message = String(
            localized:
                "The application opened, but durable process tracking is unavailable: \(error.localizedDescription)"
        )
        let event = TrackedApplicationLaunchEvent.trackingDegraded(
            requestID: requestID,
            processIdentifier: processIdentifier,
            message: message
        )
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                latestEvent = event
                let lifecycle = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: .runningDegraded(
                        processIdentifier: processIdentifier,
                        message: message
                    )
                )
                latestLifecycle = lifecycle
                return lifecycle
            }
            guard let lifecycle else { return }
            lifecycleHandler(lifecycle)
            eventHandler(event)
        }
    }

    private func observeTermination(
        of application: any RunningApplicationInstance,
        observer: any RunningApplicationTerminationObserving
    ) -> Bool {
        lock.withLock {
            guard !terminal else { return }
            isInstallingTerminationObservation = true
            pendingObservedTermination = nil
        }
        let observation = observer.observeTermination(of: application) {
            [self] in
            let deferred = lock.withLock {
                guard isInstallingTerminationObservation else {
                    return false
                }
                pendingObservedTermination = application.processIdentifier
                return true
            }
            guard !deferred else { return }
            didTerminate(
                processIdentifier: application.processIdentifier
            )
        }
        install(observation)
        return lock.withLock {
            isInstallingTerminationObservation = false
            let observed = pendingObservedTermination != nil
            pendingObservedTermination = nil
            return observed
        }
    }

    private func reportLegacyRunningEvent(processIdentifier: pid_t) {
        deliveryLock.withLock {
            let event = TrackedApplicationLaunchEvent.running(
                requestID: requestID,
                processIdentifier: processIdentifier
            )
            let shouldReport = lock.withLock {
                guard !terminal else { return false }
                latestEvent = event
                return true
            }
            if shouldReport {
                eventHandler(event)
            }
        }
    }

    fileprivate func didFail(_ error: Error) {
        finish(
            with: .failed(
                requestID: requestID,
                message: error.localizedDescription
            )
        )
    }

    private func didTerminate(processIdentifier: pid_t) {
        finish(
            with: .terminated(
                requestID: requestID,
                processIdentifier: processIdentifier
            )
        )
    }

    private func install(
        _ observation: any RunningApplicationTerminationObservation
    ) {
        let shouldCancel = lock.withLock {
            if terminal {
                return true
            }
            terminationObservation = observation
            return false
        }
        if shouldCancel {
            observation.cancel()
        }
    }

    private func finish(with event: TrackedApplicationLaunchEvent) {
        deliveryLock.withLock {
            let resources = lock.withLock {
                guard !terminal else {
                    return (
                        lifecycle:
                            Optional<ProfileLaunchLifecycleSnapshot>.none,
                        lease: Optional<ProfileActivityLease>.none,
                        observation:
                            Optional<
                                any RunningApplicationTerminationObservation
                            >.none
                    )
                }
                terminal = true
                lifecycleBeforeTerminationRequest = nil
                latestEvent = event
                let state: ProfileLaunchLifecycleState
                switch event {
                case .terminated(_, let processIdentifier):
                    state = .terminated(
                        processIdentifier: processIdentifier
                    )
                case .failed(_, let message):
                    state = .failed(message: message)
                case .requested, .running, .trackingDegraded:
                    state = .failed(
                        message: String(
                            localized:
                                "Launch tracking ended without a terminal process result."
                        )
                    )
                }
                let lifecycle = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: state,
                    terminationDisposition: {
                        if case .terminated = state {
                            return terminationWasRequested
                                ? .expected
                                : .unexpected
                        }
                        return nil
                    }()
                )
                latestLifecycle = lifecycle
                let lease = activityLease
                activityLease = nil
                let observation = terminationObservation
                terminationObservation = nil
                runningInstance = nil
                return (
                    lifecycle: Optional(lifecycle),
                    lease: lease,
                    observation: observation
                )
            }

            guard let lifecycle = resources.lifecycle else { return }
            let completion: DurableLaunchCompletion
            switch event {
            case .terminated:
                completion = .terminated
            case .failed:
                completion = .failed
            case .requested, .running, .trackingDegraded:
                completion = .failed
            }
            try? activityRegistry.completeDurableLaunch(
                requestID: requestID,
                completion: completion
            )
            resources.observation?.cancel()
            resources.lease?.release()
            lifecycleHandler(lifecycle)
            eventHandler(event)
        }
    }

    private func deliverLifecycle(
        _ state: ProfileLaunchLifecycleState
    ) {
        deliveryLock.withLock {
            let lifecycle = lock.withLock {
                guard !terminal else {
                    return Optional<ProfileLaunchLifecycleSnapshot>.none
                }
                let snapshot = ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: identity,
                    state: state
                )
                latestLifecycle = snapshot
                return snapshot
            }
            if let lifecycle {
                lifecycleHandler(lifecycle)
            }
        }
    }
}

struct WorkspaceApplicationLauncher: PreparedTrackedApplicationLaunching {
    private let opener: any WorkspaceApplicationOpening
    private let terminationObserver:
        any RunningApplicationTerminationObserving

    init() {
        opener = NSWorkspaceApplicationOpener()
        terminationObserver = NSWorkspaceTerminationObserver()
    }

    init(
        opener: any WorkspaceApplicationOpening,
        terminationObserver: any RunningApplicationTerminationObserving
    ) {
        self.opener = opener
        self.terminationObserver = terminationObserver
    }

    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        throw LaunchError.preparationRequired
    }

    func launch(
        prepared: PreparedLaunch,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        let configuration = configuration(for: prepared)
        opener.openApplication(
            at: prepared.applicationURL,
            configuration: configuration
        ) { result in
            completion(result.map { _ in () })
        }
    }

    @discardableResult
    func launchTracked(
        application: ManagedApplication,
        profile: LaunchProfile,
        requestID: UUID,
        activityRegistry: ProfileActivityRegistry,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy = .deny,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void = {
                _ in
            },
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        throw LaunchError.preparationRequired
    }

    @discardableResult
    func launchTracked(
        prepared: PreparedLaunch,
        activityRegistry: ProfileActivityRegistry,
        concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy = .deny,
        lifecycleHandler:
            @escaping @Sendable (ProfileLaunchLifecycleSnapshot) -> Void = {
                _ in
            },
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        let identity = ProfileActivityIdentity(
            applicationID: prepared.applicationID,
            applicationStorageID: prepared.applicationStorageID,
            profileID: prepared.profileID,
            profileStorageID: prepared.profileStorageID
        )
        let lease = try activityRegistry.acquireLaunchLease(
            identity: identity,
            requestID: prepared.requestID,
            concurrentLaunchPolicy: concurrentLaunchPolicy
        )
        let launch = TrackedApplicationLaunch(
            requestID: prepared.requestID,
            identity: identity,
            activityRegistry: activityRegistry,
            activityLease: lease,
            lifecycleHandler: lifecycleHandler,
            eventHandler: eventHandler
        )
        launch.didRequest()
        do {
            try activityRegistry.markLaunchOpening(
                requestID: prepared.requestID
            )
        } catch {
            launch.didFail(error)
            throw error
        }
        launch.didBeginOpening()

        let configuration = configuration(for: prepared)
        opener.openApplication(
            at: prepared.applicationURL,
            configuration: configuration
        ) { [terminationObserver] result in
            switch result {
            case .success(let runningApplication):
                launch.didOpen(
                    runningApplication,
                    observer: terminationObserver
                )
            case .failure(let error):
                launch.didFail(error)
            }
        }
        return launch
    }

    private func configuration(
        for prepared: PreparedLaunch
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = prepared.arguments
        configuration.environment = prepared.environment
        return configuration
    }
}

private final class WorkspaceRunningApplication:
    RunningApplicationInstance,
    @unchecked Sendable
{
    let application: NSRunningApplication

    init(application: NSRunningApplication) {
        self.application = application
    }

    var processIdentifier: pid_t {
        application.processIdentifier
    }

    var isTerminated: Bool {
        application.isTerminated
    }

    var workspaceApplication: NSRunningApplication? {
        application
    }
}

private struct NSWorkspaceApplicationOpener:
    WorkspaceApplicationOpening,
    Sendable
{
    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    ) {
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: configuration
        ) { application, error in
            if let error {
                completion(.failure(error))
            } else if let application {
                completion(
                    .success(
                        WorkspaceRunningApplication(application: application)
                    )
                )
            } else {
                completion(.failure(LaunchError.applicationDidNotOpen(url.path)))
            }
        }
    }
}

private struct NSWorkspaceTerminationObserver:
    RunningApplicationTerminationObserving,
    Sendable
{
    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        let center = NSWorkspace.shared.notificationCenter
        let processIdentifier = application.processIdentifier
        let token = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard
                let terminatedApplication =
                    notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication,
                terminatedApplication.processIdentifier == processIdentifier
            else {
                return
            }
            handler()
        }
        return NSWorkspaceTerminationObservation(
            notificationCenter: center,
            token: token
        )
    }
}

private final class NSWorkspaceTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter,
        token: NSObjectProtocol
    ) {
        self.notificationCenter = notificationCenter
        self.token = token
    }

    func cancel() {
        let token = lock.withLock {
            let token = self.token
            self.token = nil
            return token
        }
        if let token {
            notificationCenter.removeObserver(token)
        }
    }

    deinit {
        cancel()
    }
}
