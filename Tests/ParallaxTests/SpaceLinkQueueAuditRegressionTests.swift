import Foundation
import XCTest
@testable import Parallax

final class SpaceLinkQueueAuditRegressionTests: XCTestCase {
    @MainActor
    func testPendingDuplicatesDoNotReloadAndQueueRejectsOverflowWithOneMessage() throws {
        let queue = SpaceLinkPromptQueue(capacity: 2)
        var loads = 0
        let first = request()
        let second = request()
        let load: (URL) throws -> SpaceLinkRequest = { url in
            loads += 1
            return try SpaceLink.profileID(from: url) == first.profile.id ? first : second
        }
        let firstURL = try XCTUnwrap(SpaceLink.url(profileID: first.profile.id))
        queue.receive(firstURL, load: load)
        queue.receive(firstURL, load: load)
        queue.receive(try XCTUnwrap(SpaceLink.url(profileID: second.profile.id)), load: load)
        for _ in 0..<20 {
            queue.receive(try XCTUnwrap(SpaceLink.url(profileID: UUID())), load: load)
        }
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(queue.prompts.count, 2)
        queue.cancel(try XCTUnwrap(queue.current))
        XCTAssertEqual(queue.prompts.count, 2)
        queue.cancel(try XCTUnwrap(queue.current))
        let overflow = try XCTUnwrap(queue.current)
        XCTAssertNil(overflow.request)
        XCTAssertEqual(overflow.errorMessage,
            String(localized: "Too many space links are waiting. Additional links were ignored."))
        queue.cancel(overflow)
        XCTAssertTrue(queue.prompts.isEmpty)
    }

    @MainActor
    func testMalformedLinksNeverReloadAndUnknownSpaceIsQueuedOnce() throws {
        let queue = SpaceLinkPromptQueue()
        queue.receive(try XCTUnwrap(URL(string: "parallax://delete?space=bad"))) { _ in
            XCTFail("Malformed link reloaded the library")
            return self.request()
        }
        XCTAssertEqual(queue.current?.errorMessage, SpaceLinkError.invalid.localizedDescription)
        queue.cancel(try XCTUnwrap(queue.current))
        let unknown = try XCTUnwrap(SpaceLink.url(profileID: UUID()))
        var loads = 0
        for _ in 0..<3 {
            queue.receive(unknown) { _ in
                loads += 1
                throw SpaceLinkError.unknownSpace
            }
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(queue.prompts.count, 1)
        XCTAssertEqual(queue.current?.errorMessage, SpaceLinkError.unknownSpace.localizedDescription)
    }

    @MainActor
    func testConfirmUsesDisplayedPromptEvenWhenBindingDismissesBeforeAction() throws {
        let queue = SpaceLinkPromptQueue()
        let first = request()
        let second = request()
        queue.receive(try XCTUnwrap(SpaceLink.url(profileID: first.profile.id))) { _ in first }
        let displayed = try XCTUnwrap(queue.current)
        queue.receive(try XCTUnwrap(SpaceLink.url(profileID: second.profile.id))) { _ in second }
        queue.dismiss(displayed)
        XCTAssertEqual(queue.current?.request?.profile.id, second.profile.id)
        var confirmed: [UUID] = []
        queue.confirm(displayed) { confirmed.append($0.profile.id) }
        queue.confirm(displayed) { confirmed.append($0.profile.id) }
        XCTAssertEqual(confirmed, [first.profile.id])
        XCTAssertEqual(queue.current?.request?.profile.id, second.profile.id)
    }

    @MainActor
    func testCanceledAndUnpresentedPromptsCannotBeConfirmed() throws {
        let queue = SpaceLinkPromptQueue()
        for _ in 0..<2 {
            let request = request()
            queue.receive(try XCTUnwrap(SpaceLink.url(profileID: request.profile.id))) { _ in request }
        }
        let displayed = try XCTUnwrap(queue.current)
        let waiting = try XCTUnwrap(queue.prompts.last)
        queue.confirm(waiting) { _ in XCTFail("An unpresented link was confirmed") }
        queue.cancel(displayed)
        queue.confirm(displayed) { _ in XCTFail("A canceled link was confirmed") }
        XCTAssertEqual(queue.current?.id, waiting.id)
    }

    private func request() -> SpaceLinkRequest {
        let profile = LaunchProfile(name: "Work")
        let application = ManagedApplication(displayName: "Fixture", bundleIdentifier: "example.fixture",
            appPath: "/synthetic/Fixture.app", baseStoragePath: "/synthetic/Storage", profiles: [profile])
        return SpaceLinkRequest(application: application, profile: profile, configuredBaseRoot: "/synthetic/Storage",
            fingerprint: LaunchConfigurationFingerprint(digest: "fixture"))
    }
}
