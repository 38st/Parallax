import Darwin
import Foundation

public struct RelayProcessStartIdentity: Sendable, Equatable, Hashable {
    public let processIdentifier: pid_t
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(
        processIdentifier: pid_t,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64
    ) {
        self.processIdentifier = processIdentifier
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public enum RelayProcessIdentityInspection: Sendable, Equatable {
    case live(RelayProcessStartIdentity)
    case dead
    case ambiguous
}

public protocol RelayProcessIdentityInspecting: Sendable {
    func inspect(
        processIdentifier: pid_t
    ) -> RelayProcessIdentityInspection
}

public struct SystemRelayProcessIdentityInspector:
    RelayProcessIdentityInspecting,
    Sendable
{
    public init() {}

    public func inspect(
        processIdentifier: pid_t
    ) -> RelayProcessIdentityInspection {
        guard processIdentifier > 0 else { return .dead }

        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        if result == expectedSize {
            return .live(
                RelayProcessStartIdentity(
                    processIdentifier: processIdentifier,
                    startTimeSeconds: UInt64(info.pbi_start_tvsec),
                    startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
                )
            )
        }

        errno = 0
        if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH {
            return .dead
        }
        return .ambiguous
    }
}

public enum RelayExactProcessSignalResult: Sendable, Equatable {
    case delivered
    case alreadyExited
    case identityChanged
    case identityUnavailable
    case rejected(code: Int32)
}

/// Delivers a signal only after re-establishing the process's exact PID/start
/// identity. An ambiguous inspection is never treated as permission to signal.
public struct RelayExactProcessSignaler<Inspector: RelayProcessIdentityInspecting>:
    Sendable
{
    public let inspector: Inspector

    public init(inspector: Inspector) {
        self.inspector = inspector
    }

    public func send(
        _ signal: Int32,
        to expected: RelayProcessStartIdentity
    ) -> RelayExactProcessSignalResult {
        switch inspector.inspect(
            processIdentifier: expected.processIdentifier
        ) {
        case .dead:
            return .alreadyExited
        case .ambiguous:
            return .identityUnavailable
        case .live(let current):
            guard current == expected else { return .identityChanged }
        }

        guard Darwin.kill(expected.processIdentifier, signal) == 0 else {
            let code = errno
            if code == ESRCH { return .alreadyExited }
            return .rejected(code: code)
        }
        return .delivered
    }
}
