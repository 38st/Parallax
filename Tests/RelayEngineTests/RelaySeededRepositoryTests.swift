import Foundation
import XCTest

final class RelaySeededRepositoryTests: XCTestCase {
    func testAgentRepositoryExcludesHiddenOracleAndHasStableBaseline() throws {
        let fixture = try makeFixture()
        let root = temporaryRoot("hidden-oracle")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try fixture.materializeAgentRepository(
            at: root.appendingPathComponent("first")
        )
        let second = try fixture.materializeAgentRepository(
            at: root.appendingPathComponent("second")
        )

        XCTAssertEqual(first.baselineCommit, second.baselineCommit)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: first.url.appendingPathComponent("Sources/value.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: first.url.appendingPathComponent("Hidden/oracle.txt").path
            )
        )

        let verification = root.appendingPathComponent("verification")
        try fixture.materializeVerificationRepository(
            from: first.url,
            at: verification
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: verification.appendingPathComponent("Hidden/oracle.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: first.url.appendingPathComponent("Hidden/oracle.txt").path
            )
        )
    }

    func testAllowedPathPolicyRejectsUntrackedForbiddenChange() throws {
        let fixture = try makeFixture()
        let root = temporaryRoot("path-policy")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try fixture.materializeAgentRepository(
            at: root.appendingPathComponent("repository")
        )
        let forbidden = repository.url.appendingPathComponent("Secrets/token.txt")
        try FileManager.default.createDirectory(
            at: forbidden.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("secret".utf8).write(to: forbidden)

        XCTAssertThrowsError(
            try fixture.assertChangesAllowed(
                in: repository.url,
                since: repository.baselineCommit
            )
        ) { error in
            XCTAssertEqual(
                error as? RelaySeededRepositoryError,
                .forbiddenChanges(["Secrets/token.txt"])
            )
        }
    }

    func testRejectsTraversalGitMetadataAndOracleCollision() throws {
        let manifest = makeManifest()
        for path in ["../escape", "/absolute", ".git/config", "a//b"] {
            XCTAssertThrowsError(
                try RelaySeededRepositoryFixture(
                    manifest: manifest,
                    visibleFiles: [RelaySeededFile(path, contents: "x")],
                    hiddenOracleFiles: []
                )
            ) { error in
                XCTAssertEqual(
                    error as? RelaySeededRepositoryError,
                    .invalidRelativePath(path)
                )
            }
        }

        XCTAssertThrowsError(
            try RelaySeededRepositoryFixture(
                manifest: manifest,
                visibleFiles: [RelaySeededFile("same", contents: "visible")],
                hiddenOracleFiles: [RelaySeededFile("same", contents: "hidden")]
            )
        ) { error in
            XCTAssertEqual(
                error as? RelaySeededRepositoryError,
                .visibleHiddenCollision("same")
            )
        }
    }

    func testHiddenOracleCannotFollowCandidateSymlinkOutsideVerificationRoot() throws {
        let fixture = try makeFixture()
        let root = temporaryRoot("hidden-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try fixture.materializeAgentRepository(
            at: root.appendingPathComponent("repository")
        )
        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: repository.url.appendingPathComponent("Hidden"),
            withDestinationURL: external
        )

        XCTAssertThrowsError(
            try fixture.materializeVerificationRepository(
                from: repository.url,
                at: root.appendingPathComponent("verification")
            )
        ) { error in
            XCTAssertEqual(
                error as? RelaySeededRepositoryError,
                .unsafeVerificationPath("Hidden/oracle.txt")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: external.appendingPathComponent("oracle.txt").path
            )
        )
    }

    private func makeFixture() throws -> RelaySeededRepositoryFixture {
        try RelaySeededRepositoryFixture(
            manifest: makeManifest(),
            visibleFiles: [
                RelaySeededFile("Sources/value.txt", contents: "before\n"),
                RelaySeededFile("README.md", contents: "fixture\n"),
            ],
            hiddenOracleFiles: [
                RelaySeededFile("Hidden/oracle.txt", contents: "expected\n"),
            ]
        )
    }

    private func makeManifest() -> RelaySeededRepositoryManifest {
        RelaySeededRepositoryManifest(
            id: "text-replacement",
            revision: 1,
            objective: "Replace the fixture value.",
            publicAcceptanceCommands: [["test", "-f", "Sources/value.txt"]],
            hiddenAcceptanceCommands: [["test", "-f", "Hidden/oracle.txt"]],
            allowedPaths: ["Sources/**"],
            forbiddenPaths: ["Secrets/**"]
        )
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "Parallax-RelaySeededRepository-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
