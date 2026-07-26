import Foundation
@testable import Parallax

enum MigrationTestSupportError: Error {
    case missingFixture(String)
    case invalidFixtureTopLevel(String)
    case missingLegacyProfile
}

struct MigrationFixtureWorkspace {
    let rootURL: URL
    let applicationSupportURL: URL
    let managedRootURL: URL
    let externalRootURL: URL

    var parallaxURL: URL {
        applicationSupportURL.appendingPathComponent("Parallax", isDirectory: true)
    }

    var libraryURL: URL {
        parallaxURL.appendingPathComponent("library.json", isDirectory: false)
    }

    init(testName: String = #function) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Parallax-STOR-002-\(testName)-\(UUID().uuidString)",
            isDirectory: true
        )
        applicationSupportURL = rootURL.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        managedRootURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        externalRootURL = rootURL.appendingPathComponent("External", isDirectory: true)

        try FileManager.default.createDirectory(
            at: parallaxURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalRootURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @discardableResult
    func installFixture(
        named name: String,
        mutate: ((inout Any) throws -> Void)? = nil
    ) throws -> Data {
        guard let fixtureURL = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw MigrationTestSupportError.missingFixture(name)
        }

        let fixtureData = try Data(contentsOf: fixtureURL)
        var object = try JSONSerialization.jsonObject(with: fixtureData)
        object = rebase(object)
        try mutate?(&object)
        let rebasedData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try rebasedData.write(to: libraryURL)
        return rebasedData
    }

    func installBytes(_ data: Data) throws {
        try data.write(to: libraryURL)
    }

    /// Reproduces the v1 folder algorithm only for test fixture materialization.
    /// Unsafe legacy components are deliberately not appended to a URL here.
    @discardableResult
    func materializeLegacySources(
        excludingProfileIDs excludedProfileIDs: Set<UUID> = []
    ) throws -> [URL: Data] {
        let data = try Data(contentsOf: libraryURL)
        guard case let .migrationRequired(legacy) = try LibraryPersistence.decodeLibrary(from: data) else {
            return [:]
        }

        var sentinels: [URL: Data] = [:]
        for application in legacy.applications {
            let applicationFolder = Self.legacySanitizedComponent(application.displayName)
            for profile in application.profiles where !excludedProfileIDs.contains(profile.id) {
                let rawComponent = profile.storageName
                    ?? Self.legacySanitizedComponent(profile.name)
                guard Self.isSafeFixtureComponent(rawComponent) else { continue }

                let sourceURL = managedRootURL
                    .appendingPathComponent(applicationFolder, isDirectory: true)
                    .appendingPathComponent(rawComponent, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: sourceURL,
                    withIntermediateDirectories: true
                )
                let sentinelURL = sourceURL.appendingPathComponent(
                    "fixture-\(profile.id.uuidString.lowercased()).sentinel",
                    isDirectory: false
                )
                let sentinel = Data(
                    "legacy:\(application.id.uuidString):\(profile.id.uuidString)".utf8
                )
                try sentinel.write(to: sentinelURL)
                sentinels[sentinelURL] = sentinel
            }
        }
        return sentinels
    }

    @discardableResult
    func materializeExternalIsolationSentinels() throws -> [URL: Data] {
        let codexHome = externalRootURL.appendingPathComponent(
            "CodexHome",
            isDirectory: true
        )
        let userData = externalRootURL.appendingPathComponent(
            "UserData",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: userData,
            withIntermediateDirectories: true
        )

        let codexSentinel = codexHome.appendingPathComponent("account.sentinel")
        let browserSentinel = userData.appendingPathComponent("browser.sentinel")
        let values = [
            codexSentinel: Data("external-codex-account".utf8),
            browserSentinel: Data("external-browser-account".utf8)
        ]
        for (url, data) in values {
            try data.write(to: url)
        }
        return values
    }

