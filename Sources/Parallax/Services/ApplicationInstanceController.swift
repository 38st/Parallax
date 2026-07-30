import AppKit
import Foundation

struct WorkspaceApplicationProcess: Equatable, Sendable {
    let process: ProcessStartIdentity
    let bundleURL: URL
    let bundleIdentifier: String?
}

struct ManagedApplicationInstance:
    Identifiable,
    Equatable,
    Sendable
{
    let process: ProcessStartIdentity
    let profileID: UUID?
    let profileName: String?

    var id: ProcessStartIdentity { process }

    var processIdentifier: pid_t {
        process.processIdentifier
    }

    var displayName: String {
        profileName ?? String(localized: "Other instance")
    }

    var isTrackedSpace: Bool {
        profileID != nil
    }
}

enum ApplicationInstanceControllerError: LocalizedError {
    case instanceNoLongerRunning
    case processIdentityChanged(pid_t)
    case applicationIdentityChanged(pid_t)
    case activationRequestRejected(pid_t)
    case quitRequestRejected(pid_t)

    var errorDescription: String? {
        switch self {
        case .instanceNoLongerRunning:
            String(localized: "This app instance is no longer running.")
        case .processIdentityChanged(let processIdentifier):
            String(
                localized:
                    "Process \(processIdentifier) changed before Parallax could ask it to quit."
            )
        case .applicationIdentityChanged(let processIdentifier):
            String(
                localized:
                    "Process \(processIdentifier) no longer belongs to this app."
            )
        case .activationRequestRejected(let processIdentifier):
            String(
                localized:
                    "Process \(processIdentifier) did not accept the request to come forward."
            )
        case .quitRequestRejected(let processIdentifier):
            String(
                localized:
                    "Process \(processIdentifier) did not accept the quit request."
            )
        }
    }
}

@MainActor
protocol WorkspaceApplicationProcessProviding: AnyObject {
    func runningProcesses() -> [WorkspaceApplicationProcess]
    func requestTermination(
        of process: ProcessStartIdentity
    ) -> Bool
    func requestActivation(
        of process: ProcessStartIdentity
    ) -> Bool
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
        let trackedByProcess = trackedProcesses.reduce(
            into: [ProcessStartIdentity: ProfileActivityIdentity]()
        ) { result, tracked in
            result[tracked.process] = tracked.identity
        }
        let profileNames = Dictionary(
            uniqueKeysWithValues: application.profiles.map {
                ($0.id, $0.name)
            }
        )

        return processProvider.runningProcesses()
            .filter {
                Self.matches(
                    bundleURL: $0.bundleURL,
                    applicationPath: application.appPath
                )
            }
            .map { running in
                let trackedIdentity = trackedByProcess[running.process]
                let profileID = trackedIdentity.flatMap { identity in
                    identity.applicationID == application.id
                        && identity.applicationStorageID
                            == application.storageID
                        ? identity.profileID
                        : nil
                }
                return ManagedApplicationInstance(
                    process: running.process,
                    profileID: profileID,
                    profileName: profileID.flatMap {
                        profileNames[$0]
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
        let current = try verifiedRunningProcess(
            for: instance,
            application: application
        )
        guard processProvider.requestTermination(of: current.process) else {
            throw ApplicationInstanceControllerError
                .quitRequestRejected(instance.processIdentifier)
        }
    }

    func requestActivate(
        _ instance: ManagedApplicationInstance,
        from application: ManagedApplication
    ) throws {
        let current = try verifiedRunningProcess(
            for: instance,
            application: application
        )
        guard processProvider.requestActivation(of: current.process) else {
            throw ApplicationInstanceControllerError
                .activationRequestRejected(instance.processIdentifier)
        }
    }

    private func verifiedRunningProcess(
        for instance: ManagedApplicationInstance,
        application: ManagedApplication
    ) throws -> WorkspaceApplicationProcess {
        let current = processProvider.runningProcesses().first {
            $0.process.processIdentifier
                == instance.processIdentifier
        }
        guard let current else {
            throw ApplicationInstanceControllerError
                .instanceNoLongerRunning
        }
        guard current.process == instance.process else {
            throw ApplicationInstanceControllerError
                .processIdentityChanged(instance.processIdentifier)
        }
        guard
            Self.matches(
                bundleURL: current.bundleURL,
                applicationPath: application.appPath
            )
        else {
            throw ApplicationInstanceControllerError
                .applicationIdentityChanged(
                    instance.processIdentifier
                )
        }
        return current
    }

    private static func matches(
        bundleURL: URL,
        applicationPath: String
    ) -> Bool {
        bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: applicationPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
    }
}

@MainActor
private final class NSWorkspaceApplicationProcessProvider:
    WorkspaceApplicationProcessProviding
{
    private let processInspector = SystemProcessIdentityInspector()

    func runningProcesses() -> [WorkspaceApplicationProcess] {
        NSWorkspace.shared.runningApplications.compactMap {
            application in
            guard
                !application.isTerminated,
                let bundleURL = application.bundleURL,
                case .live(let process) = processInspector.inspect(
                    processIdentifier:
                        application.processIdentifier
                )
            else {
                return nil
            }
            return WorkspaceApplicationProcess(
                process: process,
                bundleURL: bundleURL,
                bundleIdentifier: application.bundleIdentifier
            )
        }
    }

    func requestTermination(
        of process: ProcessStartIdentity
    ) -> Bool {
        guard
            case .live(let current) = processInspector.inspect(
                processIdentifier: process.processIdentifier
            ),
            current == process,
            let application = NSRunningApplication(
                processIdentifier: process.processIdentifier
            ),
            !application.isTerminated
        else {
            return false
        }
        return application.terminate()
    }

    func requestActivation(
        of process: ProcessStartIdentity
    ) -> Bool {
        guard
            case .live(let current) = processInspector.inspect(
                processIdentifier: process.processIdentifier
            ),
            current == process,
            let application = NSRunningApplication(
                processIdentifier: process.processIdentifier
            ),
            !application.isTerminated
        else {
            return false
        }

        let options: NSApplication.ActivationOptions = [
            .activateAllWindows
        ]

        // macOS 14 and later use cooperative activation. Yielding first
        // preserves the user's click as the activation handoff and lets
        // Launch Services target this exact process even when several
        // instances share the same bundle identifier.
        NSApp.yieldActivation(to: application)
        if application.activate(
            from: NSRunningApplication.current,
            options: options
        ) {
            return true
        }

        // Keep the traditional request as a compatibility fallback for apps
        // that do not participate in coordinated activation.
        return application.activate(options: options)
    }
}
