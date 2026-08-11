import Darwin
import Foundation

struct WorkspaceApplicationBundleIdentity: Equatable, Hashable, Sendable {
    let bundleURL: URL
    let bundleIdentifier: String?

    init(bundleURL: URL, bundleIdentifier: String?) {
        self.bundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
    }
}

struct WorkspaceProcessIdentity: Equatable, Hashable, Sendable {
    let process: ProcessStartIdentity
    let application: WorkspaceApplicationBundleIdentity

    var processIdentifier: pid_t {
        process.processIdentifier
    }
}

enum WorkspaceProcessIdentityInspection: Equatable, Sendable {
    case live(WorkspaceProcessIdentity)
    case exited
    case indeterminate
}

enum LaunchProcessProvenanceIndeterminacy: Equatable, Sendable {
    case exitedBeforeVerification
    case unverifiableIdentity
    case processIdentifierMismatch
    case unexpectedApplication
    case bundleIdentityChanged
    case processIdentifierReused
    case processDidNotStartAfterLaunchBoundary
}

enum LaunchRequestTimeBoundaryError: Error, Equatable {
    case unavailable
    case invalidSeconds
    case invalidMicroseconds
}

struct LaunchRequestTimeBoundary: Equatable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    init(seconds: Int64, microseconds: Int64) throws {
        guard seconds >= 0 else {
            throw LaunchRequestTimeBoundaryError.invalidSeconds
        }
        guard (0..<1_000_000).contains(microseconds) else {
            throw LaunchRequestTimeBoundaryError.invalidMicroseconds
        }
        self.seconds = UInt64(seconds)
        self.microseconds = UInt64(microseconds)
    }

    func isStrictlyBefore(_ process: ProcessStartIdentity) -> Bool {
        process.startTimeSeconds > seconds
            || (process.startTimeSeconds == seconds
                && process.startTimeMicroseconds > microseconds)
    }
}

protocol LaunchRequestTimeProviding: Sendable {
    func launchRequestBoundary() throws -> LaunchRequestTimeBoundary
}

struct SystemLaunchRequestTimeProvider: LaunchRequestTimeProviding, Sendable {
    func launchRequestBoundary() throws -> LaunchRequestTimeBoundary {
        var current = timeval()
        guard Darwin.gettimeofday(&current, nil) == 0 else {
            throw LaunchRequestTimeBoundaryError.unavailable
        }
        return try LaunchRequestTimeBoundary(
            seconds: Int64(current.tv_sec),
            microseconds: Int64(current.tv_usec)
        )
    }
}

enum LaunchProcessProvenance: Equatable, Sendable {
    case new(WorkspaceProcessIdentity)
    case preExisting(WorkspaceProcessIdentity)
    case indeterminate(
        processIdentifier: pid_t,
        reason: LaunchProcessProvenanceIndeterminacy
    )
}

struct WorkspaceProcessSnapshot: Equatable, Sendable {
    let expectedApplication: WorkspaceApplicationBundleIdentity
    let processes: Set<WorkspaceProcessIdentity>
}
