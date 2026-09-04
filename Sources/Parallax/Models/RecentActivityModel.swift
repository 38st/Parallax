import Foundation
import Observation

enum LaunchHistoryPresentationTone: Sendable, Equatable {
    case neutral
    case active
    case warning
    case failure
}

struct LaunchHistoryEntryPresentation: Sendable, Equatable {
    let statusLabel: String
    let timeLabel: String
    let durationLabel: String?
    let systemImageName: String
    let tone: LaunchHistoryPresentationTone

    init(
        entry: LaunchHistoryEntry,
        crashReport: ApplicationCrashReport? = nil,
        now: Date = Date(),
        locale: Locale = .current
    ) {
        if crashReport != nil {
            statusLabel = String(localized: "Crashed")
            systemImageName = "exclamationmark.triangle.fill"
            tone = .failure
        } else {
            switch entry.state {
            case .opening:
                statusLabel = String(localized: "Opening")
                systemImageName = "arrow.up.forward.app.fill"
                tone = .warning
            case .running:
                statusLabel = String(localized: "Running")
                systemImageName = "circle.fill"
                tone = .active
            case .closed:
                // NSWorkspace tells us that a process ended, but not whether
                // it quit normally or crashed. A matching macOS diagnostic
                // report above is the evidence that promotes this to
                // "Crashed"; Command-Q and other ordinary external quits are
                // presented as closed.
                statusLabel = String(localized: "Closed")
                systemImageName = "checkmark.circle"
                tone = .neutral
            case .failed:
                statusLabel = String(localized: "Couldn’t Open")
                systemImageName = "xmark.octagon.fill"
                tone = .failure
            }
        }

        let activityDate = entry.endedAt
            ?? entry.startedAt
            ?? entry.requestedAt
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .named
        timeLabel = relativeFormatter.localizedString(
            for: activityDate,
            relativeTo: now
        )

        if let startedAt = entry.startedAt {
            let end = entry.endedAt ?? now
            durationLabel = Self.durationLabel(
                max(0, end.timeIntervalSince(startedAt)),
                locale: locale
            )
        } else {
            durationLabel = nil
        }
    }

    private static func durationLabel(
        _ duration: TimeInterval,
        locale: Locale
    ) -> String {
        guard duration >= 60 else {
            return String(localized: "Less than a minute")
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: duration)
            ?? String(localized: "Less than a minute")
    }
}

struct RecentActivityLoadRequest: Hashable, Sendable {
    let applicationID: UUID
    let bundleIdentifier: String?
    let processName: String
    let entries: [LaunchHistoryEntry]
}

struct RecentActivityCrashReportSnapshot: Equatable, Sendable {
    let matched: [UUID: ApplicationCrashReport]
    let recent: [ApplicationCrashReport]
}

protocol RecentActivityCrashReportLoading: Sendable {
    func load(
        for request: RecentActivityLoadRequest
    ) async throws -> RecentActivityCrashReportSnapshot
}

actor RecentActivityCrashReportLoader:
    RecentActivityCrashReportLoading
{
    private let locator: ApplicationCrashReportLocator

    init(locator: ApplicationCrashReportLocator = .init()) {
        self.locator = locator
    }

    func load(
        for request: RecentActivityLoadRequest
    ) async throws -> RecentActivityCrashReportSnapshot {
        try Task.checkCancellation()
        let index = locator.index()
        try Task.checkCancellation()
        return RecentActivityCrashReportSnapshot(
            matched: index.reports(matching: request.entries),
            recent: index.recentReports(
                bundleIdentifier: request.bundleIdentifier,
                processName: request.processName
            )
        )
    }
}

@MainActor
@Observable
final class RecentActivityModel {
    private(set) var crashReports:
        [UUID: ApplicationCrashReport] = [:]
    private(set) var recentCrashReports:
        [ApplicationCrashReport] = []
    var expandedRequestIDs: Set<UUID> = []
    var expandedCrashReportURLs: Set<URL> = []
    var isConfirmingClear = false

    @ObservationIgnored
    private let loader: any RecentActivityCrashReportLoading
    @ObservationIgnored
    private var loadGeneration: UInt = 0
    @ObservationIgnored
    private var currentApplicationID: UUID?

    init(
        loader: any RecentActivityCrashReportLoading =
            RecentActivityCrashReportLoader()
    ) {
        self.loader = loader
    }

    func reload(for request: RecentActivityLoadRequest) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if currentApplicationID != request.applicationID {
            currentApplicationID = request.applicationID
            crashReports = [:]
            recentCrashReports = []
            expandedRequestIDs = []
            expandedCrashReportURLs = []
        }

        do {
            let snapshot = try await loader.load(for: request)
            try Task.checkCancellation()
            guard
                generation == loadGeneration,
                currentApplicationID == request.applicationID
            else { return }
            crashReports = snapshot.matched
            recentCrashReports = snapshot.recent
        } catch is CancellationError {
            return
        } catch {
            // The production loader treats unreadable reports as unavailable.
            // Retain the previous coherent snapshot for injected loader errors.
            return
        }
    }

    func clearParallaxActivity() {
        loadGeneration &+= 1
        crashReports = [:]
        expandedRequestIDs = []
    }

    func isEntryExpanded(_ requestID: UUID) -> Bool {
        expandedRequestIDs.contains(requestID)
    }

    func setEntryExpanded(_ isExpanded: Bool, requestID: UUID) {
        if isExpanded {
            expandedRequestIDs.insert(requestID)
        } else {
            expandedRequestIDs.remove(requestID)
        }
    }

    func isCrashReportExpanded(_ fileURL: URL) -> Bool {
        expandedCrashReportURLs.contains(fileURL)
    }

    func setCrashReportExpanded(_ isExpanded: Bool, fileURL: URL) {
        if isExpanded {
            expandedCrashReportURLs.insert(fileURL)
        } else {
            expandedCrashReportURLs.remove(fileURL)
        }
    }

    var unlinkedCrashReports: [ApplicationCrashReport] {
        let linkedURLs = Set(crashReports.values.map(\.fileURL))
        return recentCrashReports.filter {
            !linkedURLs.contains($0.fileURL)
        }
    }
}
