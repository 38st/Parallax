import Darwin
import Foundation
import XCTest
@testable import Parallax

final class FilesystemSupportAuditRegressionTests: XCTestCase {
    func testFullSyncIsRequestedAndFailuresFallBack() {
        var fullCalls = 0
        var syncCalls = 0
        XCTAssertEqual(synchronizeFileDescriptor(-1, fullSync: { _ in
            fullCalls += 1; return 0
        }, sync: { _ in syncCalls += 1; return 0 }), 0)
        XCTAssertEqual(fullCalls, 1)
        XCTAssertEqual(syncCalls, 0)
        XCTAssertEqual(synchronizeFileDescriptor(-1, fullSync: { _ in
            errno = ENOTSUP; return -1
        }, sync: { _ in syncCalls += 1; return 0 }), 0)
        XCTAssertEqual(syncCalls, 1)
        XCTAssertEqual(synchronizeFileDescriptor(-1, fullSync: { _ in
            errno = EIO; return -1
        }, sync: { _ in syncCalls += 1; return 0 }), 0)
        XCTAssertEqual(syncCalls, 2)
    }

    func testMissingPackagedResourcesDoNotFallBackToDevelopmentBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-ResourceAudit-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("Fixture.app/Contents")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.parallax.missing-resources",
            "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        XCTAssertNil(PackagedRuntimeResources.resolveBundle(mainBundle: bundle,
            developmentDirectories: [PackagedRuntimeResources.bundle.bundleURL.deletingLastPathComponent()]))
        XCTAssertThrowsError(try PackagedRuntimeResources.verify(bundle: bundle)) { error in
            XCTAssertEqual(error as? PackagedRuntimeResourceError, .missing("AppIcon.icns"))
        }
    }

    func testPermissionChangeAndSynchronizationRefuseLeafSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-FSSupportAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try Data("keep".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o644), 0)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try LocalFileSystem().setPOSIXPermissions(0o600, at: link))
        XCTAssertThrowsError(try LocalFileSystem().synchronize(at: link))
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: target).posixPermissions, 0o644)
    }

    func testTrustedContainerRejectsFIFOReplacementAfterPreflight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-TrustedFIFOAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try TrustedParallaxContainer.establish(applicationSupportURL: root)
        let ordinary = TrustedContainerFileStore(container: container)
        try ordinary.replace(Data("keep".utf8), named: "data")
        let source = container.url.appendingPathComponent("data")
        let store = TrustedContainerFileStore(container: container) { boundary in
            if case let .beforeOpenFile(name, flags) = boundary, name == "data" {
                XCTAssertNotEqual(flags & O_NONBLOCK, 0)
                guard flags & O_NONBLOCK != 0 else { throw CocoaError(.userCancelled) }
                try FileManager.default.removeItem(at: source)
                XCTAssertEqual(mkfifo(source.path, 0o600), 0)
            }
        }
        XCTAssertThrowsError(try store.read(named: "data", maximumBytes: 100))
        XCTAssertThrowsError(try LocalFileSystem().synchronize(at: source))
    }

    func testTrustedContainerReadAndReplacementOpensAreNonblocking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-FSTrustedAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try TrustedParallaxContainer.establish(applicationSupportURL: root)
        let ordinary = TrustedContainerFileStore(container: container)
        try ordinary.replace(Data("keep".utf8), named: "data")
        let store = TrustedContainerFileStore(container: container) { boundary in
            if case let .beforeOpenFile(_, flags) = boundary {
                XCTAssertNotEqual(flags & O_NONBLOCK, 0)
                throw CocoaError(.userCancelled)
            }
        }
        XCTAssertThrowsError(try store.read(named: "data", maximumBytes: 100))
        XCTAssertThrowsError(try store.replace(Data("new".utf8), named: "data"))
    }
}
