import AppKit
import Foundation

func makeNSWorkspaceApplicationOpeningDependencies() -> (
    opener: any WorkspaceApplicationOpening,
    terminationObserver: any RunningApplicationTerminationObserving
) {
    (
        opener: NSWorkspaceApplicationOpener(),
        terminationObserver: NSWorkspaceTerminationObserver()
    )
}

private final class WorkspaceRunningApplication:
    RunningApplicationInstance,
    @unchecked Sendable
{
    let application: NSRunningApplication
    private let activationRequester: WorkspaceVerifiedActivationRequester

    init(
        application: NSRunningApplication,
        activationRequester: WorkspaceVerifiedActivationRequester =
            WorkspaceVerifiedActivationRequester()
    ) {
        self.application = application
        self.activationRequester = activationRequester
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

    func requestActivation(of identity: WorkspaceProcessIdentity) {
        activationRequester.requestActivation(of: identity)
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
