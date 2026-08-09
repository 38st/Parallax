import Foundation
import XCTest
@testable import Parallax

final class SingletonLaunchPolicyTests: XCTestCase {
    @MainActor
    func testSynchronousImmediateExitIsFailedWithoutAcceptedState()
        async throws
    {
        let context = makeImmediateExitStore()
        let process = LifecycleRunningApplication(
            processIdentifier: 4_301,
            isTerminated: true
        )
        context.harness.processState.markExited(processIdentifier: 4_301)
        context.harness.opener.synchronousResult = .success(process)

        try context.store.openPreparedLaunch(
            context.prepared,
            profileName: context.profile.name,
            concurrentLaunchPolicy: .deny
        )

        assertImmediateExitWasNotAccepted(context)
        for _ in 0..<10 { await Task.yield() }
        assertImmediateExitWasNotAccepted(context)
    }

    @MainActor
    func testAsynchronousImmediateExitIsFailedWithoutAcceptedState()
        async throws
    {
        let context = makeImmediateExitStore()
        let process = LifecycleRunningApplication(
            processIdentifier: 4_302,
            isTerminated: true
        )

        try context.store.openPreparedLaunch(
            context.prepared,
            profileName: context.profile.name,
            concurrentLaunchPolicy: .deny
        )
        context.harness.processState.markExited(processIdentifier: 4_302)
        context.harness.opener.complete(.success(process))

        for _ in 0..<100 {
            if context.store.launchStatusPresentation(
                for: context.application,
                profile: context.profile
            )?.tone == .failure {
                break
            }
            await Task.yield()
        }
        assertImmediateExitWasNotAccepted(context)
    }

