import Foundation
import XCTest
@testable import Parallax

final class SpaceLinkAuditRegressionTests: XCTestCase {
    func testValidLinkRoundTripsOnlySpaceIdentity() throws {
        let id = UUID()
        let url = try XCTUnwrap(SpaceLink.url(profileID: id))
        XCTAssertEqual(try SpaceLink.profileID(from: url), id)
        XCTAssertEqual(url.absoluteString, "parallax://open?space=\(id.uuidString.lowercased())")
    }

    func testMalformedLinksAndEveryOtherActionAreRejected() throws {
        let id = UUID().uuidString
        for text in [
            "parallax://open", "parallax://open?space=", "parallax://open?space=bad",
            "parallax://open?space=\(id)&space=\(id)", "parallax://open?space=\(id)&action=delete",
            "parallax://delete?space=\(id)", "https://open?space=\(id)",
            "parallax://open/path?space=\(id)", "parallax://open?space=\(id)#fragment",
            "parallax://user@open?space=\(id)", "parallax://open:123?space=\(id)",
            "parallax://open?Space=\(id)", "parallax://open?space=\(id)&",
        ] {
            XCTAssertThrowsError(try SpaceLink.profileID(from: XCTUnwrap(URL(string: text))), text)
        }
    }

    @MainActor
    func testLinkAlwaysRequiresConfirmationWithGlobalConfirmationDisabledOrEnabled() throws {
        for enabled in [false, true] {
            let (store, launcher) = try fixture()
            store.settings.confirmBeforeLaunch = enabled
            let profile = try XCTUnwrap(store.applications.first?.profiles.first)
            let request = try store.spaceLinkRequest(for: XCTUnwrap(SpaceLink.url(profileID: profile.id)))
            XCTAssertEqual(launcher.count, 0)
            XCTAssertTrue(request.message.contains("Work"))
            XCTAssertTrue(request.message.contains("Fixture"))
            XCTAssertTrue(store.confirmSpaceLink(request))
            XCTAssertFalse(store.isShowingLaunchConfirmation)
            XCTAssertEqual(launcher.count, 1)
        }
    }

    @MainActor
    func testUnknownSpaceAndChangedOrRemovedTargetNeverLaunch() throws {
        let (store, launcher) = try fixture()
        XCTAssertThrowsError(try store.spaceLinkRequest(for: XCTUnwrap(SpaceLink.url(profileID: UUID())))) { error in
            guard case SpaceLinkError.unknownSpace = error else {
                return XCTFail("Expected an unknown-space error, got \(error)")
            }
        }
        let profile = try XCTUnwrap(store.applications.first?.profiles.first)
        let request = try store.spaceLinkRequest(for: XCTUnwrap(SpaceLink.url(profileID: profile.id)))
        store.applications[0].profiles[0].environmentText = "CHANGED=yes"
        XCTAssertFalse(store.confirmSpaceLink(request))
        store.applications = []
        XCTAssertFalse(store.confirmSpaceLink(request))
        XCTAssertEqual(launcher.count, 0)
    }

    @MainActor
    func testBookkeepingDoesNotInvalidateLinkConfirmation() throws {
        let (store, launcher) = try fixture()
        let profile = try XCTUnwrap(store.applications.first?.profiles.first)
        store.applications[0].profiles.append(LaunchProfile(name: "Other"))
        let request = try store.spaceLinkRequest(for: XCTUnwrap(SpaceLink.url(profileID: profile.id)))
        store.applications[0].profiles[0].lastLaunchedAt = Date(timeIntervalSince1970: 10)
        store.applications[0].profiles[1].lastLaunchedAt = Date(timeIntervalSince1970: 20)
        XCTAssertTrue(store.confirmSpaceLink(request))
        XCTAssertEqual(launcher.count, 1)
    }

    @MainActor
    func testUnsavedDraftBlocksConfirmedLink() throws {
        let (store, launcher) = try fixture()
        let application = try XCTUnwrap(store.applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let request = try store.spaceLinkRequest(for: XCTUnwrap(SpaceLink.url(profileID: profile.id)))
        var draft = profile
        draft.environmentText = "CHANGED=yes"
        store.rememberProfileEditingDraft(applicationID: application.id, draft: draft, baseline: profile,
            baselineVersion: .missing, stagedKeychainReferences: [], pendingKeychainDeletionReferences: [])
        XCTAssertFalse(store.confirmSpaceLink(request))
        XCTAssertEqual(launcher.count, 0)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testFailedQueuedConfirmationUsesOnlyStoreErrorPresentation() throws {
        let (store, launcher) = try fixture()
        let profile = try XCTUnwrap(store.applications.first?.profiles.first)
        let queue = SpaceLinkPromptQueue()
        queue.receive(try XCTUnwrap(SpaceLink.url(profileID: profile.id))) { try store.spaceLinkRequest(for: $0) }
        let prompt = try XCTUnwrap(queue.current)
        store.applications = []
        queue.confirm(prompt) { XCTAssertFalse(store.confirmSpaceLink($0)) }
        XCTAssertEqual(store.errorMessage, SpaceLinkError.changed.localizedDescription)
        XCTAssertTrue(queue.prompts.isEmpty)
        XCTAssertEqual(launcher.count, 0)
    }

    @MainActor
    private func fixture() throws -> (LibraryStore, SpaceLinkRecordingLauncher) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-Link-Audit-\(UUID())")
        let suite = "Parallax-Link-Audit-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let launcher = SpaceLinkRecordingLauncher()
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: root),
            profileActivityRegistry: ProfileActivityRegistry(), launcher: launcher, settings: AppSettings(userDefaults: defaults))
        store.settings.confirmBeforeLaunch = false
        store.applications = [ManagedApplication(displayName: "Fixture", bundleIdentifier: "example.fixture",
            appPath: root.appendingPathComponent("Fixture.app").path, baseStoragePath: root.path,
            profiles: [LaunchProfile(name: "Work")])]
        return (store, launcher)
    }
}

private final class SpaceLinkRecordingLauncher: ApplicationLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }

    func launch(application: ManagedApplication, profile: LaunchProfile,
                completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
        lock.withLock { calls += 1 }
    }
}
