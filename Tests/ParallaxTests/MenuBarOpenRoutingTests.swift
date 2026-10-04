import AppKit
import XCTest
@testable import Parallax

@MainActor
final class MenuBarOpenRoutingTests: XCTestCase {
    func testQueuedMenuOpenUsesCapturedSceneAndKeepsConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let profile = LaunchProfile(name: "Explicit target")
        let app = ManagedApplication(displayName: "Synthetic App", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .custom, baseStoragePath: root.path, profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        _ = try repository.save([app], expectedVersion: .missing)
        let settings = AppSettings()
        settings.confirmBeforeLaunch = true
        let store = LibraryStore(repository: repository, launcher: AuditNoopLauncher(), settings: settings)
        let registry = ParallaxMainWindowRegistry()
        registry.requestOpen(applicationID: app.id, profileID: profile.id)
        XCTAssertFalse(store.isShowingLaunchConfirmation)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { registry.remove(window); window.close() }
        registry.register(window, store: store)
        XCTAssertTrue(store.isShowingLaunchConfirmation)
        XCTAssertEqual(store.pendingLaunchProfileName, profile.name)
        XCTAssertEqual(store.selectedProfileID, profile.id)
        XCTAssertEqual(store.sceneCoordinator.requestedApplicationPage, app.id)
        XCTAssertTrue(store.launchPreparationTasks.isEmpty)
        store.cancelLaunch()

        // A removed target must not fall back to an arbitrary remaining space.
        registry.remove(window)
        registry.requestOpen(applicationID: app.id, profileID: UUID())
        registry.register(window, store: store)
        XCTAssertFalse(store.isShowingLaunchConfirmation)
        XCTAssertEqual(store.errorMessage, SpaceLinkError.unknownSpace.localizedDescription)
        XCTAssertTrue(store.launchPreparationTasks.isEmpty)
    }
}
