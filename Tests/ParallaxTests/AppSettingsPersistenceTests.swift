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
