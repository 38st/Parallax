import Foundation
import XCTest
@testable import Parallax

final class ManagedRevealAuditRegressionTests: XCTestCase {
    @MainActor
    func testConfiguredManagedPathsRevealForGeneratedAndExplicitOwnership() throws {
        try withStore { store, root in
            for ownership: IsolationPathOwnership in [.generated, .explicit] {
                var profile = LaunchProfile(name: "Space", isolationOwnership: .init(userData: ownership, codexHome: ownership))
                let app = ManagedApplication(displayName: "Fixture", appPath: "/Synthetic/Fixture.app",
                                             preset: .codex, baseStoragePath: root.path, profiles: [profile])
                let paths = try store.managedPaths(for: app, profile: profile)
                profile.argumentsText = ShellWordsParser.quote("--user-data-dir=\(paths.userData.url.path)")
                profile.environmentText = "CODEX_HOME=\(paths.codexHome.url.path)"
                var revealed: [URL] = []
                XCTAssertTrue(store.revealUserData(for: app, profile: profile,
                    revealManaged: { revealed.append($0.url); return true },
                    revealExternal: { _ in XCTFail("Expected managed folder"); return false }))
                XCTAssertTrue(store.revealCodexHome(for: app, profile: profile,
                    revealManaged: { revealed.append($0.url); return true },
                    revealExternal: { _ in XCTFail("Expected managed folder"); return false }))
                XCTAssertEqual(revealed, [paths.userData.url, paths.codexHome.url])
                XCTAssertNil(store.errorMessage)
            }
        }
    }

    @MainActor
    func testExplicitExternalRevealDoesNotResolveUnavailableManagedRoot() throws {
        try withStore { store, root in
            let unavailable = root.appendingPathComponent("not-a-directory")
            try Data().write(to: unavailable)
            let external = root.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            let profile = LaunchProfile(name: "Space",
                argumentsText: ShellWordsParser.quote("--user-data-dir=\(external.path)"),
                environmentText: "CODEX_HOME=\(external.path)",
                isolationOwnership: .init(userData: .explicit, codexHome: .explicit))
            let app = ManagedApplication(displayName: "Fixture", appPath: "/Synthetic/Fixture.app",
                preset: .codex, baseStoragePath: unavailable.path, profiles: [profile])
            var revealed: [URL] = []
            XCTAssertTrue(store.revealUserData(for: app, profile: profile,
                revealManaged: { _ in XCTFail("Expected external folder"); return false },
                revealExternal: { revealed.append($0.url); return true }))
            XCTAssertTrue(store.revealCodexHome(for: app, profile: profile,
                revealManaged: { _ in XCTFail("Expected external folder"); return false },
                revealExternal: { revealed.append($0.url); return true }))
            XCTAssertEqual(revealed, [external, external])
            XCTAssertNil(store.errorMessage)
        }
    }

    @MainActor
    private func withStore(_ body: (LibraryStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-RevealAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: root))
        try body(store, root)
    }
}
