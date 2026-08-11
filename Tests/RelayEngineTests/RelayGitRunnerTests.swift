import Foundation
@testable import RelayEngine
import XCTest

final class RelayGitRunnerTests: XCTestCase {
    func testDirectArgumentVectorDoesNotInvokeShellExpansion() throws {
        let fixture = try RelayGitRepositoryFixture()
        defer { fixture.preserveThenRemoveTestFixture() }
        let marker = fixture.temporaryURL.appendingPathComponent("injected")

        let result = try RelaySystemGitRunner().run(
            arguments: ["rev-parse", "--verify", "HEAD;touch \(marker.path)"],
            workingDirectory: fixture.repositoryURL,
            standardOutputLimit: 1_024,
            acceptedExitStatuses: [128]
        )

        XCTAssertEqual(result.exitStatus, 128)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOutputLimitFailsClosed() throws {
        let fixture = try RelayGitRepositoryFixture()
        defer { fixture.preserveThenRemoveTestFixture() }

        XCTAssertThrowsError(
            try RelaySystemGitRunner().run(
                arguments: ["show", "--format=fuller", "HEAD"],
                workingDirectory: fixture.repositoryURL,
                standardOutputLimit: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? RelayGitCommandError,
                .outputLimitExceeded(stream: .standardOutput, limit: 1)
            )
        }
    }
}
