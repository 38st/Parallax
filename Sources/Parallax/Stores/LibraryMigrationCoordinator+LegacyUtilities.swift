import Darwin
import Foundation

extension LibraryMigrationCoordinator {
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
