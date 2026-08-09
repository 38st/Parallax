import XCTest
@testable import Parallax

final class AppSettingsPersistenceTests: XCTestCase {
    private var suites: [(defaults: UserDefaults, name: String)] = []

    override func tearDown() {
        for suite in suites {
            suite.defaults.removePersistentDomain(forName: suite.name)
        }
        suites = []
        super.tearDown()
    }

    func testBuiltInTemplateIDsAreStableAndUnique() {
        XCTAssertEqual(
            ProfileTemplate.defaults.map {
                $0.id.uuidString.lowercased()
            },
            [
                "10000000-0000-4000-8000-000000000001",
                "10000000-0000-4000-8000-000000000002",
                "10000000-0000-4000-8000-000000000003",
                "10000000-0000-4000-8000-000000000004",
            ]
        )
        XCTAssertEqual(
            Set(ProfileTemplate.defaults.map(\.id)).count,
            ProfileTemplate.defaults.count
        )
    }

    @MainActor
    func testAutomaticCrashRecoveryDefaultsOnAndPersistsOptOut()
        throws
    {
        let (defaults, _) = try makeDefaults()
        let initial = AppSettings(userDefaults: defaults)
        XCTAssertTrue(initial.automaticallyRecoverCrashedApps)

        initial.automaticallyRecoverCrashedApps = false

        let reloaded = AppSettings(userDefaults: defaults)
        XCTAssertFalse(reloaded.automaticallyRecoverCrashedApps)
    }

    @MainActor
    func testCorruptTemplateBytesAreSurfacedAndQuarantinedWithoutReplacement()
        throws
    {
        let (defaults, _) = try makeDefaults()
        let corruptData = Data("{not-json".utf8)
        defaults.set(corruptData, forKey: "settings.profileTemplates")

        let settings = AppSettings(userDefaults: defaults)

        XCTAssertEqual(settings.profileTemplates, ProfileTemplate.defaults)
        XCTAssertEqual(
            defaults.data(forKey: "settings.profileTemplates"),
            corruptData,
            "Loading must not replace corrupt bytes with fallback defaults."
        )

        guard case let .corruptProfileTemplates(quarantineKey, byteCount) =
            settings.persistenceIssues.first
        else {
            return XCTFail("Expected a surfaced corrupt-template recovery issue.")
        }
        XCTAssertEqual(byteCount, corruptData.count)
        XCTAssertEqual(defaults.data(forKey: quarantineKey), corruptData)
        XCTAssertEqual(
            settings.quarantinedProfileTemplateData(
                for: settings.persistenceIssues[0]
            ),
            corruptData
        )

        settings.appearance = .dark

        XCTAssertEqual(
            defaults.data(forKey: "settings.profileTemplates"),
            corruptData,
            "An unrelated setting update must not overwrite recoverable bytes."
        )
        XCTAssertEqual(defaults.data(forKey: quarantineKey), corruptData)
    }

