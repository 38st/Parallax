import Foundation
import Observation

@Observable
@MainActor
final class LaunchHistoryStore {
    struct Header: Decodable { let schemaVersion: Int }

    struct Document: Codable {
        let schemaVersion: Int
        let entries: [LaunchHistoryEntry]
    }

    static let schemaVersion = 1
    static let fileName = "launch-history.json"
    private static let lockFileName = ".launch-history.lock"
    static let maximumDocumentBytes = 4 * 1_024 * 1_024

    private(set) var entries: [LaunchHistoryEntry]
    private(set) var persistenceErrorMessage: String?

    @ObservationIgnored
    let fileStore: TrustedContainerFileStore?
    @ObservationIgnored
    private let maximumEntryCount: Int
    @ObservationIgnored
    private let processInspector: any ProcessIdentityInspecting
    @ObservationIgnored
    private let encoder: JSONEncoder
    @ObservationIgnored
    let decoder: JSONDecoder
    @ObservationIgnored
    private var pendingRequestIDs: Set<UUID> = []

    init(
        maximumEntryCount: Int = 200,
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector(),
        persistenceErrorMessage: String? = nil
    ) {
        fileStore = nil
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.processInspector = processInspector
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        entries = []
        self.persistenceErrorMessage = persistenceErrorMessage
    }

    init(
        applicationSupportURL: URL,
        maximumEntryCount: Int = 200,
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector(),
        fileManager: FileManager = .default
    ) throws {
        _ = fileManager
        let container = try TrustedParallaxContainer.establish(
            applicationSupportURL: applicationSupportURL
        )
        fileStore = TrustedContainerFileStore(container: container)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.processInspector = processInspector
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        entries = []
        persistenceErrorMessage = nil

        load()
        reconcileRunningEntries()
    }

    init(
        trustedContainer: TrustedParallaxContainer,
        maximumEntryCount: Int = 200,
        processInspector: any ProcessIdentityInspecting =
            SystemProcessIdentityInspector()
    ) throws {
        try trustedContainer.validate()
        fileStore = TrustedContainerFileStore(
            container: trustedContainer
        )
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.processInspector = processInspector
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        entries = []
        persistenceErrorMessage = nil
        load()
        reconcileRunningEntries()
    }

    func record(
        _ lifecycle: ProfileLaunchLifecycleSnapshot,
        application: ManagedApplication?,
        profile: LaunchProfile?,
        fallbackProfileName: String,
        at date: Date = Date()
    ) {
        let index = entries.firstIndex {
            $0.requestID == lifecycle.requestID
        }

        if index == nil {
            guard
                let application,
                let profile,
                lifecycle.matches(
                    application: application,
                    profile: profile
                )
            else {
                return
            }
            entries.append(
                LaunchHistoryEntry(
                    requestID: lifecycle.requestID,
                    applicationID: application.id,
                    applicationStorageID: application.storageID,
                    profileID: profile.id,
                    profileStorageID: profile.storageID,
                    applicationName: application.displayName,
                    applicationBundleIdentifier:
                        application.bundleIdentifier,
                    profileName: fallbackProfileName,
                    requestedAt: date,
                    startedAt: nil,
                    endedAt: nil,
                    state: .opening,
                    process: nil,
                    observedProcessIdentifier: nil,
                    terminationDisposition: nil,
                    updatedAt: date
                )
            )
        }

        guard let currentIndex = entries.firstIndex(where: {
            $0.requestID == lifecycle.requestID
        }) else {
            return
        }

        if let application {
            entries[currentIndex].applicationName =
                application.displayName
            entries[currentIndex].applicationBundleIdentifier =
                application.bundleIdentifier
        }
        if let profile {
            entries[currentIndex].profileName = profile.name
        }
        entries[currentIndex].updatedAt = date

        switch lifecycle.state {
        case .requested, .launching:
            entries[currentIndex].state = .opening

        case .running(let processIdentifier),
             .runningDegraded(let processIdentifier, _),
             .terminating(let processIdentifier):
            entries[currentIndex].state = .running
            entries[currentIndex].observedProcessIdentifier =
                processIdentifier
            entries[currentIndex].startedAt =
                entries[currentIndex].startedAt ?? date
            if let process = lifecycle.processIdentity?.process {
                entries[currentIndex].process = process
            } else if case .live(let process) = processInspector.inspect(
                processIdentifier: processIdentifier
            ) {
                entries[currentIndex].process = process
            }
            // A terminating lifecycle is only delivered after a caller
            // requested the quit. Remember that so an entry reconciled
            // without a lifecycle (for example after Parallax restarts) is
            // not reported as ending unexpectedly. A restored running
            // lifecycle means the request was withdrawn.
            if case .terminating = lifecycle.state {
                entries[currentIndex].terminationDisposition = .expected
            } else {
                entries[currentIndex].terminationDisposition = nil
            }

        case .terminated(let processIdentifier):
            entries[currentIndex].state = .closed
            entries[currentIndex].observedProcessIdentifier =
                processIdentifier
            entries[currentIndex].endedAt = date
            entries[currentIndex].terminationDisposition =
                lifecycle.terminationDisposition
            if let process = lifecycle.processIdentity?.process {
                entries[currentIndex].process = process
            }

        case .failed:
            entries[currentIndex].state = .failed
            entries[currentIndex].endedAt = date
        }

        pendingRequestIDs.insert(lifecycle.requestID)
        sortAndTrim()
        persist()
    }