    @MainActor
    func testPreExistingSingletonRefusalDoesNotRecordAnAcceptedLaunch() throws {
        let profile = LaunchProfile(name: "Research")
        let application = ManagedApplication(
            displayName: "Browser",
            bundleIdentifier: "com.example.browser",
            appPath: "/Applications/Browser.app",
            profiles: [profile]
        )
        let persistence = SingletonPolicyPersistence(applications: [application])
        let history = LaunchHistoryStore()
        let store = LibraryStore(
            persistence: persistence,
            launchHistoryStore: history
        )
        store.applications = [application]
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id

        let requestID = UUID()
        let source = store.launchConfigurationSource(
            application: application,
            profile: profile,
            requestID: requestID
        )
        XCTAssertTrue(
            store.registerDirectLaunchIfNeeded(
                application: application,
                profile: profile,
                source: source
            )
        )
        store.handleLaunchLifecycle(
            ProfileLaunchLifecycleSnapshot(
                requestID: requestID,
                identity: ProfileActivityIdentity(
                    applicationID: application.id,
                    applicationStorageID: application.storageID,
                    profileID: profile.id,
                    profileStorageID: profile.storageID
                ),
                state: .failed(message: "pre-existing singleton"),
                openingDisposition: .preExistingSingletonRefused(
                    processIdentifier: 4242
                )
            ),
            profileName: profile.name
        )

        XCTAssertNil(store.applications[0].profiles[0].lastLaunchedAt)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(persistence.savedApplications.isEmpty)

        let presentation = try XCTUnwrap(
            store.launchStatusPresentation(
                for: application,
                profile: profile
            )
        )
        XCTAssertEqual(presentation.tone, .failure)
        XCTAssertEqual(presentation.listSummary, "Couldn’t open")
        XCTAssertTrue(presentation.message.contains("may have been brought forward"))
        XCTAssertTrue(presentation.message.contains("is unconfirmed"))
        XCTAssertTrue(presentation.message.contains("Quit every Browser instance"))
        XCTAssertTrue(presentation.message.contains("try again"))
        XCTAssertFalse(presentation.message.contains("Opened Research"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("Failed"))
    }

    func testIndeterminatePresentationOverridesFalseRunningClaim() {
        let profile = LaunchProfile(name: "Research")
        let warning = SpaceLaunchStatusPresentation(
            message: "Delivery is unconfirmed. Managed-data actions remain blocked.",
            listSummary: "Open result unverified",
            tone: .warning
        )

        let item = ProfileListItemPresentation(
            profile: profile,
            isRunning: true,
            launchStatus: warning
        )

        XCTAssertEqual(item.statusSummary, "Open result unverified")
        XCTAssertNotEqual(item.statusSummary, "Running now")
        XCTAssertTrue(warning.accessibilityLabel.contains("Warning"))
        XCTAssertTrue(warning.accessibilityLabel.contains("blocked"))
    }

    func testSingletonRecoveryCopyHasEnglishSpanishParity() throws {
        let key = "%1$@ reused a pre-existing process. That existing instance may have been brought forward, but delivery of %2$@’s arguments, environment, and isolation is unconfirmed. Parallax did not mark the space as open. Quit every %3$@ instance, then try again."
        let en = try Self.catalog(locale: "en")
        let es = try Self.catalog(locale: "es")
        let englishFormat = try XCTUnwrap(en[key])
        let spanishFormat = try XCTUnwrap(es[key])

        XCTAssertEqual(Self.placeholders(in: englishFormat), [1, 2, 3])
        XCTAssertEqual(Self.placeholders(in: spanishFormat), [1, 2, 3])

        let spanish = String(
            format: spanishFormat,
            locale: Locale(identifier: "es"),
            "Browser",
            "Investigación",
            "Browser"
        )
        XCTAssertTrue(spanish.contains("Puede que esa instancia existente pasara al frente"))
        XCTAssertTrue(spanish.contains("no se ha confirmado"))
        XCTAssertTrue(spanish.contains("Sal de todas"))
        XCTAssertTrue(spanish.contains("vuelve a intentarlo"))
    }

    private static func catalog(locale: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            PackagedRuntimeResources.bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: locale
            )
        )
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String]
        )
    }

    private static func placeholders(in value: String) -> [Int] {
        let expression = try! NSRegularExpression(pattern: "%([1-9][0-9]*)\\$@")
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: value) else {
                return nil
            }
            return Int(value[swiftRange])
        }
    }

    @MainActor
    private func makeImmediateExitStore() -> ImmediateExitStoreContext {
        let harness = LifecycleHarness()
        let profile = LaunchProfile(
            id: harness.identity.profileID,
            storageID: harness.identity.profileStorageID,
            name: "Research"
        )
        let application = ManagedApplication(
            id: harness.identity.applicationID,
            storageID: harness.identity.applicationStorageID,
            displayName: "Lifecycle Test",
            bundleIdentifier: "com.parallax.lifecycle-test",
            appPath: "/Applications/Lifecycle Test.app",
            profiles: [profile]
        )
        let persistence = SingletonPolicyPersistence(
            applications: [application]
        )
        let history = LaunchHistoryStore()
        let store = LibraryStore(
            persistence: persistence,
            profileActivityRegistry: harness.registry,
            launchHistoryStore: history,
            launcher: harness.launcher
        )
        store.applications = [application]
        let prepared = harness.prepared(requestID: UUID())
        let source = store.launchConfigurationSource(
            application: application,
            profile: profile,
            requestID: prepared.requestID
        )
        XCTAssertTrue(
            store.registerDirectLaunchIfNeeded(
                application: application,
                profile: profile,
                source: source
            )
        )
        return ImmediateExitStoreContext(
            store: store,
            harness: harness,
            persistence: persistence,
            history: history,
            application: application,
            profile: profile,
            prepared: prepared
        )
    }

    @MainActor
    private func assertImmediateExitWasNotAccepted(
        _ context: ImmediateExitStoreContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let presentation = context.store.launchStatusPresentation(
            for: context.application,
            profile: context.profile
        )
        XCTAssertEqual(presentation?.tone, .failure, file: file, line: line)
        XCTAssertTrue(
            presentation?.message.contains("safe to try again") == true,
            file: file,
            line: line
        )
        XCTAssertNil(
            context.store.applications[0].profiles[0].lastLaunchedAt,
            file: file,
            line: line
        )
        XCTAssertTrue(context.history.entries.isEmpty, file: file, line: line)
        XCTAssertTrue(
            context.persistence.savedApplications.isEmpty,
            file: file,
            line: line
        )
        XCTAssertFalse(
            context.harness.registry.isActive(identity: context.harness.identity),
            file: file,
            line: line
        )
        XCTAssertNil(
            context.store.activeTrackedLaunches[context.prepared.requestID],
            file: file,
            line: line
        )
    }
}

@MainActor
private struct ImmediateExitStoreContext {
    let store: LibraryStore
    let harness: LifecycleHarness
    let persistence: SingletonPolicyPersistence
    let history: LaunchHistoryStore
    let application: ManagedApplication
    let profile: LaunchProfile
    let prepared: PreparedLaunch
}

private final class SingletonPolicyPersistence: LibraryPersisting {
    private let applications: [ManagedApplication]
    private(set) var savedApplications: [[ManagedApplication]] = []

    init(applications: [ManagedApplication]) {
        self.applications = applications
    }

    func load() throws -> [ManagedApplication] { applications }

    func save(_ applications: [ManagedApplication]) throws {
        savedApplications.append(applications)
    }
}
