import XCTest
@testable import Parallax

final class ProfileListPresentationTests: XCTestCase {
    func testRepeatedProfileContentKeepsImmutableRowAndLaunchIdentity() {
        let first = LaunchProfile(
            id: UUID(),
            storageID: UUID(),
            name: "Repeated",
            argumentsText: "--flag value --flag value"
        )
        let second = LaunchProfile(
            id: UUID(),
            storageID: UUID(),
            name: "Repeated",
            argumentsText: "--flag value --flag value"
        )

        let firstPresentation = ProfileListItemPresentation(profile: first)
        let secondPresentation = ProfileListItemPresentation(profile: second)

        XCTAssertNotEqual(firstPresentation.id, secondPresentation.id)
        XCTAssertNotEqual(
            firstPresentation.rowAccessibility.identifier,
            secondPresentation.rowAccessibility.identifier
        )
        XCTAssertNotEqual(
            firstPresentation.launchAccessibility.identifier,
            secondPresentation.launchAccessibility.identifier
        )
        XCTAssertEqual(
            firstPresentation.rowAccessibility.label,
            secondPresentation.rowAccessibility.label
        )
    }

    func testRowSelectionAndLaunchRemainSeparateAccessibilityActions() {
        let profile = LaunchProfile(
            name: "Work",
            argumentsText: "--profile work"
        )
        let presentation = ProfileListItemPresentation(profile: profile)

        XCTAssertEqual(
            presentation.rowAccessibility.role,
            .profileSelection
        )
        XCTAssertEqual(
            presentation.launchAccessibility.role,
            .launchAction
        )
        XCTAssertNotEqual(
            presentation.rowAccessibility.identifier,
            presentation.launchAccessibility.identifier
        )
        XCTAssertEqual(
            presentation.rowAccessibility.label,
            "Work, 2 arguments"
        )
        XCTAssertEqual(
            presentation.launchAccessibility.label,
            "Launch Work"
        )
        XCTAssertEqual(
            ProfileListAccessibilityContract.traversal(
                for: profile
            ).map(\.role),
            [.launchAction, .profileSelection]
        )
    }

    func testArgumentSummaryHandlesEmptySingularAndRepeatedValues() {
        let empty = ProfileListItemPresentation(
            profile: LaunchProfile(name: "Empty")
        )
        let singular = ProfileListItemPresentation(
            profile: LaunchProfile(
                name: "Single",
                argumentsText: "--incognito"
            )
        )
        let repeated = ProfileListItemPresentation(
            profile: LaunchProfile(
                name: "Repeated",
                argumentsText: "--flag --flag"
            )
        )

        XCTAssertEqual(empty.argumentSummary, "No launch arguments")
        XCTAssertEqual(singular.argumentSummary, "1 argument")
        XCTAssertEqual(repeated.argumentSummary, "2 arguments")
    }

    func testDuplicateTemplateNamesUseTemplateUUIDIdentity() {
        let first = ProfileTemplate(id: UUID(), name: "Work")
        let second = ProfileTemplate(id: UUID(), name: "Work")

        let presentations = [first, second].map {
            ProfileListTemplatePresentation(
                template: $0,
                duplicateNameCount: 2
            )
        }

        XCTAssertNotEqual(
            presentations[0].title,
            presentations[1].title
        )
        XCTAssertTrue(
            presentations.allSatisfy {
                $0.title.hasPrefix("Work — ")
            }
        )
        XCTAssertEqual(Set(presentations.map(\.id)).count, 2)
        XCTAssertEqual(
            Set(presentations.map(\.accessibilityIdentifier)).count,
            2
        )
    }

    func testCriticalActionIdentifiersAreStable() {
        let profileID = UUID()
        let templateID = UUID()

        XCTAssertEqual(
            ProfileListActionIdentifier.row(profileID),
            ProfileListActionIdentifier.row(profileID)
        )
        XCTAssertEqual(
            ProfileListActionIdentifier.launch(profileID),
            ProfileListActionIdentifier.launch(profileID)
        )
        XCTAssertEqual(
            ProfileListActionIdentifier.template(templateID),
            ProfileListActionIdentifier.template(templateID)
        )
        XCTAssertNotEqual(
            ProfileListActionIdentifier.remove(profileID),
            ProfileListActionIdentifier.duplicate(profileID)
        )
        XCTAssertFalse(ProfileListActionIdentifier.addProfile.isEmpty)
        XCTAssertFalse(ProfileListActionIdentifier.removeAndDeleteData.isEmpty)
        XCTAssertEqual(
            ProfileListAccessibilityContract.removalActions.map(\.role),
            [
                .destructiveAction,
                .destructiveAction,
                .destructiveAction,
                .cancelAction,
            ]
        )
        XCTAssertEqual(
            Set(
                ProfileListAccessibilityContract.removalActions
                    .map(\.identifier)
            ).count,
            ProfileListAccessibilityContract.removalActions.count
        )
        XCTAssertTrue(
            ProfileListAccessibilityContract.removalActions
                .allSatisfy {
                    !$0.label.isEmpty && !$0.hint.isEmpty
                }
        )
    }

}
