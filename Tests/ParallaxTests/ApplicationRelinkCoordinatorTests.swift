import Foundation
import XCTest
@testable import Parallax

final class ApplicationRelinkCoordinatorTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-ApplicationRelink-\(UUID().uuidString)",
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

    func testMovedApplicationFixtureProducesLosslessRelinkProposal() async throws {
        let fixture = try movedApplicationFixtureValues()
        let candidate = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            name: "Moved Fixture Browser.app",
            bundleIdentifier: fixture.bundleIdentifier
        )
        let profile = LaunchProfile(
            name: fixture.profileName,
            notes: fixture.profileNotes
        )
        let target = ManagedApplication(
            displayName: fixture.displayName,
            bundleIdentifier: fixture.bundleIdentifier,
            appPath: fixture.stalePath,
            preset: .chromium,
            baseStoragePath: fixture.baseStoragePath,
            profiles: [profile]
        )

        let assessment = await ApplicationRelinkCoordinator().assess(
            ApplicationRelinkRequest(
                requestID: UUID(),
                targetApplication: target,
                candidateURL: candidate.url,
                otherApplications: []
            )
        )
        let proposal = try XCTUnwrap(assessment.proposal)

        XCTAssertEqual(assessment.storedPathState, .missing)
        XCTAssertEqual(
            assessment.identityComparison,
            .sameBundleAtNewCanonicalPath
        )
        XCTAssertTrue(assessment.blockers.isEmpty)
        XCTAssertEqual(proposal.application.id, target.id)
        XCTAssertEqual(proposal.application.storageID, target.storageID)
        XCTAssertEqual(proposal.application.displayName, target.displayName)
        XCTAssertEqual(proposal.application.preset, target.preset)
        XCTAssertEqual(
            proposal.application.baseStoragePath,
            target.baseStoragePath
        )
        XCTAssertEqual(proposal.application.profiles, target.profiles)
        XCTAssertEqual(
            proposal.application.appPath,
            try LocalFileSystem().canonicalURL(for: candidate.url).path
        )
    }

    func testHealthyStoredApplicationMakesSameBundleCandidateASeparateInstallation() async throws {
        let stored = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            name: "Stored.app",
            bundleIdentifier: "com.example.browser"
        )
        let candidate = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            name: "Candidate.app",
            bundleIdentifier: "com.example.browser"
        )
        let target = application(
            path: stored.url.path,
            bundleIdentifier: stored.bundleIdentifier
        )

        let assessment = await ApplicationRelinkCoordinator().assess(
            ApplicationRelinkRequest(
                targetApplication: target,
                candidateURL: candidate.url,
                otherApplications: []
            )
        )

        XCTAssertNil(assessment.proposal)
        XCTAssertEqual(assessment.storedPathState, .available)
        XCTAssertEqual(
            assessment.identityComparison,
            .sameBundleDifferentInstallation
        )
        XCTAssertTrue(
            assessment.blockers.contains(
                .storedApplicationStillAvailable
            )
        )
    }

    func testDifferentBundleIsReportedAsDifferentApplication() async throws {
        let candidate = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            bundleIdentifier: "com.example.other"
        )
        let target = application(
            path: temporaryDirectory
                .appendingPathComponent("Missing.app").path,
            bundleIdentifier: "com.example.expected"
        )

        let assessment = await ApplicationRelinkCoordinator().assess(
            ApplicationRelinkRequest(
                targetApplication: target,
                candidateURL: candidate.url,
                otherApplications: []
            )
        )

        XCTAssertNil(assessment.proposal)
        XCTAssertEqual(
            assessment.identityComparison,
            .differentBundle(
                expected: "com.example.expected",
                actual: "com.example.other"
            )
        )
        XCTAssertTrue(
            assessment.blockers.contains(.candidateIsDifferentApplication)
        )
    }

    func testInvalidCandidateAppIsBlockedWithHealthDetails() async throws {
        let invalid = temporaryDirectory.appendingPathComponent("Invalid.app")
        try Data("not an application".utf8).write(to: invalid)
        let target = application(
            path: temporaryDirectory
                .appendingPathComponent("Missing.app").path,
            bundleIdentifier: "com.example.expected"
        )

        let assessment = await ApplicationRelinkCoordinator().assess(
            ApplicationRelinkRequest(
                targetApplication: target,
                candidateURL: invalid,
                otherApplications: []
            )
        )

        XCTAssertNil(assessment.proposal)
        XCTAssertTrue(
            assessment.blockers.contains(.candidateInvalid)
        )
        XCTAssertTrue(
            assessment.candidateHealth.issues.contains {
                $0.code == .applicationNotDirectory
            }
        )
    }

    func testCandidateCanonicalPathOwnedByAnotherRecordIsConflict() async throws {
        let candidate = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            bundleIdentifier: "com.example.browser"
        )
        let target = application(
            path: temporaryDirectory
                .appendingPathComponent("Missing.app").path,
            bundleIdentifier: candidate.bundleIdentifier
        )
        let other = application(
            path: candidate.url.path,
            bundleIdentifier: "com.example.unrelated"
        )

        let assessment = await ApplicationRelinkCoordinator().assess(
            ApplicationRelinkRequest(
                targetApplication: target,
                candidateURL: candidate.url,
                otherApplications: [other]
            )
        )

        XCTAssertNil(assessment.proposal)
        XCTAssertTrue(
            assessment.blockers.contains(.conflictsWithStoredApplication)
        )
        XCTAssertTrue(
            assessment.conflicts.contains {
                $0.applicationID == other.id
                    && $0.kind == .candidateCanonicalPathAlreadyStored
            }
        )
    }

    func testSameBundleOnAnotherStoredRecordIsConflictWithoutConflation() async throws {
        let candidate = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            name: "Candidate.app",
            bundleIdentifier: "com.example.shared"
        )
        let otherFixture = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            name: "Other.app",
            bundleIdentifier: "com.example.shared"
        )
        let target = application(
            path: temporaryDirectory
                .appendingPathComponent("Missing.app").path,
            bundleIdentifier: "com.example.shared"
        )
        let other = application(
            path: otherFixture.url.path,
            bundleIdentifier: "com.example.shared"
        )

        let assessment = await ApplicationRelinkCoordinator().assess(
            ApplicationRelinkRequest(
                targetApplication: target,
                candidateURL: candidate.url,
                otherApplications: [other]
            )
        )

        XCTAssertNil(assessment.proposal)
        XCTAssertTrue(
            assessment.conflicts.contains {
                $0.applicationID == other.id
                    && $0.kind
                        == .bundleIdentifierUsedByAnotherInstallation
            }
        )
    }

    func testMissingPersistedBundleIdentityCannotAuthorizeRelink() async throws {
        let candidate = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory
        )
        let target = application(
            path: temporaryDirectory
                .appendingPathComponent("Missing.app").path,
            bundleIdentifier: nil
        )

        let assessment = await ApplicationRelinkCoordinator().assess(
            ApplicationRelinkRequest(
                targetApplication: target,
                candidateURL: candidate.url,
                otherApplications: []
            )
        )

        XCTAssertNil(assessment.proposal)
        XCTAssertEqual(
            assessment.identityComparison,
            .targetBundleIdentityUnavailable(
                actual: candidate.bundleIdentifier
            )
        )
        XCTAssertTrue(
            assessment.blockers.contains(.targetBundleIdentityUnavailable)
        )
    }

    private func application(
        path: String,
        bundleIdentifier: String?
    ) -> ManagedApplication {
        ManagedApplication(
            displayName: "Fixture",
            bundleIdentifier: bundleIdentifier,
            appPath: path,
            profiles: [LaunchProfile(name: "Preserved")]
        )
    }

    private func movedApplicationFixtureValues() throws -> (
        displayName: String,
        bundleIdentifier: String,
        stalePath: String,
        baseStoragePath: String,
        profileName: String,
        profileNotes: String
    ) {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "moved-application-record.json",
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        )
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let applications = try XCTUnwrap(
            root["applications"] as? [[String: Any]]
        )
        let application = try XCTUnwrap(applications.first)
        let profiles = try XCTUnwrap(
            application["profiles"] as? [[String: Any]]
        )
        let profile = try XCTUnwrap(profiles.first)
        return (
            displayName: try XCTUnwrap(
                application["displayName"] as? String
            ),
            bundleIdentifier: try XCTUnwrap(
                application["bundleIdentifier"] as? String
            ),
            stalePath: try XCTUnwrap(application["appPath"] as? String),
            baseStoragePath: try XCTUnwrap(
                application["baseStoragePath"] as? String
            ),
            profileName: try XCTUnwrap(profile["name"] as? String),
            profileNotes: try XCTUnwrap(profile["notes"] as? String)
        )
    }
}
