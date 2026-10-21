import XCTest
@testable import Parallax

final class HousekeepingTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("housekeeping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ path: String, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    func testOnlyOldStampedBackupsAreRemoved() throws {
        let backups = root.appendingPathComponent("ChatBackups")
        let old = try folder("ChatBackups/\(stamp(now - 20 * day))-local_a-1234abcd")
        let recent = try folder("ChatBackups/\(stamp(now - 2 * day))-local_b-1234abcd")
        let unstamped = try folder("ChatBackups/keep-me", modified: now - 100 * day)

        XCTAssertEqual(Housekeeping.pruneBackups(in: backups, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unstamped.path))
    }

    func testStaleBuildCachesAreRemovedAndRecentlyBuiltOnesKept() throws {
        let userData = root.appendingPathComponent("UserData")
        // Deepest first: creating a folder updates its parent's date.
        try folder("UserData/simulator-builds/aaa/DerivedData", modified: now - 30 * day)
        let stale = try folder("UserData/simulator-builds/aaa", modified: now - 30 * day)
        // The project folder itself is old, but a build log below it is fresh.
        try folder("UserData/simulator-builds/bbb/DerivedData/Logs", modified: now - day)
        try folder("UserData/simulator-builds/bbb/DerivedData", modified: now - 30 * day)
        let used = try folder("UserData/simulator-builds/bbb", modified: now - 30 * day)

        XCTAssertEqual(Housekeeping.pruneCaches(userData: [userData, root.appendingPathComponent("Missing")], now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.path))
    }

    func testIdleVMImageIsRemovedAndRecentlyRunOneKept() throws {
        func bundle(_ space: String, diskUsed: Date) throws -> URL {
            let url = try folder("\(space)/UserData/vm_bundles/claudevm.bundle")
            let disk = url.appendingPathComponent("rootfs.img")
            try Data([1]).write(to: disk)
            try FileManager.default.setAttributes([.modificationDate: diskUsed], ofItemAtPath: disk.path)
            try FileManager.default.setAttributes([.modificationDate: now - 60 * day], ofItemAtPath: url.path)
            return url
        }
        let idle = try bundle("A", diskUsed: now - 30 * day)
        let active = try bundle("B", diskUsed: now - 3 * day)

        let spaces = ["A", "B"].map { root.appendingPathComponent("\($0)/UserData") }
        XCTAssertEqual(Housekeeping.pruneCaches(userData: spaces, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: idle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    }
}
