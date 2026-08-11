import CryptoKit
import Foundation

/// Whether an execution boundary is enforced by the selected sandbox backend.
///
/// A backend must never translate `unsupported` or `unsafe` into a successful
/// authorization. The distinction is retained so the UI can explain whether a
/// capability is unavailable or merely requested from an uncontained host
/// process.
public enum RelaySandboxCapabilityState: Sendable, Equatable {
    case proven(mechanism: String)
    case unsupported(reason: String)
    case unsafe(reason: String)
}

public struct RelaySandboxCapabilityReport: Sendable, Equatable {
    public let backendIdentifier: String
    public let filesystemBoundary: RelaySandboxCapabilityState
    public let networkDeny: RelaySandboxCapabilityState
    public let processContainment: RelaySandboxCapabilityState
    public let executableIdentityPinning: RelaySandboxCapabilityState

    init(
        backendIdentifier: String,
        filesystemBoundary: RelaySandboxCapabilityState,
        networkDeny: RelaySandboxCapabilityState,
        processContainment: RelaySandboxCapabilityState,
        executableIdentityPinning: RelaySandboxCapabilityState
    ) {
        self.backendIdentifier = backendIdentifier
        self.filesystemBoundary = filesystemBoundary
        self.networkDeny = networkDeny
        self.processContainment = processContainment
        self.executableIdentityPinning = executableIdentityPinning
    }

    /// A truthful report for the ordinary Foundation `Process` backend.
    /// Running a child process on the host does not prove filesystem, network,
    /// or descendant-process containment.
    public static let unsafeHostProcess = RelaySandboxCapabilityReport(
        backendIdentifier: "foundation-process-host",
        filesystemBoundary: .unsafe(
            reason: "The child process shares the host filesystem namespace."
        ),
        networkDeny: .unsupported(
            reason: "Foundation Process cannot enforce a no-network boundary."
        ),
        processContainment: .unsafe(
            reason: "Detached descendants can outlive the launched process."
        ),
        executableIdentityPinning: .unsupported(
            reason: "Foundation Process launches by mutable path, not a pinned descriptor."
        )
    )
}

public struct RelaySandboxRequirements: Sendable, Equatable {
    public let requiresFilesystemBoundary: Bool
    public let requiresNetworkDeny: Bool
    public let requiresProcessContainment: Bool
    public let requiresExecutableIdentityPinning: Bool

    public init(
        requiresFilesystemBoundary: Bool = true,
        requiresNetworkDeny: Bool = true,
        requiresProcessContainment: Bool = true,
        requiresExecutableIdentityPinning: Bool = true
    ) {
        self.requiresFilesystemBoundary = requiresFilesystemBoundary
        self.requiresNetworkDeny = requiresNetworkDeny
        self.requiresProcessContainment = requiresProcessContainment
        self.requiresExecutableIdentityPinning =
            requiresExecutableIdentityPinning
    }

    /// Relay's safe default. A backend that cannot prove all three properties
    /// is blocked before any repository-controlled executable is launched.
    public static let secureDefault = RelaySandboxRequirements()
}

public enum RelaySandboxCapability:
    String,
    Sendable,
    Equatable,
    Hashable,
    CaseIterable
{
    case filesystemBoundary
    case networkDeny
    case processContainment
    case executableIdentityPinning
}

public struct RelaySandboxBlocker: Sendable, Equatable {
    public let capability: RelaySandboxCapability
    public let state: RelaySandboxCapabilityState
}

public enum RelaySandboxValidation: Sendable, Equatable {
    case authorized(RelaySandboxExecutionAuthorization)
    case blocked([RelaySandboxBlocker])
}

/// Proof that the selected backend reported every required containment
/// property as enforced. Only `RelaySandboxValidator` can construct it.
public struct RelaySandboxExecutionAuthorization: Sendable, Equatable {
    public let backendIdentifier: String
    public let capabilityDigest: String
    let requirements: RelaySandboxRequirements

    fileprivate init(
        report: RelaySandboxCapabilityReport,
        requirements: RelaySandboxRequirements
    ) {
        backendIdentifier = report.backendIdentifier
        capabilityDigest = Self.digest(report)
        self.requirements = requirements
    }

    private static func digest(
        _ report: RelaySandboxCapabilityReport
    ) -> String {
        let text = [
            report.backendIdentifier,
            String(describing: report.filesystemBoundary),
            String(describing: report.networkDeny),
            String(describing: report.processContainment),
            String(describing: report.executableIdentityPinning),
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct RelaySandboxValidator: Sendable {
    public init() {}

    public func validate(
        _ report: RelaySandboxCapabilityReport,
        against requirements: RelaySandboxRequirements = .secureDefault
    ) -> RelaySandboxValidation {
        var blockers: [RelaySandboxBlocker] = []

        if requirements.requiresFilesystemBoundary,
           !report.filesystemBoundary.isProven
        {
            blockers.append(
                RelaySandboxBlocker(
                    capability: .filesystemBoundary,
                    state: report.filesystemBoundary
                )
            )
        }
        if requirements.requiresNetworkDeny,
           !report.networkDeny.isProven
        {
            blockers.append(
                RelaySandboxBlocker(
                    capability: .networkDeny,
                    state: report.networkDeny
                )
            )
        }
        if requirements.requiresProcessContainment,
           !report.processContainment.isProven
        {
            blockers.append(
                RelaySandboxBlocker(
                    capability: .processContainment,
                    state: report.processContainment
                )
            )
        }
        if requirements.requiresExecutableIdentityPinning,
           !report.executableIdentityPinning.isProven
        {
            blockers.append(
                RelaySandboxBlocker(
                    capability: .executableIdentityPinning,
                    state: report.executableIdentityPinning
                )
            )
        }

        guard blockers.isEmpty else { return .blocked(blockers) }
        return .authorized(
            RelaySandboxExecutionAuthorization(
                report: report,
                requirements: requirements
            )
        )
    }
}

private extension RelaySandboxCapabilityState {
    var isProven: Bool {
        if case .proven = self { return true }
        return false
    }
}