    func migrationDirectory(migrationID: UUID) -> URL {
        parallaxURL
            .appendingPathComponent("Migrations", isDirectory: true)
            .appendingPathComponent(
                migrationID.uuidString.lowercased(),
                isDirectory: true
            )
    }

    func assertableStateURLs(migrationID: UUID) -> (
        directory: URL,
        backup: URL,
        journal: URL,
        receipt: URL,
        pendingReceipt: URL,
        staging: URL
    ) {
        let directory = migrationDirectory(migrationID: migrationID)
        return (
            directory,
            directory.appendingPathComponent("library-v1.backup.json"),
            directory.appendingPathComponent("journal.json"),
            directory.appendingPathComponent("receipt.json"),
            directory.appendingPathComponent("receipt.pending.json"),
            managedRootURL
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Transactions", isDirectory: true)
                .appendingPathComponent(
                    migrationID.uuidString.lowercased(),
                    isDirectory: true
                )
        )
    }

    func allRegularFileBytes(under root: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return [:]
        }

        var result: [String: Data] = [:]
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                continue
            }
            if values.isRegularFile == true {
                result[item.path.replacingOccurrences(of: root.path, with: "")] =
                    try Data(contentsOf: item)
            }
        }
        return result
    }

    private func rebase(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string
                .replacingOccurrences(
                    of: "/FixtureData/ManagedProfiles",
                    with: managedRootURL.path
                )
                .replacingOccurrences(
                    of: "/FixtureData/LegacyProfiles",
                    with: managedRootURL.path
                )
                .replacingOccurrences(
                    of: "/FixtureData/LegacyOptionalStorage",
                    with: managedRootURL.path
                )
                .replacingOccurrences(
                    of: "/Volumes/ParallaxFixtureExternal",
                    with: externalRootURL.path
                )
        case var dictionary as [String: Any]:
            for key in dictionary.keys {
                if let nested = dictionary[key] {
                    dictionary[key] = rebase(nested)
                }
            }
            if dictionary["displayName"] != nil, dictionary["profiles"] != nil,
               dictionary["baseStoragePath"] == nil {
                dictionary["baseStoragePath"] = managedRootURL.path
            }
            return dictionary
        case let array as [Any]:
            return array.map(rebase)
        default:
            return value
        }
    }

    private static func legacySanitizedComponent(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let scalars = name.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let sanitized = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return sanitized.isEmpty ? "Profile" : sanitized
    }

    private static func isSafeFixtureComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }
}

final class DeterministicUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]
    private var nextIndex = 0

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if nextIndex < values.count {
            defer { nextIndex += 1 }
            return values[nextIndex]
        }

        let suffix = nextIndex + 1
        nextIndex += 1
        return UUID(
            uuidString: String(
                format: "eeeeeeee-eeee-4eee-8eee-%012x",
                suffix
            )
        ) ?? UUID()
    }
}

final class MigrationOccurrenceFailingFileSystem: FileSystem, @unchecked Sendable {
    enum Operation: String, CaseIterable, Sendable {
        case fileExists
        case attributes
        case canonicalize
        case createDirectory
        case copyItem
        case moveItem
        case removeItem
        case contents
        case readData
        case writeData
        case writeDataAtomically
        case replaceItem
        case setPermissions
        case symlinkDestination
        case synchronize
        case applicationSupportURL
    }

    enum Timing: Sendable {
        case before
        case after
    }

    struct Event: Sendable {
        let operation: Operation
        let occurrence: Int
        let firstURL: URL?
        let secondURL: URL?
    }

    struct FailureRule: Sendable {
        let operation: Operation
        let occurrence: Int
        let timing: Timing

        init(
            _ operation: Operation,
            occurrence: Int,
            timing: Timing = .before
        ) {
            self.operation = operation
            self.occurrence = occurrence
            self.timing = timing
        }
    }

    enum InjectedError: Error {
        case occurrence(Operation, Int, Timing)
    }

    private let underlying: any FileSystem
    private let lock = NSLock()
    private let failureRule: FailureRule?
    private var operationCounts: [Operation: Int] = [:]
    private var recordedEvents: [Event] = []

