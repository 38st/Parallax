import AppKit
import XCTest
@testable import Parallax

/// No persistent preferences, processes, Trash, or CLI discovery in model tests.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}

@MainActor
func testHooks() -> AppHooks {
    var hooks = AppHooks()
    hooks.discoverRunningSpaces = { _ in [:] }
    hooks.runningInstances = { _ in [] }
    hooks.processArguments = { _ in (["Synthetic", "--user-data-dir=/nonexistent-parallax-test/UserData"], ["CLAUDE_CONFIG_DIR": "/nonexistent-parallax-test/Config"]) }
    hooks.isTerminated = { _ in false }
    hooks.activate = { _ in }
    hooks.terminate = { _ in XCTFail("Unexpected quit") }
    hooks.trash = { _ in XCTFail("Unexpected Trash call") }
    hooks.replyToTermination = { XCTFail("Unexpected termination reply") }
    hooks.locateCLI = { _ in nil }
    hooks.sleep = { _ in XCTFail("Inject a clock before waiting") }
    return hooks
}
