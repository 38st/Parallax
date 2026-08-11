import Foundation

struct ProcessStartIdentity: Codable, Equatable, Hashable, Sendable {
    let processIdentifier: pid_t
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

