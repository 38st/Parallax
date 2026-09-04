import XCTest
@testable import Parallax

final class LaunchStatusPresenterTests: XCTestCase {
    func testLaunchRequestStatePresentationMatrix() {
        struct Scenario {
            let state: LaunchRequestStatusState
            let message: String
            let listSummary: String?
            let tone: SpaceLaunchStatusTone
        }

        let scenarios: [Scenario] = [
            Scenario(
                state: .queuedForConfirmation,
                message: "Waiting to open",
                listSummary: "Waiting to open",
                tone: .neutral
            ),
            Scenario(
                state: .awaitingConfirmation,
                message: "Waiting for confirmation",
                listSummary: "Waiting for confirmation",
                tone: .neutral
            ),
            Scenario(
                state: .confirmed,
                message: "Opening Work…",
                listSummary: "Opening now",
                tone: .neutral
            ),
            Scenario(
                state: .launching,
                message: "Opening Work…",
                listSummary: "Opening now",
                tone: .neutral
            ),
            Scenario(
                state: .running,
                message: "Opened Work in Browser.",
                listSummary: "Running now",
                tone: .success
            ),
            Scenario(
                state: .terminated,
                message: "Work closed",
                listSummary: nil,
                tone: .neutral
            ),
            Scenario(
                state: .cancelled,
                message: "Open cancelled",
                listSummary: nil,
                tone: .neutral
            ),
            Scenario(
                state: .failed("Launch Services unavailable"),
                message:
                    "Couldn’t open Work: Launch Services unavailable",
                listSummary: "Couldn’t open",
                tone: .failure
            ),
            Scenario(
                state: .invalidated(
                    .profileRemoved(
                        profileID: UUID(
                            uuidString:
                                "00000000-0000-4000-8000-000000000001"
                        )!,
                        profileName: "Work"
                    )
                ),
                message:
                    "The “Work” profile was removed before launch confirmation. Choose a profile and try again.",
                listSummary: "Open request changed",
                tone: .failure
            ),
            Scenario(
                state: .rejected(
                    .duplicateRequestID(
                        UUID(
                            uuidString:
                                "00000000-0000-4000-8000-000000000002"
                        )!
                    )
                ),
                message: "This launch request has already been submitted.",
                listSummary: "Open request refused",
                tone: .failure
            ),
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                LaunchStatusPresenter.presentation(
                    applicationName: "Browser",
                    profileName: "Work",
                    state: scenario.state,
                    openingDisposition: nil
                ),
                SpaceLaunchStatusPresentation(
                    message: scenario.message,
                    listSummary: scenario.listSummary,
                    tone: scenario.tone
                )
            )
        }
    }

    func testUnverifiedOpeningDispositionOverridesRunningStatus() {
        let presentation = LaunchStatusPresenter.presentation(
            applicationName: "Browser",
            profileName: "Work",
            state: .running,
            openingDisposition: .provenanceIndeterminate(
                processIdentifier: 42,
                reason: .unverifiableIdentity
            )
        )

        XCTAssertEqual(presentation.listSummary, "Open result unverified")
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertTrue(
            presentation.message.contains(
                "could not verify which Browser process received it"
            )
        )
    }

    func testUnknownOpeningOutcomePreservesDetailAndOverridesFailure() {
        let presentation = LaunchStatusPresenter.presentation(
            applicationName: "Browser",
            profileName: "Work",
            state: .failed("ignored status detail"),
            openingDisposition: .outcomeUnknownAfterError(
                message: "Launch Services timed out"
            )
        )

        XCTAssertEqual(presentation.listSummary, "Open result unknown")
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertTrue(
            presentation.message.hasSuffix("Launch Services timed out")
        )
    }

    func testAccessibilityLabelIncludesToneAndMessage() {
        let presentation = SpaceLaunchStatusPresentation(
            message: "Opening Work…",
            listSummary: "Opening now",
            tone: .neutral
        )

        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Launch status: Opening Work…"
        )
    }

    func testConfirmedCrashMessageStatesThatTheCrashWasVerified() {
        XCTAssertEqual(
            LaunchStatusPresenter.confirmedCrashMessage(
                profileName: "Work"
            ),
            "Work crashed. Its data remains isolated; review Recent Activity or choose Open Again."
        )
    }
}