    var beforeOperation: (@Sendable (Event) throws -> Void)?
    var afterOperation: (@Sendable (Event) throws -> Void)?

    init(
        underlying: any FileSystem = LocalFileSystem(),
        failureRule: FailureRule? = nil
    ) {
        self.underlying = underlying
        self.failureRule = failureRule
    }

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    func occurrenceCount(of operation: Operation) -> Int {
        lock.withLock { operationCounts[operation, default: 0] }
    }

    func fileExists(at url: URL) -> Bool {
        let event = record(.fileExists, firstURL: url)
        try? beforeOperation?(event)
        let result = underlying.fileExists(at: url)
        try? afterOperation?(event)
        return result
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        try around(.attributes, firstURL: url) {
            try underlying.attributesOfItem(at: url)
        }
    }

    func canonicalURL(for url: URL) throws -> URL {
        try around(.canonicalize, firstURL: url) {
            try underlying.canonicalURL(for: url)
        }
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try around(.createDirectory, firstURL: url) {
            try underlying.createDirectory(
                at: url,
                withIntermediateDirectories: withIntermediateDirectories
            )
        }
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try around(.copyItem, firstURL: sourceURL, secondURL: destinationURL) {
            try underlying.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try around(.moveItem, firstURL: sourceURL, secondURL: destinationURL) {
            try underlying.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    func removeItem(at url: URL) throws {
        try around(.removeItem, firstURL: url) {
            try underlying.removeItem(at: url)
        }
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try around(.contents, firstURL: url) {
            try underlying.contentsOfDirectory(at: url)
        }
    }

    func readData(at url: URL) throws -> Data {
        try around(.readData, firstURL: url) {
            try underlying.readData(at: url)
        }
    }

    func writeData(_ data: Data, to url: URL) throws {
        try around(.writeData, firstURL: url) {
            try underlying.writeData(data, to: url)
        }
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try around(.writeDataAtomically, firstURL: url) {
            try underlying.writeDataAtomically(data, to: url)
        }
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        try around(
            .replaceItem,
            firstURL: destinationURL,
            secondURL: sourceURL
        ) {
            try underlying.replaceItem(
                at: destinationURL,
                withItemAt: sourceURL
            )
        }
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try around(.setPermissions, firstURL: url) {
            try underlying.setPOSIXPermissions(permissions, at: url)
        }
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try around(.symlinkDestination, firstURL: url) {
            try underlying.destinationOfSymbolicLink(at: url)
        }
    }

    func synchronize(at url: URL) throws {
        try around(.synchronize, firstURL: url) {
            try underlying.synchronize(at: url)
        }
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try around(.applicationSupportURL) {
            try underlying.applicationSupportURL(create: create)
        }
    }

    private func around<T>(
        _ operation: Operation,
        firstURL: URL? = nil,
        secondURL: URL? = nil,
        body: () throws -> T
    ) throws -> T {
        let event = record(
            operation,
            firstURL: firstURL,
            secondURL: secondURL
        )
        try beforeOperation?(event)
        try failIfNeeded(event, timing: .before)
        let value = try body()
        try afterOperation?(event)
        try failIfNeeded(event, timing: .after)
        return value
    }

    private func record(
        _ operation: Operation,
        firstURL: URL? = nil,
        secondURL: URL? = nil
    ) -> Event {
        lock.withLock {
            operationCounts[operation, default: 0] += 1
            let event = Event(
                operation: operation,
                occurrence: operationCounts[operation, default: 0],
                firstURL: firstURL,
                secondURL: secondURL
            )
            recordedEvents.append(event)
            return event
        }
    }

    private func failIfNeeded(_ event: Event, timing: Timing) throws {
        guard
            let failureRule,
            failureRule.operation == event.operation,
            failureRule.occurrence == event.occurrence,
            failureRule.timing == timing
        else {
            return
        }
        throw InjectedError.occurrence(
            event.operation,
            event.occurrence,
            timing
        )
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
