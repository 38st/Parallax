import Darwin
import Foundation

struct WorkspaceApplicationProcess: Equatable, Sendable {
    let identity: WorkspaceProcessIdentity

    var process: ProcessStartIdentity { identity.process }
    var bundleURL: URL { identity.application.bundleURL }
    var bundleIdentifier: String? {
        identity.application.bundleIdentifier
    }

    init(
        process: ProcessStartIdentity,
        bundleURL: URL,
        bundleIdentifier: String?
    ) {
        identity = WorkspaceProcessIdentity(
            process: process,
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier
            )
        )
    }

    init(identity: WorkspaceProcessIdentity) {
        self.identity = identity
    }
}

struct ManagedApplicationInstance:
    Identifiable,
    Equatable,
    Sendable
{
    let processIdentity: WorkspaceProcessIdentity
    let requestID: UUID?
    let profileID: UUID?
    let profileStorageID: UUID?
    let profileName: String?
    let controlPresentation: ProcessAuthorityPresentation

    init(
        processIdentity: WorkspaceProcessIdentity,
        requestID: UUID?,
        profileID: UUID?,
        profileStorageID: UUID?,
        profileName: String?,
        controlPresentation: ProcessAuthorityPresentation? = nil
    ) {
        self.processIdentity = processIdentity
        self.requestID = requestID
        self.profileID = profileID
        self.profileStorageID = profileStorageID
        self.profileName = profileName
        let hasTrackedAttribution = requestID != nil
            && profileID != nil
            && profileStorageID != nil
            && profileName != nil
        self.controlPresentation = controlPresentation
            ?? (hasTrackedAttribution
                ? .verificationUnavailable
                : .outsideParallax)
    }

    var id: WorkspaceProcessIdentity { processIdentity }
    var process: ProcessStartIdentity { processIdentity.process }

    var processIdentifier: pid_t {
        processIdentity.processIdentifier
    }

    var displayName: String {
        profileName ?? String(localized: "Other instance")
    }

    var hasTrackedAttribution: Bool {
        requestID != nil
            && profileID != nil
            && profileStorageID != nil
            && profileName != nil
    }

    var isTrackedSpace: Bool { hasTrackedAttribution }

    var isActionable: Bool { controlPresentation.isActionable }

    var actionPresentation: ProcessAuthorityActionPresentation {
        ProcessAuthorityActionPresentation(
            canShow: isActionable,
            canQuit: isActionable,
            help: controlPresentation.actionHelp
        )
    }

    func presenting(
        _ presentation: ProcessAuthorityPresentation
    ) -> ManagedApplicationInstance {
        ManagedApplicationInstance(
            processIdentity: processIdentity,
            requestID: requestID,
            profileID: profileID,
            profileStorageID: profileStorageID,
            profileName: profileName,
            controlPresentation: presentation
        )
    }
}

struct ProcessAuthorityActionPresentation: Equatable, Sendable {
    let canShow: Bool
    let canQuit: Bool
    let help: String
}

enum ProcessAuthorityPresentation: Equatable, Sendable {
    case verifiedParallaxInstance
    case outsideParallax
    case verificationUnavailable

    var isActionable: Bool {
        self == .verifiedParallaxInstance
    }

    var detailLabel: String {
        switch self {
        case .verifiedParallaxInstance:
            String(localized: "Parallax space")
        case .outsideParallax:
            String(localized: "Outside Parallax · Informational only")
        case .verificationUnavailable:
            String(localized: "Process verification unavailable")
        }
    }

    var actionHelp: String {
        switch self {
        case .verifiedParallaxInstance:
            String(localized: "This exact process can be controlled by Parallax.")
        case .outsideParallax:
            String(localized: "This process was not opened and tracked by Parallax, so Show and Quit are unavailable.")
        case .verificationUnavailable:
            String(localized: "Parallax could not verify the exact process identity, so Show and Quit are unavailable.")
        }
    }
}

enum WorkspaceProcessOperationResult: Error, Equatable, Sendable {
    case accepted
    case noLongerRunning
    case identityChanged
    case applicationChanged
    case verificationUnavailable
    case requestRejected
}

enum ApplicationInstanceControllerError: LocalizedError {
    case instanceNoLongerRunning
    case processIdentityChanged(pid_t)
    case applicationIdentityChanged(pid_t)
    case verificationUnavailable(pid_t)
    case applicationIdentityUnavailable
    case unmanagedInstance(pid_t)
    case activationRequestRejected(pid_t)
    case quitRequestRejected(pid_t)

    var errorDescription: String? {
        switch self {
        case .instanceNoLongerRunning:
            String(localized: "This app instance is no longer running.")
        case .processIdentityChanged(let processIdentifier):
            String(
                localized:
                    "Parallax did not send the request because process \(processIdentifier) changed."
            )
        case .applicationIdentityChanged(let processIdentifier):
            String(
                localized:
                    "Parallax did not send the request because process \(processIdentifier) no longer belongs to this app."
            )
        case .verificationUnavailable(let processIdentifier):
            String(
                localized:
                    "Parallax did not send the request because it could not verify process \(processIdentifier)."
            )
        case .applicationIdentityUnavailable:
            String(
                localized:
                    "Parallax cannot verify this app because its bundle identifier is missing. Relink the app before controlling its processes."
            )
        case .unmanagedInstance(let processIdentifier):
            String(
                localized:
                    "Parallax did not send the request because process \(processIdentifier) is not an exact instance opened and tracked by Parallax."
            )
        case .activationRequestRejected:
            String(
                localized:
                    "The verified app instance did not accept the request to come forward."
            )
        case .quitRequestRejected:
            String(
                localized:
                    "The verified app instance did not accept the quit request."
            )
        }
    }
}
