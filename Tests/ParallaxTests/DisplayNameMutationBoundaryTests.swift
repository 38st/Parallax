import Foundation
import XCTest
@testable import Parallax

final class DisplayNameMutationBoundaryTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Display-Names-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testModelDecodePreservesHistoricalNamesExactly() throws {
        let historicalProfile = LaunchProfile(
            name: "\u{202E}historical space"
        )
        let historicalApplication = ManagedApplication(
            displayName: "  historical app  ",
            appPath: "/Applications/Historical.app",
            profiles: [historicalProfile]
        )
        let historicalTemplate = ProfileTemplate(name: "..")
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let decodedApplication = try decoder.decode(
            ManagedApplication.self,
            from: encoder.encode(historicalApplication)
        )
        let decodedTemplate = try decoder.decode(
            ProfileTemplate.self,
            from: encoder.encode(historicalTemplate)
        )

        XCTAssertEqual(
            decodedApplication.displayName,
            historicalApplication.displayName
        )
        XCTAssertEqual(
            decodedApplication.profiles[0].name,
            historicalProfile.name
        )
        XCTAssertEqual(decodedTemplate.name, historicalTemplate.name)
    }

    @MainActor
    func testTemplateMutationsRejectInvalidAndCanonicalizeRepair()
        throws
    {
        let (settings, defaults, suiteName) = try makeSettings()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        settings.profileTemplates = []

        XCTAssertNil(settings.addProfileTemplate(named: "\u{202E}hidden"))
        XCTAssertTrue(settings.profileTemplates.isEmpty)

        let id = try XCTUnwrap(
            settings.addProfileTemplate(
                named: "  Cafe\u{301} / QA  "
            )
        )
        XCTAssertEqual(
            settings.profileTemplate(id: id)?.name,
            "Café / QA"
        )

        var historical = ProfileTemplate(id: id, name: "..")
        settings.profileTemplates = [historical]
        historical.notes = "Must repair the name first"
        XCTAssertFalse(settings.replaceProfileTemplate(historical))
        XCTAssertEqual(settings.profileTemplates[0].notes, "")

        historical.name = "  Repaired  "
        XCTAssertTrue(settings.replaceProfileTemplate(historical))
        XCTAssertEqual(settings.profileTemplates[0].name, "Repaired")
        XCTAssertEqual(
            AppSettings(userDefaults: defaults).profileTemplates[0].name,
            "Repaired"
        )
    }

    @MainActor
    func testSpaceCreationBoundaryRejectsAndCanonicalizes() throws {
        let application = ManagedApplication(
            displayName: "Browser",
            appPath: "/Applications/Browser.app",
            baseStoragePath: temporaryDirectory.path
        )
        let persistence = DisplayNamePersistence(
            applications: [application]
        )
        let (settings, defaults, suiteName) = try makeSettings()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = LibraryStore(
            persistence: persistence,
            launcher: DisplayNameNoopLauncher(),
            settings: settings
        )

        XCTAssertNil(
            store.createSpace(
                named: "QA\u{2028}Hidden",
                templateID: nil,
                applicationID: application.id
            )
        )
        XCTAssertTrue(persistence.applications[0].profiles.isEmpty)

        let created = try XCTUnwrap(
            store.createSpace(
                named: "  Cafe\u{301} / QA  ",
                templateID: nil,
                applicationID: application.id
            )
        )
        XCTAssertEqual(created.name, "Café / QA")
        XCTAssertEqual(
            persistence.applications[0].profiles.map(\.name),
            ["Café / QA"]
        )
    }

    @MainActor
    func testGeneratedCopyNamesRepairLegacyInputAndBoundSuffixes() throws {
        let legacy = LaunchProfile(name: "Client\u{202E}hidden")
        let occupied = [
            legacy,
            LaunchProfile(name: "Space Copy"),
            LaunchProfile(name: "space copy 2"),
        ]

        let repaired = try XCTUnwrap(
            LibraryStore.duplicateProfileName(
                basedOn: legacy.name,
                existingProfiles: occupied
            )
        )
        XCTAssertEqual(repaired, "Space Copy 3")
        XCTAssertNotNil(DisplayNameValidator.normalized(repaired))

        let maximumBase = String(repeating: "é", count: 128)
        let suffixed = try XCTUnwrap(
            LibraryStore.uniqueProfileName(
                basedOn: maximumBase,
                existingProfiles: [
                    LaunchProfile(name: maximumBase)
                ]
            )
        )
        XCTAssertTrue(suffixed.hasSuffix(" 2"))
        XCTAssertLessThanOrEqual(
            suffixed.utf8.count,
            DisplayNameValidator.maximumUTF8Bytes
        )
        XCTAssertNotNil(DisplayNameValidator.normalized(suffixed))

        let oversizedGrapheme = String(
            repeating: "👩‍👩‍👧‍👦",
            count: 32
        )
        let oversizedCopy = try XCTUnwrap(
            LibraryStore.duplicateProfileName(
                basedOn: oversizedGrapheme,
                existingProfiles: []
            )
        )
        XCTAssertTrue(oversizedCopy.hasSuffix(" Copy"))
        XCTAssertLessThanOrEqual(
            oversizedCopy.utf8.count,
            DisplayNameValidator.maximumUTF8Bytes
        )
        XCTAssertNotNil(DisplayNameValidator.normalized(oversizedCopy))
    }

    @MainActor
    func testDuplicatePathNeverCopiesInvalidLegacyName() throws {
        let legacy = LaunchProfile(name: "Client\u{202E}hidden")
        let application = ManagedApplication(
            displayName: "Browser",
            appPath: "/Applications/Browser.app",
            preset: .custom,
            baseStoragePath: temporaryDirectory.path,
            profiles: [legacy]
        )
        let persistence = DisplayNamePersistence(
            applications: [application]
        )
        let (settings, defaults, suiteName) = try makeSettings()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = LibraryStore(
            persistence: persistence,
            launcher: DisplayNameNoopLauncher(),
            settings: settings
        )

        XCTAssertTrue(store.duplicateSelectedProfile())
        XCTAssertEqual(persistence.applications[0].profiles.count, 2)
        let copy = try XCTUnwrap(
            persistence.applications[0].profiles.last
        )
        XCTAssertEqual(copy.name, "Space Copy")
        XCTAssertNotEqual(copy.id, legacy.id)
        XCTAssertNotEqual(copy.storageID, legacy.storageID)
        XCTAssertNotNil(DisplayNameValidator.normalized(copy.name))
    }

    @MainActor
    func testApplicationUpdateValidatesChangedAndNewEmbeddedProfiles()
        throws
    {
        let historical = LaunchProfile(name: "Legacy\u{202E}hidden")
        let application = ManagedApplication(
            displayName: "Browser",
            appPath: "/Applications/Browser.app",
            preset: .automatic,
            profiles: [historical]
        )
        let persistence = DisplayNamePersistence(
            applications: [application]
        )
        let (settings, defaults, suiteName) = try makeSettings()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = LibraryStore(
            persistence: persistence,
            launcher: DisplayNameNoopLauncher(),
            settings: settings
        )

        var appOnlyEdit = application
        appOnlyEdit.preset = .custom
        store.updateApplication(appOnlyEdit)
        XCTAssertEqual(
            persistence.applications[0].profiles[0].name,
            historical.name,
            "An exact unchanged historical child must remain lossless."
        )

        var changedInvalid = persistence.applications[0]
        changedInvalid.profiles[0].notes = "Changed"
        store.updateApplication(changedInvalid)
        XCTAssertEqual(
            persistence.applications[0].profiles[0].notes,
            ""
        )

        var repaired = persistence.applications[0]
        repaired.profiles[0].name = "  Repaired Space  "
        repaired.profiles[0].notes = "Changed"
        store.updateApplication(repaired)
        XCTAssertEqual(
            persistence.applications[0].profiles[0].name,
            "Repaired Space"
        )

        var withNew = persistence.applications[0]
        let proposedNew = LaunchProfile(name: "  New Space  ")
        withNew.profiles.append(proposedNew)
        store.updateApplication(withNew)
        let added = try XCTUnwrap(
            persistence.applications[0].profiles.last
        )
        XCTAssertEqual(added.name, "New Space")
        XCTAssertNotEqual(added.id, proposedNew.id)
        XCTAssertNotEqual(added.storageID, proposedNew.storageID)

        let beforeInvalidAppend = persistence.applications[0]
        var withInvalidNew = beforeInvalidAppend
        withInvalidNew.profiles.append(
            LaunchProfile(name: "New\u{0000}Hidden")
        )
        store.updateApplication(withInvalidNew)
        XCTAssertEqual(
            persistence.applications[0],
            beforeInvalidAppend
        )
    }

    @MainActor
    func testDirtyEditsRequireHistoricalNameRepairButNoOpDoesNotRewrite()
        throws
    {
        let profile = LaunchProfile(name: "\u{202E}historical space")
        let application = ManagedApplication(
            displayName: "..",
            appPath: "/Applications/Historical.app",
            profiles: [profile]
        )
        let repository = LibraryRepository(
            applicationSupportURL: temporaryDirectory
        )
        let seeded = try repository.save(
            [application],
            expectedVersion: .missing
        )
        let (settings, defaults, suiteName) = try makeSettings()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: temporaryDirectory
            ),
            repository: repository,
            launcher: DisplayNameNoopLauncher(),
            settings: settings
        )

        XCTAssertTrue(
            store.applyApplicationEdit(
                draft: application,
                baseline: application,
                baselineVersion: seeded.versionToken
            )
        )
        var dirtyApplication = application
        dirtyApplication.preset = .custom
        XCTAssertFalse(
            store.applyApplicationEdit(
                draft: dirtyApplication,
                baseline: application,
                baselineVersion: seeded.versionToken
            )
        )
        XCTAssertEqual(store.applications[0].displayName, "..")

        dirtyApplication.displayName = "  Repaired App  "
        XCTAssertTrue(
            store.applyApplicationEdit(
                draft: dirtyApplication,
                baseline: application,
                baselineVersion: seeded.versionToken
            )
        )
        XCTAssertEqual(store.applications[0].displayName, "Repaired App")

        let profileBaseline = store.applications[0].profiles[0]
        let profileVersion = try XCTUnwrap(store.currentLibraryVersion)
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: profileBaseline,
                baseline: profileBaseline,
                applicationID: application.id,
                baselineVersion: profileVersion
            )
        )
        var dirtyProfile = profileBaseline
        dirtyProfile.notes = "Must repair"
        XCTAssertFalse(
            store.applyProfileEdit(
                draft: dirtyProfile,
                baseline: profileBaseline,
                applicationID: application.id,
                baselineVersion: profileVersion
            )
        )
        dirtyProfile.name = "  Repaired Space  "
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: dirtyProfile,
                baseline: profileBaseline,
                applicationID: application.id,
                baselineVersion: profileVersion
            )
        )
        XCTAssertEqual(
            store.applications[0].profiles[0].name,
            "Repaired Space"
        )
    }

    func testImportRejectsUnsafeNamesAndCanonicallyRepairsValidEdges()
        throws
    {
        let unsafe = LibraryDocument(
            applications: [
                ManagedApplication(
                    displayName: "Safe",
                    appPath: "/Applications/Safe.app",
                    profiles: [
                        LaunchProfile(name: "QA\u{202E}hidden")
                    ]
                )
            ]
        )
        let unsafeReport = LibraryImportValidator().validate(
            try JSONEncoder().encode(unsafe)
        )

        XCTAssertFalse(unsafeReport.isValid)
        XCTAssertTrue(
            unsafeReport.issues.contains {
                $0.code == .invalidDisplayName
                    && $0.path == "$.applications[0].profiles[0].name"
            }
        )

        let repairable = LibraryDocument(
            applications: [
                ManagedApplication(
                    displayName: "  Cafe\u{301} App  ",
                    appPath: "/Applications/Cafe.app",
                    profiles: [
                        LaunchProfile(name: "  Client / QA  ")
                    ]
                )
            ]
        )
        let repairableReport = LibraryImportValidator().validate(
            try JSONEncoder().encode(repairable)
        )

        XCTAssertTrue(repairableReport.isValid)
        XCTAssertEqual(
            repairableReport.document?.applications[0].displayName,
            "Café App"
        )
        XCTAssertEqual(
            repairableReport.document?.applications[0].profiles[0].name,
            "Client / QA"
        )
        XCTAssertEqual(
            repairableReport.issues.filter {
                $0.code == .normalizedDisplayName
            }.count,
            2
        )
    }

    func testImportAppliesNameByteLimitAfterCanonicalNFC() throws {
        let decomposed = String(
            repeating: "e\u{301}",
            count: 86
        )
        let canonical = decomposed
            .precomposedStringWithCanonicalMapping
        XCTAssertGreaterThan(decomposed.utf8.count, 256)
        XCTAssertLessThanOrEqual(canonical.utf8.count, 256)
        let document = LibraryDocument(
            applications: [
                ManagedApplication(
                    displayName: decomposed,
                    appPath: "/Applications/Canonical.app",
                    profiles: [
                        LaunchProfile(name: decomposed)
                    ]
                )
            ]
        )

        let report = LibraryImportValidator().validate(
            try JSONEncoder().encode(document)
        )

        XCTAssertTrue(report.isValid)
        XCTAssertFalse(
            report.issues.contains { $0.code == .stringTooLong }
        )
        XCTAssertEqual(
            report.document?.applications[0].displayName,
            canonical
        )
        XCTAssertEqual(
            report.document?.applications[0].profiles[0].name,
            canonical
        )
    }

    @MainActor
    func testKeepBothUsesBoundedLocalizedValidatedImportSuffix()
        throws
    {
        let base = String(repeating: "é", count: 128)
        let first = try XCTUnwrap(
            LibraryStore.uniqueImportedName(base, occupied: [])
        )
        let second = try XCTUnwrap(
            LibraryStore.uniqueImportedName(
                base,
                occupied: [
                    LibraryStore.normalizedImportName(first)
                ]
            )
        )
        let occupied = Set([
            LibraryStore.normalizedImportName(first),
            LibraryStore.normalizedImportName(second),
        ])
        let third = try XCTUnwrap(
            LibraryStore.uniqueImportedName(
                base,
                occupied: occupied
            )
        )
        let importedWord = String(localized: "Imported")

        XCTAssertTrue(first.hasSuffix(" \(importedWord)"))
        XCTAssertTrue(second.hasSuffix(" \(importedWord) 2"))
        XCTAssertTrue(third.hasSuffix(" \(importedWord) 3"))
        for generated in [first, second, third] {
            XCTAssertLessThanOrEqual(
                generated.utf8.count,
                DisplayNameValidator.maximumUTF8Bytes
            )
            XCTAssertNotNil(
                DisplayNameValidator.normalized(generated)
            )
        }

        let existing = [first, second].enumerated().map {
            index, name in
            ManagedApplication(
                displayName: name,
                appPath: "/Applications/Existing\(index).app"
            )
        }
        let incoming = ManagedApplication(
            displayName: base,
            appPath: "/Applications/Incoming.app"
        )
        let persistence = DisplayNamePersistence(
            applications: existing
        )
        let (settings, defaults, suiteName) = try makeSettings()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = LibraryStore(
            persistence: persistence,
            launcher: DisplayNameNoopLauncher(),
            settings: settings
        )
        let conflict = LibraryImportConflict(
            id: LibraryImportConflictID(
                importedApplicationID: incoming.id,
                importedProfileID: nil,
                existingApplicationIDs: existing.map(\.id),
                existingProfileIDs: []
            ),
            scope: .application,
            importedApplicationID: incoming.id,
            importedProfileID: nil,
            existingApplicationIDs: existing.map(\.id),
            existingProfileIDs: [],
            reasons: [.normalizedApplicationName]
        )
        let pending = LibraryStore.PendingLibraryImport(
            sourceSHA256: "fixture",
            expectedVersion: store.currentLibraryVersion,
            applications: [incoming],
            canonicalApplications: [
                LibraryImportApplication(
                    application: incoming,
                    canonicalApplicationPath: incoming.appPath
                )
            ],
            warnings: []
        )

        let resolution = try store.keepBothResolution(
            for: conflict,
            pending: pending
        )
        guard case .keepBoth(
            .application(let renamedTo, _)
        ) = resolution else {
            return XCTFail("Expected an application Keep Both rename.")
        }
        XCTAssertEqual(renamedTo, third)
    }

    @MainActor
    private func makeSettings() throws -> (
        AppSettings,
        UserDefaults,
        String
    ) {
        let suiteName = "parallax.display-name.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        return (
            AppSettings(userDefaults: defaults),
            defaults,
            suiteName
        )
    }
}

private final class DisplayNamePersistence: LibraryPersisting {
    var applications: [ManagedApplication]

    init(applications: [ManagedApplication]) {
        self.applications = applications
    }

    func load() throws -> [ManagedApplication] {
        applications
    }

    func loadResult() throws -> LibraryLoadResult {
        .current(applications)
    }

    func save(_ applications: [ManagedApplication]) throws {
        self.applications = applications
    }
}

private struct DisplayNameNoopLauncher: ApplicationLaunching {
    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) throws {}
}
