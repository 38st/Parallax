import XCTest
@testable import Parallax

final class AppPresetDetectionTests: XCTestCase {
    func testNonEdgeMicrosoftApplicationsAreNotClassifiedAsEdge() {
        let applications = [
            ("Microsoft Word", "com.microsoft.Word"),
            ("Microsoft Teams", "com.microsoft.teams2"),
            ("Microsoft Outlook", "com.microsoft.Outlook"),
        ]

        for (displayName, bundleIdentifier) in applications {
            XCTAssertEqual(
                AppPreset.detected(
                    displayName: displayName,
                    bundleIdentifier: bundleIdentifier
                ),
                .custom,
                "\(displayName) must not inherit Edge isolation behavior"
            )
        }
    }

    func testKnownEdgeChannelsAreDetectedByExactBundleIdentifier() {
        let bundleIdentifiers = [
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.Beta",
            "com.microsoft.edgemac.Dev",
        ]

        for bundleIdentifier in bundleIdentifiers {
            XCTAssertEqual(
                AppPreset.detected(
                    displayName: "Renamed Browser",
                    bundleIdentifier: bundleIdentifier
                ),
                .edge,
                "Expected Edge detection for \(bundleIdentifier)"
            )
        }
    }

    func testUnrelatedEdgeAndMicrosoftBundleSubstringsAreNotEdge() {
        let bundleIdentifiers = [
            "com.microsoft.something",
            "com.example.edge-browser",
            "com.microsoft.edgemac.Helper",
        ]

        for bundleIdentifier in bundleIdentifiers {
            XCTAssertEqual(
                AppPreset.detected(
                    displayName: "Neutral Application",
                    bundleIdentifier: bundleIdentifier
                ),
                .custom,
                "Bundle substring must not imply Edge: \(bundleIdentifier)"
            )
        }
    }

    func testRepresentativeChromiumElectronAndCodexApplications() {
        let applications: [(String, String, AppPreset)] = [
            ("Chromium", "org.chromium.Chromium", .chromium),
            ("Electron", "com.github.Electron", .electron),
            ("Codex", "com.openai.codex", .codex),
        ]

        for (displayName, bundleIdentifier, expected) in applications {
            XCTAssertEqual(
                AppPreset.detected(
                    displayName: displayName,
                    bundleIdentifier: bundleIdentifier
                ),
                expected
            )
        }
    }

    func testDisplayNameDetectionUsesWholeWordsForKnownEdgeNames() {
        XCTAssertEqual(
            AppPreset.detected(
                displayName: "Microsoft Edge Beta",
                bundleIdentifier: nil
            ),
            .edge
        )
        XCTAssertEqual(
            AppPreset.detected(
                displayName: "Knowledge Base",
                bundleIdentifier: nil
            ),
            .custom
        )
    }

    func testAutomaticDetectionDoesNotOverrideAnExplicitPreset() {
        let application = ManagedApplication(
            displayName: "Microsoft Edge",
            bundleIdentifier: "com.microsoft.edgemac",
            appPath: "/Applications/Microsoft Edge.app",
            preset: .custom
        )

        XCTAssertEqual(
            AppPreset.detected(
                displayName: application.displayName,
                bundleIdentifier: application.bundleIdentifier
            ),
            .edge
        )
        XCTAssertEqual(application.preset, .custom)
    }
}
