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
        eventHandler: @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch
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
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch
}

enum TrackedApplicationLaunchEvent: Equatable, Sendable {
    case requested(requestID: UUID)
    case running(requestID: UUID, processIdentifier: pid_t)
    case terminated(requestID: UUID, processIdentifier: pid_t)
    case failed(requestID: UUID, message: String)
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
    private let requestID: UUID
    private let activityRegistry: ProfileActivityRegistry
    private let eventHandler:
        @Sendable (TrackedApplicationLaunchEvent) -> Void
    private var activityLease: ProfileActivityLease?
    private var terminationObservation:
        (any RunningApplicationTerminationObservation)?
    private var runningInstance: (any RunningApplicationInstance)?
    private var terminal = false
    private var latestEvent: TrackedApplicationLaunchEvent

    fileprivate init(
        requestID: UUID,
        activityRegistry: ProfileActivityRegistry,
        activityLease: ProfileActivityLease,
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) {
        self.requestID = requestID
        self.activityRegistry = activityRegistry
        self.activityLease = activityLease
        self.eventHandler = eventHandler
        latestEvent = .requested(requestID: requestID)
    }

    var currentEvent: TrackedApplicationLaunchEvent {
        lock.withLock { latestEvent }
    }

    /// The production handle returned by `NSWorkspace`, retained until the
    /// process reaches a terminal state.
    var runningApplication: NSRunningApplication? {
        lock.withLock { runningInstance?.workspaceApplication }
    }

    fileprivate func didRequest() {
        eventHandler(.requested(requestID: requestID))
    }

    fileprivate func didOpen(
        _ application: any RunningApplicationInstance,
        observer: any RunningApplicationTerminationObserving
    ) {
        if application.isTerminated {
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
        } catch {
            reportTrackingFailure(error)
            observeTermination(of: application, observer: observer)
            return
        }

        let runningEvent = TrackedApplicationLaunchEvent.running(
            requestID: requestID,
            processIdentifier: application.processIdentifier
        )
        let shouldReport = lock.withLock {
            guard !terminal else { return false }
            runningInstance = application
            latestEvent = runningEvent
            return true
        }
        guard shouldReport else { return }
        eventHandler(runningEvent)
        observeTermination(of: application, observer: observer)
    }

    private func observeTermination(
        of application: any RunningApplicationInstance,
        observer: any RunningApplicationTerminationObserving
    ) {
        let observation = observer.observeTermination(of: application) {
            [self] in
            didTerminate(
                processIdentifier: application.processIdentifier
            )
        }
        install(observation)

        // Covers termination after the first check but before the notification
        // observer was installed.
        if application.isTerminated {
            didTerminate(processIdentifier: application.processIdentifier)
        }
    }

    private func reportTrackingFailure(_ error: Error) {
        let event = TrackedApplicationLaunchEvent.failed(
            requestID: requestID,
            message: error.localizedDescription
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
        let resources = lock.withLock {
            guard !terminal else {
                return (
                    shouldReport: false,
                    lease: Optional<ProfileActivityLease>.none,
                    observation:
                        Optional<any RunningApplicationTerminationObservation>
                            .none
                )
            }
            terminal = true
            latestEvent = event
            let lease = activityLease
            activityLease = nil
            let observation = terminationObservation
            terminationObservation = nil
            runningInstance = nil
            return (
                shouldReport: true,
                lease: lease,
                observation: observation
            )
        }

        guard resources.shouldReport else { return }
        let completion: DurableLaunchCompletion
        switch event {
        case .terminated:
            completion = .terminated
        case .failed:
            completion = .failed
        case .requested, .running:
            completion = .failed
        }
        try? activityRegistry.completeDurableLaunch(
            requestID: requestID,
            completion: completion
        )
        resources.observation?.cancel()
        resources.lease?.release()
        eventHandler(event)
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
        eventHandler:
            @escaping @Sendable (TrackedApplicationLaunchEvent) -> Void
    ) throws -> TrackedApplicationLaunch {
        throw LaunchError.preparationRequired
    }

    @discardableResult
    func launchTracked(
        prepared: PreparedLaunch,
        activityRegistry: ProfileActivityRegistry,
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
            requestID: prepared.requestID
        )
        do {
            try activityRegistry.markLaunchOpening(
                requestID: prepared.requestID
            )
        } catch {
            try? activityRegistry.completeDurableLaunch(
                requestID: prepared.requestID,
                completion: .failed
            )
            lease.release()
            throw error
        }
        let launch = TrackedApplicationLaunch(
            requestID: prepared.requestID,
            activityRegistry: activityRegistry,
            activityLease: lease,
            eventHandler: eventHandler
        )
        launch.didRequest()

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
