import Darwin
import Foundation

enum ProcessIdentityInspection: Equatable, Sendable {
    case live(ProcessStartIdentity)
    case dead
    case ambiguous
}

protocol ProcessIdentityInspecting: Sendable {
    func inspect(processIdentifier: pid_t) -> ProcessIdentityInspection
}

struct SystemProcessIdentityInspector: ProcessIdentityInspecting, Sendable {
    func inspect(processIdentifier: pid_t) -> ProcessIdentityInspection {
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
                ProcessStartIdentity(
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

