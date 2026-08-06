import Darwin
import Foundation

// MARK: - Manifest and helpers

extension LibraryMigrationCoordinator {
  struct DirectoryManifest: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
      enum Kind: String, Hashable, Sendable {
        case directory
        case regularFile
        case symbolicLink
      }

      let relativePath: String
      let kind: Kind
      let size: UInt64?
      let posixPermissions: Int?
      let digestOrTarget: String?
    }

    let entries: [Entry]
  }

  struct MigrationJournal: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let migrationID: UUID
    let sourceFormat: String
    let sourceSHA256: String
    let sourceByteCount: Int
    let targetSHA256: String
    let createdAt: Date
    let applicationMappings: [LibraryMigrationApplicationMapping]
    let mappings: [LibraryMigrationPathMapping]

    enum CodingKeys: String, CodingKey {
      case schemaVersion
      case migrationID
      case sourceFormat
      case sourceSHA256
      case sourceByteCount
      case targetSHA256
      case createdAt
      case applicationMappings
      case mappings
    }

    init(
      schemaVersion: Int,
      migrationID: UUID,
      sourceFormat: String,
      sourceSHA256: String,
      sourceByteCount: Int,
      targetSHA256: String,
      createdAt: Date,
      applicationMappings: [LibraryMigrationApplicationMapping],
      mappings: [LibraryMigrationPathMapping]
    ) {
      self.schemaVersion = schemaVersion
      self.migrationID = migrationID
      self.sourceFormat = sourceFormat
      self.sourceSHA256 = sourceSHA256
      self.sourceByteCount = sourceByteCount
      self.targetSHA256 = targetSHA256
      self.createdAt = createdAt
      self.applicationMappings = applicationMappings
      self.mappings = mappings
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
      let migrationString = try container.decode(String.self, forKey: .migrationID)
      guard let migrationID = UUID(uuidString: migrationString) else {
        throw LibraryMigrationError.invalidJournal
      }
      self.migrationID = migrationID
      sourceFormat = try container.decode(String.self, forKey: .sourceFormat)
      sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
      sourceByteCount = try container.decode(Int.self, forKey: .sourceByteCount)
      targetSHA256 = try container.decode(String.self, forKey: .targetSHA256)
      createdAt = try container.decode(Date.self, forKey: .createdAt)
      applicationMappings = try container.decode(
        [LibraryMigrationApplicationMapping].self,
        forKey: .applicationMappings
      )
      mappings = try container.decode(
        [LibraryMigrationPathMapping].self,
        forKey: .mappings
      )
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(schemaVersion, forKey: .schemaVersion)
      try container.encode(
        migrationID.uuidString.lowercased(),
        forKey: .migrationID
      )
      try container.encode(sourceFormat, forKey: .sourceFormat)
      try container.encode(sourceSHA256, forKey: .sourceSHA256)
      try container.encode(sourceByteCount, forKey: .sourceByteCount)
      try container.encode(targetSHA256, forKey: .targetSHA256)
      try container.encode(createdAt, forKey: .createdAt)
      try container.encode(applicationMappings, forKey: .applicationMappings)
      try container.encode(mappings, forKey: .mappings)
    }
  }

  struct PublicationRecord: Codable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
      case prepared
      case published
    }

    let migrationID: String
    let applicationStorageID: String
    let profileStorageID: String
    let profileOccurrence: Int
    let manifestSHA256: String
    let state: State
  }

  struct RollbackRequiredRecord: Codable, Hashable, Sendable {
    let migrationID: String
    let reason: String
  }

  struct ControlPaths {
    let directory: URL
    let backup: URL
    let journal: URL
    let receipt: URL
    let pendingReceipt: URL
    let pendingLibrary: URL
  }

  var parallaxURL: URL {
    applicationSupportURL.appendingPathComponent("Parallax", isDirectory: true)
  }

  var libraryURL: URL {
    parallaxURL.appendingPathComponent("library.json")
  }

  var migrationsRootURL: URL {
    parallaxURL.appendingPathComponent("Migrations", isDirectory: true)
  }

  func controlPaths(for migrationID: UUID) -> ControlPaths {
    let directory = migrationsRootURL.appendingPathComponent(
      migrationID.uuidString.lowercased(),
      isDirectory: true
    )
    return ControlPaths(
      directory: directory,
      backup: directory.appendingPathComponent("library-v1.backup.json"),
      journal: directory.appendingPathComponent("journal.json"),
      receipt: directory.appendingPathComponent("receipt.json"),
      pendingReceipt: directory.appendingPathComponent("receipt.pending.json"),
      pendingLibrary: directory.appendingPathComponent("library-v2.pending.json")
    )
  }

  func publicationURL(
    migrationID: UUID,
    mapping: LibraryMigrationPathMapping
  ) -> URL {
    controlPaths(for: migrationID).directory.appendingPathComponent(
      "publication-\(mapping.profileOccurrence).json",
      isDirectory: false
    )
  }

  func publicationRecord(
    journal: MigrationJournal,
    mapping: LibraryMigrationPathMapping,
    state: PublicationRecord.State
  ) throws -> PublicationRecord {
    guard let manifest = mapping.sourceManifestSHA256 else {
      throw LibraryMigrationError.invalidJournal
    }
    return PublicationRecord(
      migrationID: journal.migrationID.uuidString.lowercased(),
      applicationStorageID:
        mapping.applicationStorageID.uuidString.lowercased(),
      profileStorageID: mapping.profileStorageID.uuidString.lowercased(),
      profileOccurrence: mapping.profileOccurrence,
      manifestSHA256: manifest,
      state: state
    )
  }

  func writePublicationState(
    journal: MigrationJournal,
    mapping: LibraryMigrationPathMapping,
    state: PublicationRecord.State
  ) throws {
    let url = publicationURL(
      migrationID: journal.migrationID,
      mapping: mapping
    )
    let data = try encoded(
      publicationRecord(
        journal: journal,
        mapping: mapping,
        state: state
      )
    )
    if fileSystem.fileExists(at: url) {
      try fileSystem.writeDataAtomically(data, to: url)
      try fileSystem.setPOSIXPermissions(0o600, at: url)
      try fileSystem.synchronize(at: url)
      try fileSystem.synchronize(at: url.deletingLastPathComponent())
    } else {
      try publishControlData(
        data,
        to: url,
        parent: url.deletingLastPathComponent()
      )
    }
  }

  func readPublicationState(
    journal: MigrationJournal,
    mapping: LibraryMigrationPathMapping
  ) throws -> PublicationRecord? {
    let url = publicationURL(
      migrationID: journal.migrationID,
      mapping: mapping
    )
    guard fileSystem.fileExists(at: url) else { return nil }
    let decoded = try JSONDecoder().decode(
      PublicationRecord.self,
      from: fileSystem.readData(at: url)
    )
    let prepared = try publicationRecord(
      journal: journal,
      mapping: mapping,
      state: decoded.state
    )
    guard decoded == prepared else {
      throw LibraryMigrationError.invalidJournal
    }
    return decoded
  }

  func markRollbackRequired(
    journal: MigrationJournal,
    reason: String
  ) throws {
    let url = controlPaths(for: journal.migrationID).directory
      .appendingPathComponent("rollback-required.json")
    let data = try encoded(
      RollbackRequiredRecord(
        migrationID: journal.migrationID.uuidString.lowercased(),
        reason: reason
      )
    )
    if fileSystem.fileExists(at: url) {
      try fileSystem.writeDataAtomically(data, to: url)
      try fileSystem.synchronize(at: url)
    } else {
      try publishControlData(
        data,
        to: url,
        parent: url.deletingLastPathComponent()
      )
    }
  }

  func directoryManifest(at root: URL) throws -> DirectoryManifest {
    var entries: [DirectoryManifest.Entry] = []
    try appendManifestEntries(root: root, current: root, result: &entries)
    return DirectoryManifest(
      entries: entries.sorted { $0.relativePath < $1.relativePath }
    )
  }

  func manifestSHA256(_ manifest: DirectoryManifest) -> String {
    let rows = manifest.entries.map { entry in
      [
        entry.relativePath,
        entry.kind.rawValue,
        entry.size.map(String.init) ?? "",
        entry.posixPermissions.map(String.init) ?? "",
        entry.digestOrTarget ?? "",
      ].joined(separator: "\u{1f}")
    }.joined(separator: "\u{1e}")
    return LibraryPersistence.sha256(Data(rows.utf8))
  }

  func verifySourceUnchanged(_ source: SourceRecord) throws {
    guard
      source.sourceExists,
      let expectedManifest = source.sourceManifest
    else {
      return
    }
    let attributes = try fileSystem.attributesOfItem(
      at: source.canonicalSourceURL
    )
    guard
      attributes.kind == .directory,
      attributes.identity == source.sourceIdentity,
      try directoryManifest(at: source.canonicalSourceURL)
        == expectedManifest
    else {
      throw LibraryMigrationError.sourceChanged
    }
  }

  func appendManifestEntries(
    root: URL,
    current: URL,
    result: inout [DirectoryManifest.Entry]
  ) throws {
    let attributes = try fileSystem.attributesOfItem(at: current)
    let relative = relativePath(of: current, under: root)
    switch attributes.kind {
    case .directory:
      result.append(
        .init(
          relativePath: relative,
          kind: .directory,
          size: nil,
          posixPermissions: attributes.posixPermissions,
          digestOrTarget: nil
        )
      )
      for child in try fileSystem.contentsOfDirectory(at: current)
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      {
        try appendManifestEntries(root: root, current: child, result: &result)
      }
    case .regularFile:
      let data = try fileSystem.readData(at: current)
      result.append(
        .init(
          relativePath: relative,
          kind: .regularFile,
          size: UInt64(data.count),
          posixPermissions: attributes.posixPermissions,
          digestOrTarget: LibraryPersistence.sha256(data)
        )
      )
    case .symbolicLink:
      result.append(
        .init(
          relativePath: relative,
          kind: .symbolicLink,
          size: attributes.size,
          posixPermissions: attributes.posixPermissions,
          digestOrTarget: try fileSystem.destinationOfSymbolicLink(at: current)
        )
      )
    case .other:
      throw LibraryMigrationError.unsupportedSourceItem(current.path)
    }
  }

  func relativePath(of url: URL, under root: URL) -> String {
    let rootComponents = root.standardizedFileURL.pathComponents
    let components = url.standardizedFileURL.pathComponents
    return components.dropFirst(rootComponents.count).joined(separator: "/")
  }

  func ownerMarkerURL(
    destination: URL,
    mapping: LibraryMigrationPathMapping
  ) -> URL {
    destination
      .deletingLastPathComponent()
      .appendingPathComponent(
        ".\(mapping.profileStorageID.uuidString.lowercased())."
          + "\(mapping.applicationStorageID.uuidString.lowercased()).owner",
        isDirectory: false
      )
  }

  func resolvedPaths(
    for mapping: LibraryMigrationPathMapping
  ) throws -> ResolvedProfilePaths {
    let destination = URL(
      fileURLWithPath: mapping.newCanonicalPath,
      isDirectory: true
    )
    let components = destination.pathComponents
    let suffix = [
      ".parallax",
      "Applications",
      mapping.applicationStorageID.uuidString.lowercased(),
      "Profiles",
      mapping.profileStorageID.uuidString.lowercased(),
    ]
    guard
      components.count > suffix.count,
      Array(components.suffix(suffix.count)) == suffix
    else {
      throw LibraryMigrationError.invalidJournal
    }
    let baseComponents = components.dropLast(suffix.count)
    let basePath = NSString.path(
      withComponents: Array(baseComponents)
    )
    let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
      baseRootURL: URL(fileURLWithPath: basePath, isDirectory: true),
      applicationStorageID: mapping.applicationStorageID,
      profileStorageID: mapping.profileStorageID
    )
    guard resolved.profileRoot.url.path == destination.path else {
      throw LibraryMigrationError.invalidJournal
    }
    return resolved
  }

  func ownerData(
    for journal: MigrationJournal,
    mapping: LibraryMigrationPathMapping
  ) -> Data {
    Data(
      "\(journal.migrationID.uuidString.lowercased()):"
        .appending(mapping.profileStorageID.uuidString.lowercased())
        .utf8
    )
  }

  func receipt(
    for journal: MigrationJournal,
    completedAt: Date
  ) -> LibraryMigrationReceipt {
    LibraryMigrationReceipt(
      schemaVersion: journal.schemaVersion,
      migrationID: journal.migrationID,
      sourceFormat: journal.sourceFormat,
      sourceSHA256: journal.sourceSHA256,
      sourceByteCount: journal.sourceByteCount,
      targetSHA256: journal.targetSHA256,
      backupRelativePath: "library-v1.backup.json",
      startedAt: journal.createdAt,
      completedAt: completedAt,
      committedAt: completedAt,
      legacyDataRetention: "retainedInPlace",
      applicationMappings: journal.applicationMappings,
      mappings: journal.mappings
    )
  }

  func currentPrimaryHash() throws -> String {
    LibraryPersistence.sha256(try fileSystem.readData(at: libraryURL))
  }

  func verifyPrimaryStillMatches(_ snapshot: LegacyLibrarySnapshot) throws {
    let current = try fileSystem.readData(at: libraryURL)
    guard
      current.count == snapshot.sourceByteCount,
      LibraryPersistence.sha256(current) == snapshot.sourceSHA256
    else {
      throw LibraryMigrationError.sourceChanged
    }
  }

  func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
      .prettyPrinted,
      .sortedKeys,
      .withoutEscapingSlashes,
    ]
    return try encoder.encode(value)
  }

  func encodedLibrary(_ applications: [ManagedApplication]) throws -> Data {
    try encoded(LibraryDocument(applications: applications))
  }

  func publishControlData(
    _ data: Data,
    to destination: URL,
    parent: URL
  ) throws {
    let pending = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).pending",
      isDirectory: false
    )
    if fileSystem.fileExists(at: pending) {
      guard try fileSystem.readData(at: pending) == data else {
        throw LibraryMigrationError.recoveryConflict
      }
    } else {
      try fileSystem.writeData(data, to: pending)
      try fileSystem.setPOSIXPermissions(0o600, at: pending)
      try fileSystem.synchronize(at: pending)
    }
    try fileSystem.moveItem(at: pending, to: destination)
    try fileSystem.setPOSIXPermissions(0o600, at: destination)
    try fileSystem.synchronize(at: destination)
    try fileSystem.synchronize(at: parent)
  }

  func legacyBasePath(for application: LegacyManagedApplication) -> String {
    let trimmed =
      application.baseStoragePath?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let historicalDefault = URL(
      fileURLWithPath: NSHomeDirectory(),
      isDirectory: true
    )
    .appendingPathComponent(
      "Library/Application Support/Parallax/Profiles",
      isDirectory: true
    )
    .path
    guard !trimmed.isEmpty else {
      return historicalDefault
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    return URL(
      fileURLWithPath: expanded,
      isDirectory: true
    ).standardizedFileURL.path
  }

  func canonicalBasePath(
    for application: LegacyManagedApplication,
    applicationOccurrence: Int,
    sources: [SourceRecord]
  ) throws -> String {
    if let source = sources.first(where: {
      $0.applicationOccurrence == applicationOccurrence
    }) {
      return source.canonicalBaseRoot.standardizedFileURL.path
    }
    let paths = try ManagedPathResolver(fileSystem: fileSystem).resolve(
      configuredBaseRoot: legacyBasePath(for: application),
      applicationStorageID: Self.applicationUUID,
      profileStorageID: Self.profileUUID
    )
    return paths.profileRoot.validationContext.canonicalBaseRootURL
      .standardizedFileURL.path
  }

  func sourceFormat(_ format: LegacyLibrary.Format) -> String {
    switch format {
    case .versioned(let version):
      "versioned-v\(version)"
    case .rawApplicationArray:
      "rawApplicationArray"
    }
  }

  func legacySanitizedComponent(_ name: String) -> String {
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

  func isSafeLegacyComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.contains("/")
      && !value.contains("\\")
      && !value.unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0)
      }
  }

  func compatibilityKey(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased()
  }

  func canonicalExistingOrExpected(
    _ requested: URL,
    canonicalBase: URL,
    relativeComponents: [String]
  ) -> URL {
    if fileSystem.fileExists(at: requested),
      let canonical = try? fileSystem.canonicalURL(for: requested)
    {
      return canonical.standardizedFileURL
    }
    return relativeComponents.reduce(canonicalBase) {
      $0.appendingPathComponent($1, isDirectory: true)
    }
  }

  func contains(_ target: URL, within root: URL) -> Bool {
    let rootComponents = root.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    guard targetComponents.count >= rootComponents.count else { return false }
    return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
  }

  func attributesIfExists(
    at url: URL
  ) throws -> FileSystemItemAttributes? {
    do {
      return try fileSystem.attributesOfItem(at: url)
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain,
        nsError.code == CocoaError.fileNoSuchFile.rawValue
          || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
      {
        return nil
      }
      if nsError.domain == NSPOSIXErrorDomain,
        nsError.code == Int(ENOENT) || nsError.code == Int(ENOTDIR)
      {
        return nil
      }
      throw error
    }
  }

  func uniqueBlockers(
    _ blockers: [LibraryMigrationBlocker]
  ) -> [LibraryMigrationBlocker] {
    Array(Set(blockers)).sorted {
      if $0.kind.rawValue == $1.kind.rawValue {
        return $0.recordOccurrences.lexicographicallyPrecedes(
          $1.recordOccurrences
        )
      }
      return $0.kind.rawValue < $1.kind.rawValue
    }
  }

  func duplicateValues(_ values: [UUID]) -> Set<UUID> {
    Dictionary(grouping: values, by: { $0 })
      .filter { $0.value.count > 1 }
      .keys
      .reduce(into: Set<UUID>()) { $0.insert($1) }
  }

  func nextUniqueUUID(occupied: inout Set<UUID>) -> UUID {
    while true {
      let candidate = uuidGenerator()
      if occupied.insert(candidate).inserted {
        return candidate
      }
    }
  }

  func isolationConfiguration(
    profile: LegacyLaunchProfile,
    source: SourceRecord
  ) -> LibraryMigrationPathMapping.IsolationConfiguration {
    let parsedArguments = ShellWordsParser.parseResult(profile.argumentsText)
    guard parsedArguments.isSyntacticallyValid else {
      return .requiresReview
    }
    let userDataValues = userDataArguments(in: profile.argumentsText)
    let codexHomeValues = environmentValues(
      "CODEX_HOME",
      in: profile.environmentText
    )
    let generatedUserData = source.sourceURL
      .appendingPathComponent("UserData", isDirectory: true).path
    let generatedCodexHome = source.sourceURL
      .appendingPathComponent("CodexHome", isDirectory: true).path
    if userDataValues.contains(where: { $0 != generatedUserData }) {
      return .external
    }
    if codexHomeValues.contains(where: { $0 != generatedCodexHome }) {
      return .external
    }
    if !userDataValues.isEmpty || !codexHomeValues.isEmpty {
      return .generated
    }
    return .none
  }

  func rewrittenConfiguration(
    profile: LegacyLaunchProfile,
    source: SourceRecord,
    destination: ResolvedProfilePaths
  ) -> (arguments: String, environment: String) {
    let oldUserData = source.sourceURL
      .appendingPathComponent("UserData", isDirectory: true).path
    let oldCodexHome = source.sourceURL
      .appendingPathComponent("CodexHome", isDirectory: true).path
    var arguments = profile.argumentsText
    let parsedArguments = ShellWordsParser.parseResult(arguments)
    let userDataValues = userDataArguments(in: arguments)
    let hasSplitUserDataOption = parsedArguments.words
      .contains("--user-data-dir")
    if parsedArguments.isSyntacticallyValid,
      !hasSplitUserDataOption,
      userDataValues.count == 1,
      generatedPath(userDataValues[0], matches: oldUserData)
    {
      arguments =
        replacingUniqueGeneratedPath(
          userDataValues[0],
          with: destination.userData.url.path,
          in: arguments
        ) ?? arguments
    }
    var environment = profile.environmentText
    let codexHomeValues = environmentValues("CODEX_HOME", in: environment)
    if codexHomeValues.count == 1,
      generatedPath(codexHomeValues[0], matches: oldCodexHome)
    {
      environment =
        replacingUniqueGeneratedPath(
          codexHomeValues[0],
          with: destination.codexHome.url.path,
          in: environment
        ) ?? environment
    }
    return (arguments, environment)
  }

  func userDataArguments(in text: String) -> [String] {
    let result = ShellWordsParser.parseResult(text)
    guard result.isSyntacticallyValid else { return [] }
    return result.words.filter {
      $0.hasPrefix("--user-data-dir=")
    }.map {
      String($0.dropFirst("--user-data-dir=".count))
    }
  }

  func environmentValues(_ key: String, in text: String) -> [String] {
    var values: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let string = String(line)
      let trimmed = string.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
        continue
      }
      let foundKey = String(trimmed[..<separator])
        .trimmingCharacters(in: .whitespaces)
      if foundKey == key {
        let rawValue = String(
          trimmed[trimmed.index(after: separator)...]
        ).trimmingCharacters(in: .whitespaces)
        values.append(unquotedEnvironmentValue(rawValue))
      }
    }
    return values
  }

  func unquotedEnvironmentValue(_ value: String) -> String {
    guard
      value.count >= 2,
      let first = value.first,
      first == "\"" || first == "'",
      value.last == first
    else {
      return value
    }
    return String(value.dropFirst().dropLast())
  }

  func generatedPath(_ candidate: String, matches expected: String) -> Bool {
    let expanded = (candidate as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { return false }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
      == URL(fileURLWithPath: expected).standardizedFileURL.path
  }

  func replacingUniqueGeneratedPath(
    _ original: String,
    with replacement: String,
    in text: String
  ) -> String? {
    let ranges = text.ranges(of: original)
    guard ranges.count == 1, let range = ranges.first else {
      return nil
    }
    var result = text
    result.replaceSubrange(range, with: replacement)
    return result
  }
}

extension String {
  func ranges(of needle: String) -> [Range<String.Index>] {
    guard !needle.isEmpty else { return [] }
    var result: [Range<String.Index>] = []
    var searchStart = startIndex
    while searchStart < endIndex,
      let range = range(
        of: needle,
        range: searchStart..<endIndex
      )
    {
      result.append(range)
      searchStart = range.upperBound
    }
    return result
  }
}
