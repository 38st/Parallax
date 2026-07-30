import XCTest
@testable import Parallax

final class SanitizedSupportBundleTests: XCTestCase {
    func testBundleAllowlistExcludesPrivateConfigurationAndRawCrashData()
        throws
    {
        let profile = LaunchProfile(
            name: "Highly Secret Work",
            argumentsText: "--api-key super-secret-argument",
            environmentText:
                "OPENAI_API_KEY=super-secret-environment",
            notes: "customer-acquisition-plan"
        )
        let application = ManagedApplication(
            displayName: "Private ChatGPT",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Users/private/Secret ChatGPT.app",
            preset: .codex,
            profiles: [profile]
        )
        let requestID = UUID()
        let entry = LaunchHistoryEntry(
            requestID: requestID,
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            applicationName: application.displayName,
            applicationBundleIdentifier:
                application.bundleIdentifier,
            profileName: profile.name,
            requestedAt: Date(timeIntervalSince1970: 100),
            startedAt: Date(timeIntervalSince1970: 102),
            endedAt: Date(timeIntervalSince1970: 162),
            state: .closed,
            process: ProcessStartIdentity(
                processIdentifier: 4_242,
                startTimeSeconds: 102,
                startTimeMicroseconds: 0
            ),
            observedProcessIdentifier: 4_242,
            terminationDisposition: .unexpected,
            updatedAt: Date(timeIntervalSince1970: 162)
        )
        let crash = ApplicationCrashReport(
            fileURL: URL(
                fileURLWithPath:
                    "/Users/private/Library/Logs/secret.ips"
            ),
            processIdentifier: 4_242,
            bundleIdentifier: "com.openai.codex",
            processName: "Private ChatGPT",
            launchedAt: entry.startedAt,
            capturedAt: entry.endedAt!,
            incidentIdentifier: "PRIVATE-INCIDENT-ID",
            exceptionType: "EXC_BAD_ACCESS",
            signal: "SIGSEGV",
            reason: "secret reason /Users/private"
        )
        let workaround = ManagedAppWorkaroundRecord(
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID,
            workaroundID: "secret-workaround-identifier",
            displayName: "Private operator title",
            definitionVersion: 1,
            configurationReference: "vendor.secret.path",
            state: .verified,
            updatedAt: Date(timeIntervalSince1970: 170),
            operatorNote: "super-secret-operator-note"
        )
        let service = SanitizedSupportBundleService()
        let bundle = service.makeBundle(
            application: application,
            history: [entry],
            crashReports: [requestID: crash],
            workaroundRecords: [workaround],
            settings: AppSettingsSnapshot(
                automaticCrashRecoveryEnabled: true,
                confirmBeforeLaunch: true,
                appearance: "system"
            ),
            persistenceHealth: .init(
                libraryHistoryAvailable: true,
                recoveryLedgerAvailable: true,
                workaroundStateAvailable: true
            ),
            generatedAt: Date(timeIntervalSince1970: 200),
            runtime: .init(
                parallaxVersion: "test",
                operatingSystem: "testOS",
                architecture: "arm64"
            )
        )
        let data = try service.encode(bundle)
        let text = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )

        XCTAssertEqual(bundle.activity.first?.profileIndex, 1)
        XCTAssertEqual(
            bundle.activity.first?.crashExceptionType,
            "EXC_BAD_ACCESS"
        )
        XCTAssertEqual(bundle.activity.first?.crashSignal, "SIGSEGV")
        XCTAssertEqual(bundle.activity.first?.durationSeconds, 60)
        XCTAssertEqual(
            bundle.workarounds.first?.identifier,
            "unrecognized"
        )
        for forbidden in [
            "Highly Secret Work",
            "Private ChatGPT",
            "/Users/private",
            "super-secret-argument",
            "super-secret-environment",
            "customer-acquisition-plan",
            "PRIVATE-INCIDENT-ID",
            "super-secret-operator-note",
            "vendor.secret.path",
            "secret-workaround-identifier",
            requestID.uuidString,
            application.id.uuidString,
            application.storageID.uuidString,
            profile.id.uuidString,
            profile.storageID.uuidString,
            "4242",
        ] {
            XCTAssertFalse(
                text.contains(forbidden),
                "Support bundle leaked \(forbidden)"
            )
        }
    }

    func testDiagnosticTokensRejectPathsAndControlCharacters()
        throws
    {
        let profile = LaunchProfile(name: "Space")
        let application = ManagedApplication(
            displayName: "App",
            appPath: "/Applications/App.app",
            profiles: [profile]
        )
        let requestID = UUID()
        let entry = LaunchHistoryEntry(
            requestID: requestID,
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            applicationName: application.displayName,
            applicationBundleIdentifier: nil,
            profileName: profile.name,
            requestedAt: Date(),
            startedAt: nil,
            endedAt: Date(),
            state: .failed,
            process: nil
        )
        let crash = ApplicationCrashReport(
            fileURL: URL(fileURLWithPath: "/tmp/private.ips"),
            processIdentifier: 1,
            bundleIdentifier: nil,
            processName: "App",
            launchedAt: nil,
            capturedAt: Date(),
            incidentIdentifier: nil,
            exceptionType: "EXC/../../secret\nvalue",
            signal: "SIG\u{0}SEGV",
            reason: nil
        )

        let bundle = SanitizedSupportBundleService().makeBundle(
            application: application,
            history: [entry],
            crashReports: [requestID: crash],
            workaroundRecords: [],
            settings: AppSettingsSnapshot(
                automaticCrashRecoveryEnabled: false,
                confirmBeforeLaunch: false,
                appearance: "system"
            ),
            persistenceHealth: .init(
                libraryHistoryAvailable: true,
                recoveryLedgerAvailable: true,
                workaroundStateAvailable: true
            )
        )

        XCTAssertEqual(
            bundle.activity.first?.crashExceptionType,
            "EXC....secretvalue"
        )
        XCTAssertEqual(
            bundle.activity.first?.crashSignal,
            "SIGSEGV"
        )
    }

    func testBundleCapsUnrecognizedWorkaroundMetadata() throws {
        let profile = LaunchProfile(name: "Space")
        let application = ManagedApplication(
            displayName: "App",
            appPath: "/Applications/App.app",
            profiles: [profile]
        )
        let records = (0..<250).map { index in
            ManagedAppWorkaroundRecord(
                applicationStorageID: application.storageID,
                profileStorageID: profile.storageID,
                workaroundID: "private-\(index)",
                displayName: "Private \(index)",
                definitionVersion: 1,
                configurationReference: "private.path",
                state: .verified,
                updatedAt: Date(),
                operatorNote: "private note"
            )
        }
        let service = SanitizedSupportBundleService()
        let bundle = service.makeBundle(
            application: application,
            history: [],
            crashReports: [:],
            workaroundRecords: records,
            settings: AppSettingsSnapshot(
                automaticCrashRecoveryEnabled: true,
                confirmBeforeLaunch: true,
                appearance: "system"
            ),
            persistenceHealth: .init(
                libraryHistoryAvailable: true,
                recoveryLedgerAvailable: true,
                workaroundStateAvailable: true
            )
        )

        XCTAssertEqual(bundle.workarounds.count, 200)
        XCTAssertTrue(
            bundle.workarounds.allSatisfy {
                $0.identifier == "unrecognized"
            }
        )
        XCTAssertLessThan(
            try service.encode(bundle).count,
            256 * 1_024
        )
    }
}
