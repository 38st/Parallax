import Foundation
import XCTest
@testable import Parallax

final class IsolationCapabilitiesAuditRegressionTests: XCTestCase {
    private var english: Bundle {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Parallax/Resources/en.lproj")
        return Bundle(url: url) ?? .main
    }
    func testReadsBooleanMultipleInstancePolicyAndHandlesMissingOrInvalidPlist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try ValidApplicationBundleFixture.create(in: root)
        let plist = app.url.appendingPathComponent("Contents/Info.plist")
        func write(_ value: Any?) throws {
            let dictionary = value.map { ["LSMultipleInstancesProhibited": $0] } ?? [:]
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).write(to: plist)
        }
        try write(true)
        XCTAssertEqual(ApplicationIsolationCapabilities.readPolicy(at: app.url), .prohibited)
        try write(false)
        XCTAssertEqual(ApplicationIsolationCapabilities.readPolicy(at: app.url), .notProhibited)
        try write(nil)
        XCTAssertEqual(ApplicationIsolationCapabilities.readPolicy(at: app.url), .notProhibited)
        try write("false")
        XCTAssertEqual(ApplicationIsolationCapabilities.readPolicy(at: app.url), .unknown)
        try Data("corrupt".utf8).write(to: plist)
        XCTAssertEqual(ApplicationIsolationCapabilities.readPolicy(at: app.url), .unknown)
        try FileManager.default.removeItem(at: plist)
        XCTAssertEqual(ApplicationIsolationCapabilities.readPolicy(at: app.url), .unknown)
    }

    func testEveryPresetDescribesItsMechanismWithoutPromisingOSIsolation() throws {
        let mechanisms: [AppPreset: [String]] = [
            .automatic: ["options"], .custom: ["options"], .codex: ["CODEX_HOME", "--user-data-dir"],
            .claude: ["CLAUDE_CONFIG_DIR", "--user-data-dir"], .chrome: ["--user-data-dir"],
            .brave: ["--user-data-dir"], .edge: ["--user-data-dir"], .chromium: ["--user-data-dir"],
            .electron: ["--user-data-dir"]
        ]
        for preset in AppPreset.allCases {
            let summary = ApplicationIsolationCapabilities(preset: preset, multipleInstancePolicy: .notProhibited)
            let text = summary.dataSummary(bundle: english).lowercased()
            for promise in ["security boundary", "sandboxed", "guarantees isolation", "fully isolated", "guaranteed"] {
                XCTAssertFalse(text.contains(promise), text)
            }
            if preset == .electron { XCTAssertFalse(text.contains("browser data")) }
            if preset == .firefox || preset == .visualStudioCode {
                XCTAssertTrue(text.contains("applying the recommended settings"))
            }
        }
        for (preset, expected) in mechanisms {
            let summary = ApplicationIsolationCapabilities(preset: preset, multipleInstancePolicy: .notProhibited)
            for mechanism in expected { XCTAssertTrue(summary.dataSummary(bundle: english).contains(mechanism), summary.dataSummary(bundle: english)) }
            XCTAssertFalse(summary.instanceSummary(bundle: english).isEmpty)
        }
        for name in ["firefox", "visualStudioCode"] {
            let preset = try XCTUnwrap(AppPreset(rawValue: name))
            let summary = ApplicationIsolationCapabilities(preset: preset, multipleInstancePolicy: .notProhibited)
            XCTAssertTrue(summary.dataSummary(bundle: english).contains(name == "firefox" ? "-profile" : "--extensions-dir"))
        }
    }

    func testCapabilityPolicyLoadingAndReuseNeverShowStaleResults() {
        var state = ApplicationCapabilityPolicyState()
        XCTAssertNil(state.policy(for: "/one.app"))
        state.record(.prohibited, for: "/one.app")
        XCTAssertEqual(state.policy(for: "/one.app"), .prohibited)
        XCTAssertNil(state.policy(for: "/two.app"))
        state.record(.notProhibited, for: "/two.app")
        XCTAssertEqual(state.policy(for: "/two.app"), .notProhibited)
        XCTAssertNil(state.policy(for: "/one.app"))
    }

    func testSpanishSummariesAreLocalizedForEveryPreset() throws {
        let spanish = try XCTUnwrap(Bundle(url: english.bundleURL.deletingLastPathComponent().appendingPathComponent("es.lproj")))
        for preset in AppPreset.allCases {
            let summary = ApplicationIsolationCapabilities(preset: preset, multipleInstancePolicy: .notProhibited)
            XCTAssertNotEqual(summary.dataSummary(bundle: english), summary.dataSummary(bundle: spanish))
            XCTAssertNotEqual(summary.instanceSummary(bundle: english), summary.instanceSummary(bundle: spanish))
        }
    }

    func testPlistProhibitionOverridesPresetConcurrencyAndUnknownStaysUnverified() {
        for preset in AppPreset.allCases {
            let prohibited = ApplicationIsolationCapabilities(preset: preset, multipleInstancePolicy: .prohibited)
            XCTAssertTrue(prohibited.instanceSummary(bundle: english).contains("prohibits multiple instances"))
            let unknown = ApplicationIsolationCapabilities(preset: preset, multipleInstancePolicy: .unknown)
            XCTAssertTrue(unknown.instanceSummary(bundle: english).contains("unverified"))
        }
    }
}
