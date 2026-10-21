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

    func testMeasureSplitsSpaceIntoPartsAndRemovingVMImageKeepsChats() throws {
        func file(_ path: String, bytes: Int) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        try file("S/UserData/vm_bundles/claudevm.bundle/rootfs.img", bytes: 400_000)
        try file("S/UserData/ClaudeConfig/projects/-work/chat.jsonl", bytes: 100_000)
        try file("S/UserData/simulator-builds/aaa/DerivedData/x", bytes: 50_000)
        try file("S/UserData/Cache/y", bytes: 20_000)
        let space = root.appendingPathComponent("S"), id = UUID()

        let before = SpaceStorage.measure(spaceID: id, folder: space)
        XCTAssertGreaterThanOrEqual(before.vmImage, 400_000)
        XCTAssertGreaterThanOrEqual(before.chats, 100_000)
        XCTAssertGreaterThanOrEqual(before.buildCaches, 50_000)
        XCTAssertGreaterThanOrEqual(before.other, 20_000)
        XCTAssertEqual(before.total, before.vmImage + before.chats + before.buildCaches + before.other)

        try Housekeeping.removeVMImage(folder: space)
        let after = SpaceStorage.measure(spaceID: id, folder: space)
        XCTAssertEqual(after.vmImage, 0)
        XCTAssertEqual(after.chats, before.chats)
        XCTAssertTrue(FileManager.default.fileExists(atPath: space.appendingPathComponent("UserData/vm_bundles").path))
    }
}
