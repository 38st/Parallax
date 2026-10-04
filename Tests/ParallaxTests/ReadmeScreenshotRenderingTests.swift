import AppKit
import SwiftUI
import XCTest

@testable import Parallax

final class ReadmeScreenshotRenderingTests: XCTestCase {
    @available(*, deprecated)
    @MainActor
    func testRenderReadmeScreenshots() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "PARALLAX_README_SCREENSHOT_DIR"
        ] else {
            throw XCTSkip("Set PARALLAX_README_SCREENSHOT_DIR to render the README screenshots.")
        }
        guard !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenshotError.invalidOutputDirectory
        }

        // Initialize AppKit in the test process only, never ParallaxApp or its
        // app delegate. Only this process's synthetic windows are shown.
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("Screenshot rendering requires access to a macOS window server.")
        }
        let size = NSSize(width: 1280, height: 860)
        let margin: CGFloat = 16
        guard let screen = NSScreen.screens.first(where: {
            $0.backingScaleFactor == 2
                && $0.frame.width >= size.width + margin * 2
                && $0.frame.height >= size.height + margin * 2
        }) else { throw ScreenshotError.displayTooSmall }
        let availableFrame = screen.visibleFrame.width >= size.width + margin * 2
            && screen.visibleFrame.height >= size.height + margin * 2
            ? screen.visibleFrame : screen.frame
        let frame = NSRect(
            x: availableFrame.midX - size.width / 2,
            y: availableFrame.midY - size.height / 2,
            width: size.width, height: size.height
        )
        let backdrop = NSPanel(
            contentRect: frame.insetBy(dx: -margin, dy: -margin),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backdrop.isReleasedWhenClosed = false
        backdrop.isFloatingPanel = false
        backdrop.hidesOnDeactivate = false
        backdrop.level = .normal
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        backdrop.ignoresMouseEvents = true
        backdrop.animationBehavior = .none
        defer {
            backdrop.orderOut(nil)
            backdrop.close()
        }
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.animationBehavior = .none
        window.title = "Parallax"
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallax-readme-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove screenshot fixtures: \(error)") }
        }

        let application = try makeApplication(root: root)
        let persistence = LibraryPersistence(applicationSupportURL: root)
        try persistence.save([application])
        let legacy = SettingsLegacySnapshotClassifier.classify([
            "settings.defaultBaseStoragePath": root.appendingPathComponent("Spaces").path,
            "settings.appearance": "light",
            "settings.automaticallyRecoverCrashedApps": false,
        ])
        let settings = AppSettings(production: SettingsRuntimeBootstrapper(
            applicationSupportURL: root,
            legacyApplicationIdentifier: "test.parallax.readme",
            legacyCaptureOverride: { legacy }
        ).bootstrap())
        XCTAssertEqual(settings.persistenceAuthority, .versionedRepository)

        // Match the production scene's store ownership and ContentView inputs.
        // The process-level composition also starts live provider polling;
        // this harness supplies a rejecting service instead, with no timer.
        let scene = SceneCoordinator()
        scene.compactProfileListHeight = 340
        let libraryChanges = LibraryChangeBroadcaster()
        let store = LibraryStore(
            repository: LibraryRepository(applicationSupportURL: root),
            launcher: ScreenshotLauncher(),
            applicationInstanceController: ScreenshotInstances(),
            secretStore: ScreenshotSecrets(),
            settings: settings,
            sceneCoordinator: scene,
            libraryChangeBroadcaster: libraryChanges
        )
        scene.editorDraftRegistry.register(store)
        let sceneStore = ParallaxSceneStore(mainWindows: ParallaxMainWindowRegistry()) { store }
        store.selectedApplicationID = application.id
        store.selectedProfileID = application.profiles[2].id
        guard case .loaded = store.loadState else {
            throw ScreenshotError.libraryNotReady
        }
        guard store.errorMessage == nil, store.activeTrackedLaunches.isEmpty else {
            throw ScreenshotError.libraryNotReady
        }

        // Relative labels in the real views use the current date. Freeze the
        // store clock at this capture's reference time to keep all rows fresh.
        let now = Date()
        let accounts = makeAccounts(now: now)
        let accountStore = CorporateUsageStore(
            userDefaults: try XCTUnwrap(ScreenshotDefaults(
                fileURL: root.appendingPathComponent("accounts.json")
            )),
            initialAccounts: accounts,
            clock: { now },
            freshnessScheduler: ScreenshotFreshnessScheduler()
        )
        XCTAssertTrue(accountStore.saveTrackedAccount(accounts[0]))
        let operations = CorporateAccountOperationCoordinator(
            store: accountStore, service: ScreenshotAccountService()
        )
        defer { operations.prepareForTermination() }

        scene.selectedWorkspaceTab = .localSpaces
        store.selectedApplicationID = nil
        store.selectedProfileID = nil
        let content = ContentView(
            store: store,
            corporateStore: accountStore,
            corporateAccountOperationCoordinator: operations
        )
        .background(ParallaxMainWindowCapture(sceneStore: sceneStore))
        .frame(minWidth: 980, minHeight: 620)
        .preferredColorScheme(appColorScheme(for: settings.appearance))
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .current)
        // Hosting through a controller attaches the real SwiftUI toolbar to
        // the window. Start Home at the top with no implicit space selection.
        let hostingController = NSHostingController(
            rootView: content.defaultScrollAnchor(.top)
        )
        hostingController.sceneBridgingOptions = [.title, .toolbars]
        let hosting = hostingController.view
        defer {
            window.orderOut(nil)
            backdrop.orderOut(nil)
            window.contentViewController = nil
            sceneStore.windowWillClose(window)
            for task in store.healthInspectionTasks.values { task.cancel() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        hosting.appearance = window.appearance
        window.contentViewController = hostingController
        window.setFrame(frame, display: true)
        // The compositor needs real, visible windows to resolve sidebar
        // materials. Keep the neutral panel immediately below our window;
        // neither activate another app nor capture the desktop/backdrop itself.
        backdrop.orderFrontRegardless()
        window.orderFrontRegardless()
        backdrop.order(.below, relativeTo: window.windowNumber)
        settleLayout(hosting)

        guard scene.selectedWorkspaceTab == .localSpaces,
              store.selectedApplicationID == nil,
              operations.runningOperationCount == 0,
              accountStore.inFlightAttemptKinds.isEmpty,
              accountStore.persistenceErrorMessage == nil,
              accountStore.trackedAccounts.allSatisfy({
                  CorporateAccountFreshnessPolicy.state(for: $0, now: now).isCurrent
              })
        else { throw ScreenshotError.viewNotReady }
        let homePNG = try capture(window, name: "Home")

        // Drive the same explicit selection used by Home and the sidebar.
        hostingController.rootView = content.defaultScrollAnchor(.top)
        store.selectedApplicationID = application.id
        store.selectedProfileID = application.profiles[2].id
        scene.selectedWorkspaceTab = .localSpaces
        settleLayout(hosting)
        // Health inspection is asynchronous; wait for its real result rather
        // than capturing the initial "Health inspection" placeholder.
        let deadline = Date().addingTimeInterval(5)
        while !store.healthInspectionTasks.isEmpty, Date() < deadline {
            settleLayout(hosting, duration: 0.1)
        }
        guard scene.selectedWorkspaceTab == .localSpaces,
              store.healthInspectionTasks.isEmpty,
              store.selectedApplicationID == application.id,
              store.selectedProfileID == application.profiles[2].id,
              store.selectedProfile?.name == "Client — Acme",
              store.errorMessage == nil
        else { throw ScreenshotError.viewNotReady }
        let localSpacesPNG = try capture(window, name: "Local Spaces")

        // Publish only after both views rendered successfully. These are the
        // only files retained; every store and space lives under the temp root.
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try localSpacesPNG.write(
            to: output.appendingPathComponent("parallax-local-spaces.png"), options: .atomic
        )
        try homePNG.write(
            to: output.appendingPathComponent("parallax-home.png"), options: .atomic
        )
    }

    @available(*, deprecated)
    @MainActor
    func testRenderAccountAndHistoryPanels() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["PARALLAX_README_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set PARALLAX_README_SCREENSHOT_DIR to render panels.")
        }
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) else {
            throw XCTSkip("Panel rendering requires a Retina macOS window server.")
        }
        let fixture = try ClaudeConversationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.destinationRecordURL)
        let bundle = try ValidApplicationBundleFixture.create(in: fixture.root)
        let profiles = [
            LaunchProfile(name: "Work", accountLink: SpaceAccountLink(expectedEmail: "work@example.invalid")),
            LaunchProfile(name: "Personal", accountLink: SpaceAccountLink(expectedEmail: "personal@example.invalid")),
        ]
        let application = ManagedApplication(displayName: "Synthetic Claude", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .claude, baseStoragePath: fixture.root.path, profiles: profiles)
        let repository = LibraryRepository(applicationSupportURL: fixture.root.appendingPathComponent("Support"))
        _ = try repository.save([application], expectedVersion: .missing)
        let store = LibraryStore(repository: repository, launcher: AuditNoopLauncher(), settings: AppSettings())
        for (profile, source) in zip(profiles, [fixture.sourceRoot, fixture.destinationRoot]) {
            let paths = try store.managedPaths(for: application, profile: profile)
            try FileManager.default.createDirectory(at: paths.profileRoot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: paths.profileRoot.url)
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        func render(_ view: AnyView, name: String) throws {
            let window = NSWindow(contentRect: NSRect(x: screen.frame.midX - 330, y: screen.frame.midY - 380,
                width: 660, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.animationBehavior = .none
            window.title = "Parallax — Synthetic Preview"
            defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
            let host = NSHostingController(rootView: view.environment(\.locale, Locale(identifier: "en_US")))
            window.contentViewController = host
            window.orderFrontRegardless()
            settleLayout(host.view, duration: 1.2)
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                y: screen.visibleFrame.midY - window.frame.height / 2))
            settleLayout(host.view)
            try capture(window, name: name, requiresToolbar: false).write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        try render(AnyView(SpaceAccountDetailsView(store: store, corporateStore: nil, application: application, profile: profiles[0])),
            name: "parallax-account-details")
        try render(AnyView(ConversationLibraryView(store: store, application: application, source: profiles[0])),
            name: "parallax-history-review")
        try await store.enrollConversationLibrary(application: application, source: profiles[0],
            namespaces: Dictionary(uniqueKeysWithValues: profiles.map { ($0.storageID, fixture.namespace.components) }), expected: nil)
        try render(AnyView(ConversationLibraryView(store: store, application: application, source: profiles[0])),
            name: "parallax-history")
        store.conversationSwitchMessage = String(localized: "Saving conversations…")
        store.errorMessage = ProfileActivityRegistryError.storageReservedForDataOperation.localizedDescription
        try render(AnyView(ConversationLibraryView(store: store, application: application, source: profiles[0])),
            name: "parallax-history-error")
        store.errorMessage = nil
        store.conversationSwitchMessage = nil
        XCTAssertEqual(try store.conversationLibrary(application: application, profile: profiles[0])?.bindings.count, 2)
        XCTAssertTrue(store.launchPreparationTasks.isEmpty)
        let accountStore = CorporateUsageStore(
            userDefaults: try XCTUnwrap(ScreenshotDefaults(fileURL: fixture.root.appendingPathComponent("accounts.json"))),
            initialAccounts: [], clock: { Date(timeIntervalSince1970: 1_000) },
            freshnessScheduler: ScreenshotFreshnessScheduler())
        let operations = CorporateAccountOperationCoordinator(store: accountStore, service: ScreenshotAccountService())
        defer { operations.prepareForTermination() }
        try render(AnyView(WorkspaceSettingsView(store: store, corporateStore: accountStore, operations: operations)
            .frame(width: 760, height: 700)), name: "parallax-settings")
    }

    @MainActor
    private func settleLayout(_ view: NSView, duration: TimeInterval = 0.8) {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            view.window?.displayIfNeeded()
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        } while Date() < deadline
        view.layoutSubtreeIfNeeded()
    }

    // macOS 14 deprecates this API, but it can capture this process's own
    // windows without requesting Screen Recording access. Keep the caller
    // deprecated too so the opt-in test builds with warnings as errors.
    @available(*, deprecated)
    @MainActor
    private func capture(_ window: NSWindow, name: String, requiresToolbar: Bool = true) throws -> Data {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard !requiresToolbar || window.toolbar?.isVisible == true else {
            throw ScreenshotError.missingToolbar(name)
        }
        guard window.isVisible, window.windowNumber > 0,
              let capturedImage = CGWindowListCreateImage(
                  .null, .optionIncludingWindow,
                  CGWindowID(window.windowNumber),
                  [.boundsIgnoreFraming, .bestResolution]
              ),
              capturedImage.width > 0, capturedImage.height > 0
        else { throw ScreenshotError.emptyRendering(name) }
        let width = capturedImage.width
        let height = capturedImage.height
        guard width == Int(window.frame.width * 2),
              height == Int(window.frame.height * 2)
        else { throw ScreenshotError.unexpectedResolution(name, width, height) }

        // Normalize to 8-bit RGBA while preserving the compositor's transparent
        // rounded corners. boundsIgnoreFraming omits the system window shadow.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        let pixelRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(pixelRect)
        context.draw(capturedImage, in: pixelRect)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        bitmap.size = window.frame.size
        // A window-server failure can produce a valid but blank PNG.
        var sampledColors: Set<UInt32> = []
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in stride(from: 0, to: height, by: 13) {
            for x in stride(from: 0, to: width, by: 13) {
                let offset = y * context.bytesPerRow + x * 4
                // Transparent pixels cannot count as rendered UI detail.
                guard pixels[offset + 3] > 0 else { continue }
                sampledColors.insert(
                    UInt32(pixels[offset]) << 16
                        | UInt32(pixels[offset + 1]) << 8
                        | UInt32(pixels[offset + 2])
                )
            }
        }
        guard sampledColors.count > 32 else { throw ScreenshotError.blankRendering(name) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        guard !png.isEmpty else { throw ScreenshotError.emptyRendering(name) }
        guard png.count < 1_500_000 else { throw ScreenshotError.pngTooLarge }
        return png
    }

    private func makeApplication(root: URL) throws -> ManagedApplication {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let hasChrome = FileManager.default.fileExists(atPath: chrome.path)
        let appURL = hasChrome ? chrome : root.appendingPathComponent("Example Browser.app")
        if !hasChrome {
            // A generic synthetic bundle supplies the fallback icon. It is
            // never installed, registered with LaunchServices, or launched.
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        }
        let base = root.appendingPathComponent("Spaces", isDirectory: true)
        var application = ManagedApplication(
            displayName: hasChrome ? "Google Chrome" : "Example Browser",
            appPath: appURL.path,
            preset: .chromium,
            baseStoragePath: base.path,
            profiles: ["Work", "Personal", "Client — Acme", "Testing"].map {
                LaunchProfile(name: $0, isolationOwnership: .init(userData: .generated))
            }
        )
        for index in application.profiles.indices {
            let profileRoot = ManagedPathResolver.profileRootURL(
                baseRootURL: base, applicationStorageID: application.storageID,
                profileStorageID: application.profiles[index].storageID
            )
            let userData = profileRoot.appendingPathComponent("UserData", isDirectory: true)
            try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
            application.profiles[index].argumentsText = "--user-data-dir=\"\(userData.path)\""
        }
        application.profiles[2].notes = "Client projects, reviews, and shared resources for Acme."
        return application
    }

    private func makeAccounts(now: Date) -> [TrackedAIAccount] {
        [
            (.codex, "Work account", "work@example.com", "Plus", 32, 18),
            (.codex, "Personal account", "personal@example.com", "Plus", 12, 8),
            (.claude, "Work account", "work@example.com", "Pro", 46, 29),
        ].map { (provider: AIProvider, label: String, email: String, plan: String, session: Int, weekly: Int) in
            TrackedAIAccount(
                id: UUID(), provider: provider, label: label, email: email,
                planName: plan, usagePercent: session,
                resetsAt: now.addingTimeInterval(3 * 60 * 60),
                lastCheckedAt: now.addingTimeInterval(-60),
                isConnected: true, lifetimeTokens: nil,
                usageWindows: [
                    AIUsageWindow(kind: .session, usagePercent: session,
                                  resetsAt: now.addingTimeInterval(3 * 60 * 60)),
                    AIUsageWindow(kind: .weeklyAllModels, usagePercent: weekly,
                                  resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)),
                ]
            )
        }
    }
}