    @MainActor
    func testRepeatedLoadsReuseMatchingCorruptTemplateQuarantine() throws {
        let (defaults, _) = try makeDefaults()
        let corruptData = Data([0xff, 0x00, 0x41])
        defaults.set(corruptData, forKey: "settings.profileTemplates")

        let first = AppSettings(userDefaults: defaults)
        let firstKey = corruptQuarantineKey(from: first)
        let second = AppSettings(userDefaults: defaults)
        let secondKey = corruptQuarantineKey(from: second)

        XCTAssertEqual(secondKey, firstKey)
        let quarantineKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("settings.profileTemplates.corrupt.")
        }
        XCTAssertEqual(quarantineKeys, [firstKey])
    }

    @MainActor
    func testIntentionalEmptyTemplateArrayRemainsEmptyAcrossInstances() throws {
        let (defaults, _) = try makeDefaults()
        let settings = AppSettings(userDefaults: defaults)

        settings.profileTemplates = []

        let reloaded = AppSettings(userDefaults: defaults)
        XCTAssertTrue(reloaded.profileTemplates.isEmpty)
        XCTAssertTrue(reloaded.profileTemplateNames.isEmpty)
    }

    @MainActor
    func testProfilePictureOverridePersistsAndCanReturnToAutomatic()
        throws
    {
        let (defaults, _) = try makeDefaults()
        let profileID = try XCTUnwrap(
            UUID(
                uuidString:
                    "7C4A78B1-11B8-4D41-9E0E-7C8C509BA8E4"
            )
        )
        let settings = AppSettings(userDefaults: defaults)

        settings.setProfileVisualSymbol(.leaf, for: profileID)
        settings.setProfileVisualColor(.indigo, for: profileID)

        let customized = AppSettings(userDefaults: defaults)
        XCTAssertTrue(
            customized.hasProfileVisualIdentity(for: profileID)
        )
        XCTAssertEqual(
            customized.profileVisualIdentity(for: profileID),
            ProfileInstanceVisualIdentity(
                symbol: .leaf,
                color: .indigo
            )
        )

        customized.resetProfileVisualIdentity(for: profileID)

        let automatic = AppSettings(userDefaults: defaults)
        XCTAssertFalse(
            automatic.hasProfileVisualIdentity(for: profileID)
        )
        XCTAssertEqual(
            automatic.profileVisualIdentity(for: profileID),
            ProfileInstanceVisualIdentity(profileID: profileID)
        )
    }

    @MainActor
    func testCorruptProfilePicturesArePreservedBeforeReplacement()
        throws
    {
        let (defaults, _) = try makeDefaults()
        let corruptData = Data("{not-pictures".utf8)
        defaults.set(
            corruptData,
            forKey: "settings.profileVisualIdentities"
        )

        let settings = AppSettings(userDefaults: defaults)

        guard
            case let .corruptProfileVisualIdentities(
                quarantineKey,
                byteCount
            ) = settings.persistenceIssues.first
        else {
            return XCTFail(
                "Expected a corrupt profile-picture issue."
            )
        }
        XCTAssertEqual(byteCount, corruptData.count)
        XCTAssertEqual(
            defaults.data(forKey: quarantineKey),
            corruptData
        )

        settings.resetAllProfileVisualIdentities()

        let reloaded = AppSettings(userDefaults: defaults)
        XCTAssertTrue(reloaded.profileVisualIdentities.isEmpty)
        XCTAssertEqual(
            defaults.data(forKey: quarantineKey),
            corruptData
        )
    }

    @MainActor
    func testDuplicateTemplateNamesRemainDistinctByIdentity() throws {
        let (defaults, _) = try makeDefaults()
        let settings = AppSettings(userDefaults: defaults)
        settings.profileTemplates = []

        let firstID = try XCTUnwrap(
            settings.addProfileTemplate(named: "Client")
        )
        let secondID = try XCTUnwrap(
            settings.addProfileTemplate(named: "client")
        )
        var second = try XCTUnwrap(
            settings.profileTemplate(id: secondID)
        )
        second.argumentsText = "--second"

        XCTAssertTrue(settings.replaceProfileTemplate(second))
        XCTAssertEqual(
            settings.profileTemplate(id: firstID)?.argumentsText,
            ""
        )
        XCTAssertEqual(
            settings.profileTemplate(id: secondID)?.argumentsText,
            "--second"
        )
        XCTAssertTrue(settings.removeProfileTemplate(id: firstID))
        XCTAssertNil(settings.profileTemplate(id: firstID))
        XCTAssertEqual(settings.profileTemplate(id: secondID)?.name, "client")

        let reloaded = AppSettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.profileTemplates.map(\.id), [secondID])
        XCTAssertEqual(reloaded.profileTemplates.first?.argumentsText, "--second")
    }

    @MainActor
    func testResetCanUndoToExactPriorTemplatesIncludingEmpty() throws {
        let (defaults, _) = try makeDefaults()
        let settings = AppSettings(userDefaults: defaults)
        settings.profileTemplates = []

        XCTAssertTrue(settings.resetProfileTemplatesToDefaults())
        XCTAssertEqual(settings.profileTemplates, ProfileTemplate.defaults)
        XCTAssertTrue(settings.canUndoProfileTemplateReset)

        XCTAssertTrue(settings.undoProfileTemplateReset())
        XCTAssertTrue(settings.profileTemplates.isEmpty)
        XCTAssertFalse(settings.canUndoProfileTemplateReset)

        let reloaded = AppSettings(userDefaults: defaults)
        XCTAssertTrue(reloaded.profileTemplates.isEmpty)
    }

    @MainActor
    func testEditingAfterResetInvalidatesResetUndo() throws {
        let (defaults, _) = try makeDefaults()
        let settings = AppSettings(userDefaults: defaults)
        let custom = ProfileTemplate(
            name: "Custom",
            argumentsText: "--custom"
        )
        settings.profileTemplates = [custom]

        XCTAssertTrue(settings.resetProfileTemplatesToDefaults())
        var edited = settings.profileTemplates[0]
        edited.notes = "Edited after reset"
        XCTAssertTrue(settings.replaceProfileTemplate(edited))

        XCTAssertFalse(settings.canUndoProfileTemplateReset)
        XCTAssertFalse(settings.undoProfileTemplateReset())
        XCTAssertEqual(
            settings.profileTemplate(id: edited.id)?.notes,
            "Edited after reset"
        )
    }

    @MainActor
    func testUnrelatedConcurrentSettingUpdatesDoNotRepublishStaleSnapshots()
        throws
    {
        let (_, suiteName) = try makeDefaults()
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let first = AppSettings(userDefaults: firstDefaults)
        let second = AppSettings(userDefaults: secondDefaults)

        first.defaultBaseStoragePath = "/Volumes/Profile Data"
        second.appearance = .dark
        first.confirmBeforeLaunch = true
        second.profileTemplates = []

        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reloaded = AppSettings(userDefaults: reloadedDefaults)
        XCTAssertEqual(reloaded.defaultBaseStoragePath, "/Volumes/Profile Data")
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertTrue(reloaded.confirmBeforeLaunch)
        XCTAssertTrue(reloaded.profileTemplates.isEmpty)
    }

    @MainActor
    func testLegacyTemplateNameMigrationRemainsLossless() throws {
        let (defaults, _) = try makeDefaults()
        defaults.set(
            ["Client", "Lab"],
            forKey: "settings.profileTemplateNames"
        )

        let settings = AppSettings(userDefaults: defaults)

        XCTAssertEqual(settings.profileTemplateNames, ["Client", "Lab"])
        XCTAssertNil(
            defaults.object(forKey: "settings.profileTemplateNames")
        )
        XCTAssertNotNil(defaults.data(forKey: "settings.profileTemplates"))
        XCTAssertTrue(settings.persistenceIssues.isEmpty)
    }

    @MainActor
    func testRejectedSettingWriteIsSurfacedAndDoesNotClaimPersistence() throws {
        let suiteName =
            "parallax.settings.persistence.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            RejectingUserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        suites.append((defaults, suiteName))
        let settings = AppSettings(userDefaults: defaults)
        defaults.rejectedKeys.insert("settings.appearance")

        settings.appearance = .dark

        XCTAssertTrue(
            settings.persistenceIssues.contains(
                .settingWriteFailed(key: "settings.appearance")
            )
        )
        let reloaded = AppSettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.appearance, .system)
    }

    @MainActor
    func testFailedQuarantineBlocksTemplateReplacement() throws {
        let suiteName =
            "parallax.settings.persistence.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            RejectingUserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        suites.append((defaults, suiteName))
        let corruptData = Data("{broken".utf8)
        defaults.set(corruptData, forKey: "settings.profileTemplates")
        defaults.rejectedPrefixes.insert(
            "settings.profileTemplates.corrupt."
        )

        let settings = AppSettings(userDefaults: defaults)
        settings.profileTemplates = []

        XCTAssertEqual(
            defaults.data(forKey: "settings.profileTemplates"),
            corruptData
        )
        XCTAssertTrue(
            settings.persistenceIssues.contains(
                .corruptProfileTemplatesQuarantineFailed(
                    byteCount: corruptData.count
                )
            )
        )
    }

    @MainActor
    private func corruptQuarantineKey(
        from settings: AppSettings
    ) -> String {
        guard case let .corruptProfileTemplates(key, _) =
            settings.persistenceIssues.first
        else {
            XCTFail("Expected corrupt-template issue.")
            return ""
        }
        return key
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "parallax.settings.persistence.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        suites.append((defaults, name))
        return (defaults, name)
    }
}

private final class RejectingUserDefaults: UserDefaults {
    var rejectedKeys: Set<String> = []
    var rejectedPrefixes: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectedKeys.contains(defaultName),
              !rejectedPrefixes.contains(where: defaultName.hasPrefix)
        else {
            return
        }
        super.set(value, forKey: defaultName)
    }
}
