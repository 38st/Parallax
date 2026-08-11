import AppKit
import Foundation

struct WorkspaceRunningProcessCandidate: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleURL: URL?
    let bundleIdentifier: String?
    let isTerminated: Bool
}

protocol WorkspaceRunningProcessListing: Sendable {
    func runningProcesses() throws -> [WorkspaceRunningProcessCandidate]
    func runningProcess(
        processIdentifier: pid_t
    ) throws -> WorkspaceRunningProcessCandidate?
}

struct SystemWorkspaceRunningProcessList:
    WorkspaceRunningProcessListing,
    Sendable
{
    func runningProcesses() -> [WorkspaceRunningProcessCandidate] {
        NSWorkspace.shared.runningApplications.map(candidate)
    }

    func runningProcess(
        processIdentifier: pid_t
    ) -> WorkspaceRunningProcessCandidate? {
        guard
            let application = NSRunningApplication(
                processIdentifier: processIdentifier
            )
        else {
            return nil
        }
        return candidate(application)
    }

    private func candidate(
        _ application: NSRunningApplication
    ) -> WorkspaceRunningProcessCandidate {
        WorkspaceRunningProcessCandidate(
            processIdentifier: application.processIdentifier,
            bundleURL: application.bundleURL,
            bundleIdentifier: application.bundleIdentifier,
            isTerminated: application.isTerminated
        )
    }
}