private enum ScreenshotError: LocalizedError, CustomStringConvertible {
    case invalidOutputDirectory
    case displayTooSmall
    case libraryNotReady
    case viewNotReady
    case emptyRendering(String)
    case blankRendering(String)
    case missingToolbar(String)
    case unexpectedResolution(String, Int, Int)
    case pngTooLarge
    case forbiddenOperation

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .invalidOutputDirectory:
            "PARALLAX_README_SCREENSHOT_DIR must name an output directory."
        case .displayTooSmall:
            "Screenshot rendering needs a 2x Retina display at least 1312 × 892 points to show the window and its neutral backdrop."
        case .libraryNotReady:
            "The synthetic library did not load cleanly or has an active launch."
        case .viewNotReady:
            "The requested workspace selection or synthetic data did not settle before capture."
        case .emptyRendering(let name):
            "\(name): the window compositor returned no image or an empty bitmap. Check that the test window is visible and has window-server access."
        case .blankRendering(let name):
            "\(name): the captured bitmap is blank or has insufficient rendered detail. No screenshots were written."
        case .missingToolbar(let name):
            "\(name): SwiftUI has not attached a visible toolbar to the test window. No screenshots were written."
        case .unexpectedResolution(let name, let width, let height):
            "\(name): the window compositor returned \(width) × \(height) pixels instead of a 2x image. No screenshots were written."
        case .pngTooLarge:
            "The rendered PNG exceeds the 1.5 MB README image limit."
        case .forbiddenOperation:
            "Screenshot rendering attempted a forbidden provider, application, or secret operation."
        }
    }
}

