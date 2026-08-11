import Foundation
import Observation

enum LaunchHistoryState: String, Codable, Sendable {
    case opening
    case running
    case closed
    case failed

    var isTerminal: Bool {
        switch self {
        case .closed, .failed:
            true
        case .opening, .running:
            false
        }
    }
}

struct LaunchHistoryEntry:
    Identifiable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    var id: UUID { requestID }

    let requestID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    var applicationName: String
    var applicationBundleIdentifier: String?
    var profileName: String
    let requestedAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var state: LaunchHistoryState
    var process: ProcessStartIdentity?
    var observedProcessIdentifier: pid_t? = nil
    var terminationDisposition:
        ManagedProcessTerminationDisposition? = nil
    var updatedAt: Date? = nil

    var processIdentifier: pid_t? {
        process?.processIdentifier ?? observedProcessIdentifier
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        let end = endedAt ?? Date()
        return max(0, end.timeIntervalSince(startedAt))
    }
}

enum LaunchHistoryStoreError: LocalizedError {
    case invalidDocument
    case unsupportedSchema(Int)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            String(localized: "Recent activity could not be read.")
        case .unsupportedSchema(let version):
            String(
                localized:
                    "Recent activity uses unsupported format \(version)."
            )
        case .persistence(let detail):
            String(
                localized:
                    "Recent activity could not be saved: \(detail)"
            )
        }
    }
}

@Observable
@MainActor
final class LaunchHistoryStore {
    private struct Document: Codable {
        let schemaVersion: Int
        let entries: [LaunchHistoryEntry]
    }

    private static let schemaVersion = 1
    private static let fileName = "launch-history.json"
    private static let lockFileName = ".launch-history.lock"
    private static let maximumDocumentBytes = 4 * 1_024 * 1_024

    private(set) var entries: [LaunchHistoryEntry]
    private(set) var persistenceErrorMessage: String?

    @ObservationIgnored
    private let fileStore: TrustedContainerFileStore?
    @ObservationIgnored
    private let maximumEntryCount: Int
    @ObservationIgnored
    private let processInspector: any ProcessIdentityInspecting
    @ObservationIgnored
    private let encoder: JSONEncoder
    @ObservationIgnored
    private let decoder: JSONDecoder

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
            if case .live(let process) = processInspector.inspect(
                processIdentifier: processIdentifier
            ) {
                entries[currentIndex].process = process
            }

        case .terminated(let processIdentifier):
            entries[currentIndex].state = .closed
            entries[currentIndex].observedProcessIdentifier =
                processIdentifier
            entries[currentIndex].endedAt = date
            entries[currentIndex].terminationDisposition =
                lifecycle.terminationDisposition
            if entries[currentIndex].process == nil,
               case .live(let process) = processInspector.inspect(
                   processIdentifier: processIdentifier
               )
            {
                entries[currentIndex].process = process
            }

        case .failed:
            entries[currentIndex].state = .failed
            entries[currentIndex].endedAt = date
        }

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
        entries.removeAll {
            $0.applicationID == application.id
                && $0.applicationStorageID == application.storageID
        }
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
                    do {
                        retainedResidual = try quarantineCorruptDocument()
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

    private func reconcileRunningEntries(at date: Date = Date()) {
        var changed = false
        for index in entries.indices
        where entries[index].state == .running {
            guard let process = entries[index].process else {
                entries[index].state = .closed
                entries[index].endedAt = date
                entries[index].terminationDisposition = .unexpected
                entries[index].updatedAt = date
                changed = true
                continue
            }

            switch processInspector.inspect(
                processIdentifier: process.processIdentifier
            ) {
            case .live(let current) where current == process:
                break
            case .ambiguous:
                break
            case .live, .dead:
                entries[index].state = .closed
                entries[index].endedAt = date
                entries[index].terminationDisposition = .unexpected
                entries[index].updatedAt = date
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
        guard let fileStore else { return }
        do {
            try fileStore.withExclusiveLock(
                named: Self.lockFileName
            ) {
                let persisted = try readPersistedEntries()
                entries = mergedEntries(
                    persisted,
                    entries
                )
                if let removingApplication {
                    entries.removeAll {
                        $0.applicationID == removingApplication.id
                            && $0.applicationStorageID
                                == removingApplication.storageID
                    }
                }
                sortAndTrim()
                let document = Document(
                    schemaVersion: Self.schemaVersion,
                    entries: entries
                )
                let data = try encoder.encode(document)
                try fileStore.replace(data, named: Self.fileName)
            }
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage =
                LaunchHistoryStoreError
                    .persistence(error.localizedDescription)
                    .localizedDescription
        }
    }

    private func readPersistedEntries() throws -> [LaunchHistoryEntry] {
        guard let fileStore else {
            return []
        }
        let data: Data
        switch try fileStore.read(
            named: Self.fileName,
            maximumBytes: Self.maximumDocumentBytes
        ) {
        case .missing:
            return []
        case .bytes(let bytes):
            data = bytes
        }
        guard !data.isEmpty else {
            throw LaunchHistoryStoreError.invalidDocument
        }
        let document = try decoder.decode(
            Document.self,
            from: data
        )
        guard document.schemaVersion == Self.schemaVersion else {
            throw LaunchHistoryStoreError.unsupportedSchema(
                document.schemaVersion
            )
        }
        return document.entries
    }

    private func mergedEntries(
        _ first: [LaunchHistoryEntry],
        _ second: [LaunchHistoryEntry]
    ) -> [LaunchHistoryEntry] {
        var merged: [UUID: LaunchHistoryEntry] = [:]
        for candidate in first + second {
            guard let existing = merged[candidate.requestID] else {
                merged[candidate.requestID] = candidate
                continue
            }
            if recency(of: candidate) >= recency(of: existing) {
                merged[candidate.requestID] = candidate
            }
        }
        return Array(merged.values)
    }

    private func recency(
        of entry: LaunchHistoryEntry
    ) -> Date {
        entry.updatedAt
            ?? entry.endedAt
            ?? entry.startedAt
            ?? entry.requestedAt
    }

    private func quarantineCorruptDocument()
        throws -> TrustedContainerFileResidual?
    {
        guard
            let fileStore
        else {
            return nil
        }
        return try fileStore.quarantine(
            named: Self.fileName,
            as: "launch-history.corrupt.retained.json"
        )
    }
}
