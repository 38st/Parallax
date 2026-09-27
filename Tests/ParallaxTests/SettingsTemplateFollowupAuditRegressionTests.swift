import Darwin
import Foundation
import XCTest
@testable import Parallax

@MainActor
final class SettingsTemplateFollowupAuditRegressionTests: XCTestCase {
    private func historicalBytes(notes: String) throws -> Data {
        // The schema and keys written by 84b67f7, independent of today's model.
        let object: [String: Any] = [
            "schemaVersion": 1, "revision": 7, "defaultBaseStoragePath": "",
            "confirmBeforeLaunch": false, "automaticallyRecoverCrashedApps": true,
            "appearance": "system", "profileVisualIdentities": [],
            "profileTemplates": [
                ["id": "10000000-0000-4000-8000-000000000002", "name": "Trabajar",
                 "argumentsText": "", "environmentText": "", "notes": ""],
                ["id": "10000000-0000-4000-8000-000000000004", "name": "Tirar a la basura",
                 "argumentsText": "", "environmentText": "", "notes": notes],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func fixture(_ bytes: Data) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-template-compatibility-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Parallax/Settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let primary = directory.appendingPathComponent("settings.json")
        try bytes.write(to: primary)
        XCTAssertEqual(chmod(primary.path, 0o600), 0)
        return (root, primary)
    }

    private func bootstrap(_ root: URL) throws -> SettingsRuntime {
        let empty = SettingsLegacySnapshotClassifier.classify([:])
        let result = SettingsRuntimeBootstrapper(applicationSupportURL: root,
            legacyApplicationIdentifier: "test.template-compatibility", legacyCaptureOverride: { empty }).bootstrap()
        guard case .ready(let runtime) = result else { throw UnexpectedBootstrap(result) }
        return runtime
    }

    func testHistoricalSpanishTemplatesLoadAndCommitWithoutRewriting() throws {
        for notes in ["Un espacio desechable para sesiones temporales.", "Un espacio disponible para sesiones temporales."] {
            let bytes = try historicalBytes(notes: notes)
            let (root, primary) = try fixture(bytes)
            let runtime = try bootstrap(root)
            XCTAssertEqual(runtime.initialState.profileTemplates.map(\.name), ["Trabajar", "Tirar a la basura"])
            XCTAssertEqual(runtime.initialState.profileTemplates[1].notes, notes)
            XCTAssertEqual(try Data(contentsOf: primary), bytes, "Loading must not publish settings")
            XCTAssertEqual(try SettingsDocumentCodec().encode(runtime.initialSnapshot.document), bytes)
            let original = runtime.initialState
            guard case .committed(let state, let snapshot) = runtime.coordinator.applySynchronously(.setConfirmBeforeLaunch(true)) else {
                return XCTFail("Expected an unrelated setting to commit")
            }
            XCTAssertEqual(state.profileTemplates, original.profileTemplates)
            // Only the explicitly changed setting and revision may differ from the prior wire format.
            let expected = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\"confirmBeforeLaunch\":false", with: "\"confirmBeforeLaunch\":true")
                .replacingOccurrences(of: "\"revision\":7", with: "\"revision\":8")
            XCTAssertEqual(snapshot.originalBytes, Data(expected.utf8))
            XCTAssertEqual(try bootstrap(root).initialState, state)
            XCTAssertEqual(try Data(contentsOf: primary), snapshot.originalBytes)
        }
    }

    func testResetToDefaultsAndUndoPreserveHistoricalTemplatesOnDisk() throws {
        let bytes = try historicalBytes(notes: "Un espacio disponible para sesiones temporales.")
        let (root, primary) = try fixture(bytes)
        let runtime = try bootstrap(root)
        let settings = AppSettings(production: .ready(runtime))
        let previous = settings.profileTemplates
        XCTAssertNotEqual(previous, ProfileTemplate.defaults)
        XCTAssertTrue(settings.resetProfileTemplatesToDefaults())
        settings.flushForTermination()
        XCTAssertEqual(try bootstrap(root).initialState.profileTemplates, ProfileTemplate.defaults)
        XCTAssertTrue(settings.undoProfileTemplateReset())
        settings.flushForTermination()
        XCTAssertEqual(settings.profileTemplates, previous)
        XCTAssertEqual(try bootstrap(root).initialState.profileTemplates, previous)
        let expected = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"revision\":7", with: "\"revision\":9")
        XCTAssertEqual(try Data(contentsOf: primary), Data(expected.utf8))
    }

    func testRemovedRepairMarkerIsRejectedAsAnUnknownKey() throws {
        let bytes = try historicalBytes(notes: "Un espacio disponible para sesiones temporales.")
        for marker: Any in [true, false, "true"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["didRepairSpanishTemplateNames"] = marker
            let invalid = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard case .invalid(let failure) = SettingsDocumentCodec().decode(invalid) else {
                XCTFail("The removed marker must be an unknown key")
                continue
            }
            XCTAssertEqual(failure.issue, .unknownKey(path: "$.didRepairSpanishTemplateNames"))
            XCTAssertEqual(failure.originalBytes, invalid)
        }
    }
}

private struct UnexpectedBootstrap: Error {
    let result: SettingsRuntimeBootstrapResult
    init(_ result: SettingsRuntimeBootstrapResult) { self.result = result }
}
