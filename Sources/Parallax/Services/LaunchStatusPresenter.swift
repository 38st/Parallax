import Foundation

enum SpaceLaunchStatusTone: Equatable, Sendable {
    case neutral
    case success
    case warning
    case failure
}

struct SpaceLaunchStatusPresentation: Equatable, Sendable {
    let message: String
    let listSummary: String?
    let tone: SpaceLaunchStatusTone

    var accessibilityLabel: String {
        let state = switch tone {
        case .neutral: String(localized: "Launch status")
        case .success: String(localized: "Success")
        case .warning: String(localized: "Warning")
        case .failure: String(localized: "Failed")
        }
        return String(
            format: String(localized: "%1$@: %2$@"),
            locale: .current,
            arguments: [state, message]
        )
    }
}

enum LaunchStatusPresenter {
    static func presentation(
        applicationName: String,
        profileName: String,
        state: LaunchRequestStatusState,
        openingDisposition: ProfileLaunchOpeningDisposition?
    ) -> SpaceLaunchStatusPresentation {
        if let openingDisposition {
            switch openingDisposition {
            case .provenanceIndeterminate:
                return SpaceLaunchStatusPresentation(
                    message: indeterminateProvenanceMessage(
                        applicationName: applicationName,
                        profileName: profileName
                    ),
                    listSummary: String(localized: "Open result unverified"),
                    tone: .warning
                )
            case .outcomeUnknownAfterError(let detail):
                return SpaceLaunchStatusPresentation(
                    message: unknownOpenOutcomeMessage(
                        applicationName: applicationName,
                        profileName: profileName,
                        detail: detail
                    ),
                    listSummary: String(localized: "Open result unknown"),
                    tone: .warning
                )
            case .pending, .preExistingSingletonRefused:
                break
            }
        }

        switch state {
        case .queuedForConfirmation:
            return SpaceLaunchStatusPresentation(
                message: String(localized: "Waiting to open"),
                listSummary: String(localized: "Waiting to open"),
                tone: .neutral
            )
        case .awaitingConfirmation:
            return SpaceLaunchStatusPresentation(
                message: String(localized: "Waiting for confirmation"),
                listSummary: String(localized: "Waiting for confirmation"),
                tone: .neutral
            )
        case .confirmed, .launching:
            return SpaceLaunchStatusPresentation(
                message: String(localized: "Opening \(profileName)…"),
                listSummary: String(localized: "Opening now"),
                tone: .neutral
            )
        case .running:
            return SpaceLaunchStatusPresentation(
                message: String(
                    localized:
                        "Opened \(profileName) in \(applicationName)."
                ),
                listSummary: String(localized: "Running now"),
                tone: .success
            )
        case .terminated:
            return SpaceLaunchStatusPresentation(
                message: String(localized: "\(profileName) closed"),
                listSummary: nil,
                tone: .neutral
            )
        case .cancelled:
            return SpaceLaunchStatusPresentation(
                message: String(localized: "Open cancelled"),
                listSummary: nil,
                tone: .neutral
            )
        case .failed(let message):
            return SpaceLaunchStatusPresentation(
                message: String(
                    localized:
                        "Couldn’t open \(profileName): \(message)"
                ),
                listSummary: String(localized: "Couldn’t open"),
                tone: .failure
            )
        case .invalidated(let reason):
            return SpaceLaunchStatusPresentation(
                message: reason.message,
                listSummary: String(localized: "Open request changed"),
                tone: .failure
            )
        case .rejected(let reason):
            return SpaceLaunchStatusPresentation(
                message: reason.message,
                listSummary: String(localized: "Open request refused"),
                tone: .failure
            )
        }
    }

    static func preExistingSingletonRefusalMessage(
        applicationName: String,
        profileName: String
    ) -> String {
        String(
            format: String(
                localized:
                    "%1$@ reused a pre-existing process. That existing instance may have been brought forward, but delivery of %2$@’s arguments, environment, and isolation is unconfirmed. Parallax did not mark the space as open. Quit every %3$@ instance, then try again."
            ),
            locale: .current,
            arguments: [applicationName, profileName, applicationName]
        )
    }

    static func indeterminateProvenanceMessage(
        applicationName: String,
        profileName: String
    ) -> String {
        String(
            format: String(
                localized:
                    "Parallax sent the open request for %1$@, but could not verify which %2$@ process received it. Delivery of the space’s arguments, environment, and isolation is unconfirmed. Managed-data actions remain blocked. Quit every %3$@ instance, then try again."
            ),
            locale: .current,
            arguments: [profileName, applicationName, applicationName]
        )
    }

    static func unknownOpenOutcomeMessage(
        applicationName: String,
        profileName: String,
        detail: String
    ) -> String {
        String(
            format: String(
                localized:
                    "%1$@ reported an error while opening %2$@, but Parallax cannot prove that no process started. Delivery of the space’s arguments, environment, and isolation is unconfirmed, so managed-data actions remain blocked. Quit every %3$@ instance before retrying. %4$@"
            ),
            locale: .current,
            arguments: [applicationName, profileName, applicationName, detail]
        )
    }

    static func indeterminateProcessEndedMessage(
        profileName: String
    ) -> String {
        String(
            format: String(
                localized:
                    "Parallax could not verify which process received the open request for %1$@. That process is no longer running, so it is safe to try again."
            ),
            locale: .current,
            arguments: [profileName]
        )
    }

    static func degradedTrackingMessage(
        profileName: String,
        detail: String
    ) -> String {
        String(
            localized:
                "\(profileName) opened, but Parallax could not enable durable process tracking. Managed-data actions remain blocked until the process closes. \(detail)"
        )
    }

    static func unexpectedTerminationMessage(
        profileName: String
    ) -> String {
        String(
            localized:
                "\(profileName) ended unexpectedly. Its data remains isolated; review Recent Activity for a crash report or choose Open Again."
        )
    }
}
