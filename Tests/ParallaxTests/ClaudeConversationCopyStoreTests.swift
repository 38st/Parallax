import XCTest
@testable import Parallax

final class ClaudeConversationCopyStoreTests: XCTestCase {
    @MainActor
    private func fixture(
        version: String? = "9.0.0",
        source: LaunchProfile = LaunchProfile(name: "Source")
    ) throws -> (LibraryStore, ManagedApplication) {
        let fixture = try ClaudeConversationFixture()
        let root = fixture.root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let plistURL = bundle.url.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        plist["CFBundleShortVersionString"] = version
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: plistURL)
        let application = ManagedApplication(
            displayName: "Claude Fixture", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .claude, baseStoragePath: root.path,
            profiles: [source, LaunchProfile(name: "Destination")])
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        _ = try repository.save([application], expectedVersion: .missing)
        let store = LibraryStore(repository: repository, settings: AppSettings())
        for (profile, data) in zip(application.profiles, [fixture.sourceRoot, fixture.destinationRoot]) {
            let path = try store.managedPaths(for: application, profile: profile).profileRoot.url
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: data, to: path)
        }
        return (store, application)
    }

    @MainActor
    func testStoreCopiesSelectedConversationAndReleasesBothReservations() async throws {
        let (store, application) = try fixture()
        let source = application.profiles[0]
        let destination = application.profiles[1]
        let catalog = try await store.claudeConversations(application: application, profile: source)
        let conversation = try XCTUnwrap(catalog.conversations.first)
        let plan = try await store.prepareClaudeConversationCopy(
            conversation, application: application, source: source, destination: destination)
        let result = try await store.copyClaudeConversation(
            plan, application: application, source: source, destination: destination, applicationIsRunning: { false })
        XCTAssertEqual(result, .copied)
        XCTAssertFalse(store.isProfileDataOperationRunning)
        let target = try await store.claudeConversations(application: application, profile: destination)
        XCTAssertEqual(target.conversations.count, 2)
        let lease = try store.reserveProfileData(application: application, profiles: application.profiles)
        lease.release()
        XCTAssertEqual(store.applications, [application])
    }

    @MainActor
    func testRunningAppOrReservedSpaceBlocksCopyWithoutPublishing() async throws {
        let (store, application) = try fixture()
        let source = application.profiles[0]
        let destination = application.profiles[1]
        let service = try store.claudeConversationService(application: application, profile: source)
        let target = try store.claudeConversationService(application: application, profile: destination)
        let conversation = try XCTUnwrap(service.catalog().conversations.first)
        let plan = try service.prepare(conversation, destination: target)
        do {
            _ = try await store.copyClaudeConversation(
                plan, application: application, source: source, destination: destination, applicationIsRunning: { true })
            XCTFail("Running Claude must block copying")
        } catch { XCTAssertEqual(error as? ClaudeConversationCopyError, .running) }
        for profile in application.profiles {
            let lease = try store.reserveProfileData(application: application, profiles: [profile])
            do {
                _ = try await store.copyClaudeConversation(
                    plan, application: application, source: source, destination: destination, applicationIsRunning: { false })
                XCTFail("Reserved storage must block copying")
            } catch { XCTAssertEqual(try target.files.itemState(at: plan.publishedRecord), .missing) }
            lease.release()
        }
        XCTAssertFalse(store.isProfileDataOperationRunning)
    }

    @MainActor
    func testExternalConfigurationIsRejectedRegardlessOfDesktopVersion() throws {
        for profile in [
            LaunchProfile(name: "External config", environmentText: "CLAUDE_CONFIG_DIR=/external/fixture"),
            LaunchProfile(name: "External data", argumentsText: "--user-data-dir=/external/fixture"),
            LaunchProfile(name: "Duplicate config", environmentText: "CLAUDE_CONFIG_DIR=/a\nCLAUDE_CONFIG_DIR=/b"),
        ] {
            let (store, application) = try fixture(source: profile)
            XCTAssertThrowsError(try store.claudeConversationService(application: application, profile: profile)) {
                XCTAssertEqual($0 as? ClaudeConversationCopyError, .externalStorage)
            }
        }
    }

    @MainActor
    func testChangedApplicationCannotUseStaleSpaceSnapshot() throws {
        let (store, application) = try fixture()
        var stale = application
        stale.displayName = "Stale"
        XCTAssertThrowsError(try store.claudeConversationService(application: stale, profile: application.profiles[0])) {
            XCTAssertEqual($0 as? ClaudeConversationCopyError, .changed)
        }
    }

    @MainActor
    func testCompatibleHistoryCopiesRegardlessOfDesktopVersion() async throws {
        for version: String? in ["2.9939.2", "2.9939.4", "2.9939.5", "9.0.0", nil, ""] {
            let (store, application) = try fixture(version: version)
            let source = application.profiles[0]
            let destination = application.profiles[1]
            let catalog = try await store.claudeConversations(application: application, profile: source)
            XCTAssertEqual(catalog.conversations.count, 1)
            XCTAssertEqual(catalog.unavailableCount, 0)
            let conversation = try XCTUnwrap(catalog.conversations.first)
            let plan = try await store.prepareClaudeConversationCopy(
                conversation, application: application, source: source, destination: destination)
            let outcome = try await store.copyClaudeConversation(
                plan, application: application, source: source, destination: destination, applicationIsRunning: { false })
            XCTAssertEqual(outcome, .copied)
            let target = try await store.claudeConversations(application: application, profile: destination)
            XCTAssertEqual(target.conversations.count, 2)
        }
    }

    @MainActor
    func testUnrecognizedVersionDoesNotBypassTranscriptValidation() async throws {
        let (store, application) = try fixture()
        let source = application.profiles[0]
        let destination = application.profiles[1]
        let service = try store.claudeConversationService(application: application, profile: source)
        let target = try store.claudeConversationService(application: application, profile: destination)
        let conversation = try XCTUnwrap(service.catalog().conversations.first)
        let path = try service.transcriptPath(for: conversation)
        let before = try target.files.manifest(at: SecureManagedPath(["UserData"]))
        let url = URL(fileURLWithPath: service.files.rootPath).appendingPathComponent(path.components.joined(separator: "/"))
        try Data("{\"futureTranscript\":true}\n".utf8).write(to: url)
        do {
            _ = try await store.prepareClaudeConversationCopy(
                conversation, application: application, source: source, destination: destination)
            XCTFail("An incompatible transcript must be rejected before writing")
        } catch { XCTAssertEqual(error as? ClaudeConversationCopyError, .unsupportedFormat) }
        XCTAssertEqual(try target.files.manifest(at: SecureManagedPath(["UserData"])), before)
    }
}
