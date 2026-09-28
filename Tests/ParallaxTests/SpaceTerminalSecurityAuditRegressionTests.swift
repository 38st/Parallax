import Foundation
import XCTest
@testable import Parallax

final class SpaceTerminalSecurityAuditRegressionTests: XCTestCase {
    func testTerminalLookupUsesPinnedSystemPathAndRejectsUnexpectedBundle() throws {
        let expected = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        XCTAssertEqual(try SpaceTerminalOpener.validatedSystemTerminalURL { url in
            XCTAssertEqual(url, expected)
            return "com.apple.Terminal"
        }, expected)
        for identifier in [nil, "example.impostor"] {
            XCTAssertThrowsError(try SpaceTerminalOpener.validatedSystemTerminalURL { _ in identifier }) {
                XCTAssertEqual($0 as? SpaceTerminalError, .terminalUnavailable)
            }
        }
    }

    func testNewlineValueIsQuotedAndBannerIsOneLineBeforeShellStarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-Terminal-Banner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try Data("#!/bin/sh\n/usr/bin/printf '%s' \"$CODEX_HOME\" > \"$RESULT_PATH\"\n/usr/bin/printf 'SHELL STARTED\\n'\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let value = root.path + "/line one\nline two 'quotes' $dollar `id` $(id) \\backslash"
        let service = SpaceTerminalService(activityRegistry: ProfileActivityRegistry(), identity:
            ChildEnvironmentIdentity(homeDirectory: root.path, userName: "fixture", temporaryDirectory: root.path))
        let url = try service.writeCommand(environmentKey: "CODEX_HOME", value: value,
            profileName: "Work\n'quoted' $(id)\u{001B}", loginShell: shell.path, temporaryDirectory: root)
        let output = root.appendingPathComponent("result")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = url
        process.environment = ["RESULT_PATH": output.path]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let banner = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), value)
        let lines = banner.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.first?.contains("Work 'quoted' $(id) ") == true)
        XCTAssertTrue(lines.first?.contains("CODEX_HOME") == true)
        XCTAssertEqual(lines.last, "SHELL STARTED")
        XCTAssertFalse(banner.contains("\u{001B}"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
}