// CorporateUsageStore's persistence interface is UserDefaults. Override its
// data access to use one disposable file, never the user's preferences domain.
private final class ScreenshotDefaults: UserDefaults {
    let fileURL: URL

    init?(fileURL: URL) {
        self.fileURL = fileURL
        super.init(suiteName: "test.parallax.readme.\(UUID().uuidString)")
    }

    override func data(forKey defaultName: String) -> Data? {
        try? Data(contentsOf: fileURL)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard let data = value as? Data else {
            XCTFail("Unexpected non-data preference in screenshot fixture")
            return
        }
        do { try data.write(to: fileURL, options: .atomic) }
        catch { XCTFail("Could not save synthetic account metadata: \(error)") }
    }
}

@MainActor
private final class ScreenshotFreshnessScheduler: CorporateFreshnessScheduling {
    func schedule(_ invalidate: @escaping @MainActor () -> Void) {}
}

private struct ScreenshotAccountService: CorporateAccountOperationServicing {
    func login(provider: AIProvider, accountID: UUID) async throws -> ConnectedAIAccountStatus {
        XCTFail("Screenshot rendering must never sign in to a provider")
        throw ScreenshotError.forbiddenOperation
    }

    func refresh(provider: AIProvider, accountID: UUID) async throws -> ConnectedAIAccountStatus {
        XCTFail("Synthetic accounts should already be fresh")
        throw ScreenshotError.forbiddenOperation
    }
}

