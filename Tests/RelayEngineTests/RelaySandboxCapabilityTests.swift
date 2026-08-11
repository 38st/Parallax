import XCTest
@testable import RelayEngine

final class RelaySandboxCapabilityTests: XCTestCase {
    func testSecureDefaultBlocksTruthfulHostProcessBackend() {
        let result = RelaySandboxValidator().validate(.unsafeHostProcess)

        guard case .blocked(let blockers) = result else {
            return XCTFail("Host Process must not satisfy secure defaults.")
        }
        XCTAssertEqual(
            Set(blockers.map(\.capability)),
            Set(RelaySandboxCapability.allCases)
        )
    }

    func testOnlyProvenRequiredCapabilitiesAuthorize() {
        let report = RelaySandboxCapabilityReport(
            backendIdentifier: "test-contained-backend",
            filesystemBoundary: .proven(mechanism: "test fixture"),
            networkDeny: .unsupported(reason: "not implemented"),
            processContainment: .proven(mechanism: "test fixture"),
            executableIdentityPinning: .proven(mechanism: "test fixture")
        )
        let requirements = RelaySandboxRequirements(
            requiresFilesystemBoundary: true,
            requiresNetworkDeny: true,
            requiresProcessContainment: true
        )

        guard case .blocked(let blockers) = RelaySandboxValidator().validate(
            report,
            against: requirements
        ) else {
            return XCTFail("Unsupported no-network enforcement must block.")
        }
        XCTAssertEqual(blockers.map(\.capability), [.networkDeny])
    }

    func testAuthorizationIsBoundToCapabilityReport() {
        let first = RelaySandboxCapabilityReport(
            backendIdentifier: "backend-a",
            filesystemBoundary: .proven(mechanism: "vm"),
            networkDeny: .proven(mechanism: "vm"),
            processContainment: .proven(mechanism: "vm"),
            executableIdentityPinning: .proven(mechanism: "vm")
        )
        let second = RelaySandboxCapabilityReport(
            backendIdentifier: "backend-b",
            filesystemBoundary: .proven(mechanism: "vm"),
            networkDeny: .proven(mechanism: "vm"),
            processContainment: .proven(mechanism: "vm"),
            executableIdentityPinning: .proven(mechanism: "vm")
        )

        guard case .authorized(let firstAuthorization) =
            RelaySandboxValidator().validate(first),
            case .authorized(let secondAuthorization) =
            RelaySandboxValidator().validate(second)
        else {
            return XCTFail("Both complete test reports should authorize.")
        }
        XCTAssertNotEqual(
            firstAuthorization.capabilityDigest,
            secondAuthorization.capabilityDigest
        )
    }
}
