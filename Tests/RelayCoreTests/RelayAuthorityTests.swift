import Foundation
import RelayCore
import XCTest

final class RelayAuthorityTests: XCTestCase {
    func testOmittedCredentialsFailClosed() {
        let authority = RelayAuthority(
            fileSystem: .workspaceWrite,
            execution: .test,
            git: .read
        )

        XCTAssertEqual(authority.credentials, .none)
        XCTAssertEqual(authority.network, .none)
        XCTAssertEqual(authority.externalWrites, .none)
    }

    func testEveryBuiltInAuthorityHasNoCredentialOrExternalWriteAccess() {
        let builtIns: [RelayAuthority] = [
            .scout,
            .implementer,
            .verifier,
            .reviewer,
        ]

        for authority in builtIns {
            XCTAssertEqual(authority.credentials, .none)
            XCTAssertEqual(authority.network, .none)
            XCTAssertEqual(authority.externalWrites, .none)
        }
    }

    func testCredentialGrantMustBeExplicitAtConstruction() {
        let authority = RelayAuthority(
            fileSystem: .readOnly,
            execution: .diagnostic,
            git: .read,
            credentials: .selectedCodexHome
        )

        XCTAssertEqual(authority.credentials, .selectedCodexHome)
    }

    func testCanonicalRoundTripDoesNotReintroduceCredentials() throws {
        let bytes = try RelayCanonicalEncoding.encode(RelayAuthority.reviewer)
        let decoded = try JSONDecoder().decode(RelayAuthority.self, from: bytes)

        XCTAssertEqual(decoded, .reviewer)
        XCTAssertEqual(decoded.credentials, .none)
    }
}