private struct ScreenshotLauncher: ApplicationLaunching {
    func launch(
        application: ManagedApplication, profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        XCTFail("Screenshot rendering must never launch an application")
        throw ScreenshotError.forbiddenOperation
    }
}

@MainActor
private final class ScreenshotInstances: ApplicationInstanceControlling {
    func instances(
        for application: ManagedApplication, trackedProcesses: [ProfileRunningProcess]
    ) -> [ManagedApplicationInstance] { [] }

    func requestQuit(_ instance: ManagedApplicationInstance, from application: ManagedApplication) throws {
        XCTFail("Screenshot rendering must never quit an application")
        throw ScreenshotError.forbiddenOperation
    }

    func requestActivate(_ instance: ManagedApplicationInstance, from application: ManagedApplication) throws {
        XCTFail("Screenshot rendering must never activate an application")
        throw ScreenshotError.forbiddenOperation
    }
}

private struct ScreenshotSecrets: SecretStoring {
    func resolve(_ reference: EnvironmentSecretReference) async throws -> SecretValue {
        XCTFail("Screenshot rendering must never read secrets")
        throw ScreenshotError.forbiddenOperation
    }

    func store(_ value: SecretValue, for reference: EnvironmentSecretReference) async throws {
        XCTFail("Screenshot rendering must never store secrets")
        throw ScreenshotError.forbiddenOperation
    }

    func remove(_ reference: EnvironmentSecretReference) async throws {
        XCTFail("Screenshot rendering must never remove secrets")
        throw ScreenshotError.forbiddenOperation
    }
}
