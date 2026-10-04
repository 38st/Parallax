import XCTest
@testable import Parallax

final class SpaceAccountLinkTests: XCTestCase {
    func testLegacyProfileDecodesWithoutInventingIdentity() throws {
        let original = LaunchProfile(name: "Named like an account")
        let decoded = try JSONDecoder().decode(LaunchProfile.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.accountLink)
        XCTAssertEqual(decoded.storageID, original.storageID)
        XCTAssertEqual(SpaceAccountLink().summary, String(localized: "Desktop account unknown"))
    }

    func testConfirmationIsInvalidatedByIdentityChangeImportAndDuplication() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        var link = SpaceAccountLink(expectedEmail: "account@example.invalid", trackingAccountID: UUID())
        link.confirmDesktopLogin(at: date)
        XCTAssertEqual(link.desktopConfirmation?.confirmedAt, date)
        var profile = LaunchProfile(name: "Account", accountLink: link)
        let renamed = LaunchProfile(id: profile.id, storageID: profile.storageID, name: "Renamed", accountLink: link)
            .preservingIdentity(of: profile)
        XCTAssertEqual(renamed.accountLink, link)
        XCTAssertEqual(renamed.storageID, profile.storageID)
        let duplicate = profile.duplicatedWithFreshIdentity()
        XCTAssertNil(duplicate.accountLink?.desktopConfirmation)
        XCTAssertNotEqual(duplicate.storageID, profile.storageID)
        XCTAssertEqual(duplicate.accountLink?.expectedEmail, link.expectedEmail)
        profile.markLaunchConfigurationImported()
        XCTAssertNil(profile.accountLink?.desktopConfirmation)
        XCTAssertNil(profile.accountLink?.trackingAccountID)
        XCTAssertEqual(profile.accountLink?.expectedEmail, link.expectedEmail)
        link.expectedEmail = "other@example.invalid"
        XCTAssertNil(link.desktopConfirmation)
    }

    @MainActor
    func testAccountLinkSaveSurvivesRestartAndRejectsStaleEditorWithoutChangingLaunchInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = LaunchProfile(name: "Synthetic Account")
        let app = ManagedApplication(displayName: "Synthetic App", bundleIdentifier: "test.parallax.account-link",
            appPath: root.appendingPathComponent("App.app").path, preset: .claude, baseStoragePath: root.path, profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        _ = try repository.save([app], expectedVersion: .missing)
        let store = LibraryStore(repository: repository, settings: AppSettings())
        let launch = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        let link = SpaceAccountLink(expectedEmail: "account@example.invalid", trackingAccountID: UUID())
        XCTAssertTrue(store.saveAccountLink(link, applicationID: app.id, profileID: profile.id, expected: nil))
        let current = try XCTUnwrap(store.applications.first)
        let saved = try XCTUnwrap(current.profiles.first)
        XCTAssertEqual(saved.id, profile.id)
        XCTAssertEqual(saved.storageID, profile.storageID)
        XCTAssertTrue(store.launchInputsMatch(launch, application: current, profile: saved))
        XCTAssertFalse(store.saveAccountLink(SpaceAccountLink(expectedEmail: "stale@example.invalid"),
            applicationID: app.id, profileID: profile.id, expected: nil))
        let restarted = LibraryStore(repository: repository, settings: AppSettings())
        XCTAssertEqual(restarted.applications.first?.profiles.first?.accountLink, link)
        XCTAssertEqual(restarted.applications.first?.profiles.first?.argumentsText, profile.argumentsText)
    }

    func testUsageRecordCannotBecomeDesktopConfirmation() {
        let link = SpaceAccountLink(expectedEmail: "account@example.invalid", trackingAccountID: UUID())
        XCTAssertNil(link.desktopConfirmation)
        XCTAssertEqual(link.summary, String(localized: "Expected account: \("account@example.invalid")"))
    }
}
