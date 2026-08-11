import AppKit
import Foundation

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
func makeNSWorkspaceApplicationProcessRuntime()
    -> any WorkspaceApplicationProcessRuntime
{
    NSWorkspaceApplicationProcessRuntime()
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