    func entries(for application: ManagedApplication) -> [LaunchHistoryEntry] {
        entries.filter {
            $0.applicationID == application.id
                && $0.applicationStorageID == application.storageID
        }
    }

    func refreshFromDisk() {
        guard fileStore != nil else { return }
        load()
        reconcileRunningEntries()
    }

    func clearHistory(for application: ManagedApplication) {
        persist(
            removingApplication: (
                id: application.id,
                storageID: application.storageID
            )
        )
    }

    private func load() {
        guard let fileStore else { return }
        var retainedResidual: TrustedContainerFileResidual?
        var quarantineErrorMessage: String?
        do {
            try fileStore.withExclusiveLock(
                named: Self.lockFileName
            ) {
                do {
                    entries = try readPersistedEntries()
                } catch {
                    if let failure = error as? LaunchHistoryStoreError,
                        case .unsupportedSchema = failure
                    {
                        throw error
                    }
                    do {
                        retainedResidual = try quarantineCorruptDocument()
                        if retainedResidual != nil {
                            try fileStore.replace(
                                encoder.encode(
                                    Document(schemaVersion: Self.schemaVersion, entries: [])),
                                named: Self.fileName
                            )
                            retainedResidual = nil
                        }
                    } catch {
                        quarantineErrorMessage = error.localizedDescription
                    }
                    throw error
                }
            }
            sortAndTrim()
        } catch {
            entries = []
            persistenceErrorMessage = [
                error.localizedDescription,
                retainedResidual?.cleanupDescription,
                quarantineErrorMessage
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }
    }

    /// How long a requested quit may take before a still-running process is
    /// treated as having declined it.
    nonisolated static let terminationRequestGracePeriod: TimeInterval = 120

    private func reconcileRunningEntries(at date: Date = Date()) {
        var changed = false
        for index in entries.indices
        where entries[index].state == .running {
            guard let process = entries[index].process else {
                entries[index].state = .closed
                entries[index].endedAt = date
                entries[index].terminationDisposition =
                    entries[index].terminationDisposition ?? .unexpected
                entries[index].updatedAt = date
                pendingRequestIDs.insert(entries[index].requestID)
                changed = true
                continue
            }

            switch processInspector.inspect(
                processIdentifier: process.processIdentifier
            ) {
            case .live(let current) where current == process:
                // A quit that was requested but never happened (the app
                // showed a "Save changes?" sheet and the user cancelled)
                // leaves the expected-exit marker behind. Withdraw it once
                // the process has clearly outlived the request so a later
                // crash is still reported as unexpected.
                if entries[index].terminationDisposition == .expected,
                    let updatedAt = entries[index].updatedAt,
                    date.timeIntervalSince(updatedAt)
                        > Self.terminationRequestGracePeriod
                {
                    entries[index].terminationDisposition = nil
                    entries[index].updatedAt = date
                    pendingRequestIDs.insert(entries[index].requestID)
                    changed = true
                }
            case .ambiguous:
                break
            case .live, .dead:
                entries[index].state = .closed
                entries[index].endedAt = date
                entries[index].terminationDisposition =
                    entries[index].terminationDisposition ?? .unexpected
                entries[index].updatedAt = date
                pendingRequestIDs.insert(entries[index].requestID)
                changed = true
            }
        }
        if changed {
            persist()
        }
    }

    private func sortAndTrim() {
        entries.sort {
            if $0.requestedAt != $1.requestedAt {
                return $0.requestedAt > $1.requestedAt
            }
            return $0.requestID.uuidString < $1.requestID.uuidString
        }
        if entries.count > maximumEntryCount {
            entries.removeLast(entries.count - maximumEntryCount)
        }
    }

    private func persist(
        removingApplication:
            (id: UUID, storageID: UUID)? = nil
    ) {
        guard let fileStore else {
            if let removingApplication {
                entries.removeAll {
                    $0.applicationID == removingApplication.id
                        && $0.applicationStorageID == removingApplication.storageID
                }
            }
            return
        }
        do {
            try fileStore.withExclusiveLock(
                named: Self.lockFileName
            ) {
                let persisted = try readPersistedEntries()
                entries = mergedEntries(
                    persisted,
                    entries.filter { pendingRequestIDs.contains($0.requestID) }
                )
                if let removingApplication {
                    entries.removeAll {
                        $0.applicationID == removingApplication.id
                            && $0.applicationStorageID == removingApplication.storageID
                    }
                }
                sortAndTrim()
                let document = Document(
                    schemaVersion: Self.schemaVersion,
                    entries: entries
                )
                let data = try encoder.encode(document)
                try fileStore.replace(data, named: Self.fileName)
                pendingRequestIDs.removeAll()
            }
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage =
                LaunchHistoryStoreError
                    .persistence(error.localizedDescription)
                    .localizedDescription
        }
    }
}
