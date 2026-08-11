import Foundation
import RelayCore
@testable import RelayEngine
import XCTest

final class RelayRepositoryCustodyTests: XCTestCase {
    func testCleanRepositoryPreflightBindsExactRootCommonDirectoryAndHead()
        throws
    {
        let fixture = try RelayGitRepositoryFixture()
        defer { fixture.preserveThenRemoveTestFixture() }

        let admission = try RelayRepositoryCustodian().preflight(
            repositoryURL: fixture.repositoryURL
                .appendingPathComponent("nested")
        )

        XCTAssertEqual(
            admission.repositoryRootURL,
            try RelayRepositoryFileFacts.canonicalDirectory(
                fixture.repositoryURL
            )
        )
        XCTAssertEqual(
            admission.gitCommonDirectoryURL,
            try RelayRepositoryFileFacts.canonicalDirectory(fixture.gitURL)
        )
        XCTAssertEqual(admission.baselineCommit.rawValue, try fixture.head())
        XCTAssertEqual(
            admission.repositoryFileIdentity,
            try RelayRepositoryFileFacts.identity(
                ofDirectory: fixture.repositoryURL
            )
        )
    }

    func testDirtyRepositoryIsRejectedWithoutChangingCheckout() throws {
        let fixture = try RelayGitRepositoryFixture()
        defer { fixture.preserveThenRemoveTestFixture() }
        let original = try Data(
            contentsOf: fixture.repositoryURL.appendingPathComponent("file.txt")
        )
        try Data("changed\n".utf8).write(
            to: fixture.repositoryURL.appendingPathComponent("file.txt")
        )

        XCTAssertThrowsError(
            try RelayRepositoryCustodian().preflight(
                repositoryURL: fixture.repositoryURL
            )
        ) { error in
            XCTAssertEqual(
                error as? RelayRepositoryCustodyError,
                .repositoryNotClean
            )
        }
        XCTAssertNotEqual(
            try Data(
                contentsOf: fixture.repositoryURL
                    .appendingPathComponent("file.txt")
            ),
            original
        )
        XCTAssertTrue(try fixture.status().contains("file.txt"))
    }

    func testRepositoryLocalContentFilterExecutionIsRejected() throws {
        let fixture = try RelayGitRepositoryFixture()
        defer { fixture.preserveThenRemoveTestFixture() }
        try fixture.git([
            "config", "filter.hostile.smudge", "/usr/bin/false",
        ])

        XCTAssertThrowsError(
            try RelayRepositoryCustodian().preflight(
                repositoryURL: fixture.repositoryURL
            )
        ) { error in
            XCTAssertEqual(
                error as? RelayRepositoryCustodyError,
                .repositoryFilterExecutionConfigured
            )
        }
    }

    func testInProgressMergeMarkerIsRejectedEvenWithCleanStatus() throws {
        let fixture = try RelayGitRepositoryFixture()
        defer { fixture.preserveThenRemoveTestFixture() }
        try Data((try fixture.head()).utf8).write(
            to: fixture.gitURL.appendingPathComponent("MERGE_HEAD")
        )

        XCTAssertThrowsError(
            try RelayRepositoryCustodian().preflight(
                repositoryURL: fixture.repositoryURL
            )
        ) { error in
            XCTAssertEqual(
                error as? RelayRepositoryCustodyError,
                .repositoryOperationInProgress("MERGE_HEAD")
            )
        }
    }
}

final class RelayGitRepositoryFixture {
    let temporaryURL: URL
    let repositoryURL: URL
    var gitURL: URL { repositoryURL.appendingPathComponent(".git") }

    init() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "relay-repository-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            .resolvingSymlinksInPath()
        repositoryURL = temporaryURL.appendingPathComponent(
            "repository",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: repositoryURL.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try git(["init", "--initial-branch=main"])
        try git(["config", "user.name", "Relay Tests"])
        try git(["config", "user.email", "relay@example.invalid"])
        try Data("baseline\n".utf8).write(
            to: repositoryURL.appendingPathComponent("file.txt")
        )
        try git(["add", "--", "file.txt"])
        try git(["commit", "-m", "baseline"])
    }

    func git(_ arguments: [String]) throws {
        _ = try runGit(arguments)
    }

    func head() throws -> String {
        try runGit(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status() throws -> String {
        try runGit(["status", "--porcelain=v1"])
    }

    func preserveThenRemoveTestFixture() {
        // Production custody intentionally has no cleanup API. This removes
        // only the UUID-scoped test fixture created by this object.
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "--no-pager", "-c", "core.hooksPath=/dev/null",
        ] + arguments
        process.currentDirectoryURL = repositoryURL
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "RelayGitRepositoryFixture",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: data, encoding: .utf8) ?? "Git failed"
                ]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
