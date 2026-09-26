import Foundation
import XCTest

@testable import Parallax

final class LaunchHealthAuditRegressionTests: XCTestCase {
    func testMissingPathsCollideOnCaseInsensitiveVolume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let values = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard values.volumeSupportsCaseSensitiveNames == false else {
            throw XCTSkip("Requires a case-insensitive test volume")
        }
        let appID = UUID()
        let appStorageID = UUID()
        var reports = ["Missing", "missing"].map { name in
            ProfileHealthReport(
                applicationID: appID, profileID: UUID(), applicationStorageID: appStorageID,
                profileStorageID: UUID(), isActive: false,
                paths: [
                    ProfileHealthPathReport(
                        role: .externalUserData, requestedURL: root.appendingPathComponent(name),
                        canonicalURL: root.appendingPathComponent(name), state: .missingCreatable,
                        identity: nil, writableURL: root)
                ], issues: [])
        }
        LaunchHealthCollisionPolicy.addCollisions(to: &reports)
        XCTAssertTrue(
            reports.allSatisfy { $0.issues.contains { $0.code == .canonicalPathCollision } })
    }

    func testApplicationSymlinkUsesCanonicalBundleHealth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Actual.app")
        let contents = app.appendingPathComponent("Contents")
        let executables = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        let plist: [String: String] = [
            "CFBundleIdentifier": "example.audit", "CFBundleExecutable": "audit",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
            to: contents.appendingPathComponent("Info.plist"))
        let executable = executables.appendingPathComponent("audit")
        try Data("synthetic".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let link = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let service = LaunchHealthService()
        let direct = service.inspectApplication(
            ApplicationHealthInput(
                applicationID: UUID(), applicationURL: app,
                expectedBundleIdentifier: "example.audit"))
        let linked = service.inspectApplication(
            ApplicationHealthInput(
                applicationID: UUID(), applicationURL: link,
                expectedBundleIdentifier: "example.audit"))
        XCTAssertEqual(linked.isHealthy, direct.isHealthy)
        XCTAssertEqual(linked.canonicalApplicationURL, direct.canonicalApplicationURL)
    }
}
