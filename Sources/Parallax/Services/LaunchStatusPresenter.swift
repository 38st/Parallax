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
        openingDisposition: ProfileLaunchOpeningDisposition?,
        blockingProfileName: String? = nil,
        isolationActivityUnobserved: Bool = false
    ) -> SpaceLaunchStatusPresentation {
        if let openingDisposition {
            switch openingDisposition {
            case .waitingForEarlierOpen(let outcomeUnknown, _):
                let blockingSpace: String = blockingProfileName ?? applicationName
                return SpaceLaunchStatusPresentation(
                    message: outcomeUnknown
                        ? String(localized: "Waiting to open \(profileName): the open of \(blockingSpace) has an unknown outcome. Quit every instance of \(applicationName), then use Clear Stuck Launch Record for \(blockingSpace) to continue.")
                        : String(localized: "Waiting for an earlier open of \(applicationName) to finish before opening \(profileName)."),
                    listSummary: String(localized: "Waiting to open"),
                    tone: outcomeUnknown ? .warning : .neutral
                )
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
                ) + (isolationActivityUnobserved
                    ? "\n" + String(localized: "The app hasn't written to this space's data folder yet. It may be ignoring the isolation option.") : ""),
                listSummary: String(localized: "Running now"),
                tone: .success
            )
        case .mainHistoryActivated:
            return SpaceLaunchStatusPresentation(
                message: String(localized: "Brought the running Codex forward. It uses the main history."),
                listSummary: nil,
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
        detail: String,
        bundle: Bundle = PackagedRuntimeResources.bundle,
        locale: Locale = .current
    ) -> String {
        String(
            format: String(
                localized:
                    "%1$@ reported an error while opening %2$@, but Parallax cannot prove that no process started. Delivery of the space’s arguments, environment, and isolation is unconfirmed, so managed-data actions and further opens of this app remain blocked. Quit every %3$@ instance. Restart Parallax, then use Clear Stuck Launch Record for this space and confirm before opening again. %4$@",
                bundle: bundle,
                locale: locale
            ),
            locale: locale,
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

    static func confirmedCrashMessage(
        profileName: String
    ) -> String {
        String(
            localized:
                "\(profileName) crashed. Its data remains isolated; review Recent Activity or choose Open Again."
        )
    }
}
