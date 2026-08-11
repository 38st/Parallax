import CryptoKit
import Foundation
import RelayCore

public enum RelayCommandBudgetError: Error, Sendable, Equatable {
    case nonPositiveWallTime
    case negativeGracePeriod
    case negativeOutputLimit
}

public struct RelayCommandBudget: Sendable, Equatable {
    public let wallTime: Duration
    public let interruptGrace: Duration
    public let terminateGrace: Duration
    public let maximumStandardOutputBytes: Int
    public let maximumStandardErrorBytes: Int

    public init(
        wallTime: Duration,
        interruptGrace: Duration = .seconds(1),
        terminateGrace: Duration = .seconds(1),
        maximumStandardOutputBytes: Int = 256 * 1_024,
        maximumStandardErrorBytes: Int = 256 * 1_024
    ) throws {
        guard wallTime > .zero else {
            throw RelayCommandBudgetError.nonPositiveWallTime
        }
        guard interruptGrace >= .zero, terminateGrace >= .zero else {
            throw RelayCommandBudgetError.negativeGracePeriod
        }
        guard maximumStandardOutputBytes >= 0,
              maximumStandardErrorBytes >= 0
        else {
            throw RelayCommandBudgetError.negativeOutputLimit
        }
        self.wallTime = wallTime
        self.interruptGrace = interruptGrace
        self.terminateGrace = terminateGrace
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
    }
}

public enum RelayMinimalEnvironmentError: Error, Sendable, Equatable {
    case invalidName(String)
    case prohibitedName(String)
    case invalidValue(String)
}

public struct RelayMinimalEnvironment: Sendable, Equatable {
    public let values: [String: String]

    public init(
        explicitValues: [String: String] = [:],
        allowedNames: Set<String> = ["LANG", "LC_ALL", "TMPDIR"]
    ) throws {
        var result = ["LANG": "C", "LC_ALL": "C"]
        for (name, value) in explicitValues {
            guard Self.isValidName(name) else {
                throw RelayMinimalEnvironmentError.invalidName(name)
            }
            guard allowedNames.contains(name) else {
                throw RelayMinimalEnvironmentError.prohibitedName(name)
            }
            guard !value.contains("\0") else {
                throw RelayMinimalEnvironmentError.invalidValue(name)
            }
            result[name] = value
        }
        values = result.filter { allowedNames.contains($0.key) }
    }

    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }
}

public struct RelayEvidenceRedactor: Sendable, Equatable {
    public let sensitiveLiterals: Set<String>
    public let regularExpressionPatterns: [String]

    public init(
        sensitiveLiterals: Set<String> = [],
        regularExpressionPatterns: [String] = [
            #"(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*"#,
            #"\b(?:ghp|github_pat)_[A-Za-z0-9_]{16,}\b"#,
        ]
    ) {
        self.sensitiveLiterals = sensitiveLiterals.filter { !$0.isEmpty }
        self.regularExpressionPatterns = regularExpressionPatterns
    }

    public func redact(
        _ data: Data,
        mayEndMidSensitiveLiteral: Bool = false
    ) -> RelayRedactedText {
        var text = String(decoding: data, as: UTF8.self)
        var replacementCount = 0

        for literal in sensitiveLiterals.sorted(by: { $0.count > $1.count }) {
            let matches = text.components(separatedBy: literal).count - 1
            guard matches > 0 else { continue }
            text = text.replacingOccurrences(of: literal, with: "<redacted>")
            replacementCount += matches
        }

        if mayEndMidSensitiveLiteral {
            for literal in sensitiveLiterals where literal.count > 1 {
                for length in stride(
                    from: literal.count - 1,
                    through: 1,
                    by: -1
                ) {
                    let prefix = String(literal.prefix(length))
                    guard text.hasSuffix(prefix) else { continue }
                    text.removeLast(prefix.count)
                    text.append("<redacted-truncated>")
                    replacementCount += 1
                    break
                }
            }
        }

        for pattern in regularExpressionPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern)
            else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = expression.numberOfMatches(
                in: text,
                range: range
            )
            guard matches > 0 else { continue }
            text = expression.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: "<redacted>"
            )
            replacementCount += matches
        }

        return RelayRedactedText(
            text: text,
            replacementCount: replacementCount
        )
    }
}

public struct RelayRedactedText: Sendable, Equatable {
    public let text: String
    public let replacementCount: Int
}

public struct RelayCapturedCommandStream: Sendable, Equatable {
    public let text: String
    public let rawSHA256: String
    public let totalByteCount: UInt64
    public let retainedByteCount: Int
    public let wasTruncated: Bool
    public let redactionCount: Int
}

public enum RelayCommandTermination: Sendable, Equatable {
    case exited(code: Int32)
    case signaled(signal: Int32)
    case timedOut
    case cancelled
    case launchRejected(RelayCommandLaunchRejection)
}

public enum RelayCommandLaunchRejection: Sendable, Equatable {
    case sandboxUnsupported([RelaySandboxBlocker])
    case stageCapabilityRejected
    case executableChanged
    case invalidWorkingDirectory
    case processIdentityUnavailable
    case processControlFailed(RelayManagedProcessControlOutcome)
    case processLaunchFailed
}

public struct RelayCommandEvidence: Sendable, Equatable {
    public let commandDigest: String
    public let workspaceDigest: RelayDigest
    public let sandboxCapabilityDigest: String?
    public let executableIdentity: RelayExecutableIdentity
    public let processIdentity: RelayProcessStartIdentity?
    public let termination: RelayCommandTermination
    public let standardOutput: RelayCapturedCommandStream
    public let standardError: RelayCapturedCommandStream
    public let elapsed: Duration
}

final class RelayBoundedCommandStream: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var retained = Data()
    private var totalByteCount: UInt64 = 0
    private var digest = SHA256()

    init(limit: Int) {
        self.limit = limit
        retained.reserveCapacity(limit)
    }

    func append(_ data: Data) {
        lock.withLock {
            totalByteCount += UInt64(data.count)
            digest.update(data: data)
            let remaining = max(0, limit - retained.count)
            if remaining > 0 {
                retained.append(data.prefix(remaining))
            }
        }
    }

    func finalize(
        redactor: RelayEvidenceRedactor
    ) -> RelayCapturedCommandStream {
        lock.withLock {
            let wasTruncated = totalByteCount > UInt64(retained.count)
            let redacted = redactor.redact(
                retained,
                mayEndMidSensitiveLiteral: wasTruncated
            )
            return RelayCapturedCommandStream(
                text: redacted.text,
                rawSHA256: digest.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined(),
                totalByteCount: totalByteCount,
                retainedByteCount: retained.count,
                wasTruncated: wasTruncated,
                redactionCount: redacted.replacementCount
            )
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
