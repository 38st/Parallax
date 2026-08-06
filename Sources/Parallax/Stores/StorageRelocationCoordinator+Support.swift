import Darwin
import Foundation

// MARK: - Planning and filesystem support

extension StorageRelocationCoordinator {
  func resolvedOwnership(
    _ ownership: IsolationPathOwnership,
    configuredValue: String?,
    generatedURL: URL
  ) -> IsolationPathOwnership {
    guard ownership == .legacyUnknown else { return ownership }
    guard
      let configuredValue,
      canonicalComparisonPath(configuredValue)
        == canonicalComparisonPath(generatedURL.path)
    else {
      return .explicit
    }
    return .generated
  }

  func canonicalComparisonPath(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
  }

  func activeProfileIDs(
    in application: ManagedApplication
  ) -> [UUID] {
    let activeStorageIDs =
      activityProvider.activeProfileStorageIDs(
        applicationStorageID: application.storageID,
        profileStorageIDs: Set(
          application.profiles.map(\.storageID)
        )
      )
    return application.profiles.compactMap { profile in
      activeStorageIDs.contains(profile.storageID)
        ? profile.id
        : nil
    }.sorted { $0.uuidString < $1.uuidString }
  }

  func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    let left = lhs.standardizedFileURL.pathComponents
    let right = rhs.standardizedFileURL.pathComponents
    return isPrefix(left, of: right) || isPrefix(right, of: left)
  }

  func isPrefix(_ prefix: [String], of value: [String]) -> Bool {
    prefix.count <= value.count
      && Array(value.prefix(prefix.count)) == prefix
  }

  func configuredBaseRoot(
    for application: ManagedApplication
  ) -> String {
    let trimmed =
      application.baseStoragePath?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
          "Library/Application Support/Parallax/Profiles",
          isDirectory: true
        )
        .path
      : application.baseStoragePath ?? ""
  }

  func estimateApplicationStorage(
    _ paths: ResolvedApplicationStoragePaths
  ) throws -> StorageTreeEstimate {
    try estimateIfPresent(source: paths.applicationRoot)
      + estimateIfPresent(source: paths.applicationArchiveRoot)
  }

  func estimateIfPresent(
    source: any ManagedMutationPath
  ) throws -> StorageTreeEstimate {
    guard fileSystem.fileExists(at: source.url) else { return .zero }
    _ = try pathResolver.revalidateForMutation(source)
    return try estimate(at: source.url)
  }

  func estimate(at url: URL) throws -> StorageTreeEstimate {
    let attributes = try fileSystem.attributesOfItem(at: url)
    switch attributes.kind {
    case .directory:
      var result = StorageTreeEstimate(
        allocatedBytes: 0,
        itemCount: 1
      )
      for child in try fileSystem.contentsOfDirectory(at: url) {
        result = result + (try estimate(at: child))
      }
      return result
    case .regularFile:
      return StorageTreeEstimate(
        allocatedBytes: attributes.size ?? 0,
        itemCount: 1
      )
    case .symbolicLink, .other:
      throw StorageRelocationError(
        .sourceChanged,
        path: url.path
      )
    }
  }

  func fingerprintIfPresent(
    _ path: any ManagedMutationPath
  ) throws -> String? {
    guard fileSystem.fileExists(at: path.url) else { return nil }
    _ = try pathResolver.revalidateForMutation(path)
    return try fingerprint(at: path.url)
  }

  func fingerprint(at root: URL) throws -> String {
    var entries: [RelocationManifestEntry] = []
    try appendManifest(
      at: root,
      relativePath: ".",
      entries: &entries
    )
    let manifestEncoder = JSONEncoder()
    manifestEncoder.outputFormatting = [.sortedKeys]
    return LibraryPersistence.sha256(try manifestEncoder.encode(entries))
  }

  func appendManifest(
    at url: URL,
    relativePath: String,
    entries: inout [RelocationManifestEntry]
  ) throws {
    let attributes = try fileSystem.attributesOfItem(at: url)
    switch attributes.kind {
    case .directory:
      entries.append(
        RelocationManifestEntry(
          relativePath: relativePath,
          kind: "directory",
          size: nil,
          contentSHA256: nil
        )
      )
      for child in try fileSystem.contentsOfDirectory(at: url)
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      {
        try appendManifest(
          at: child,
          relativePath: relativePath == "."
            ? child.lastPathComponent
            : relativePath + "/" + child.lastPathComponent,
          entries: &entries
        )
      }
    case .regularFile:
      let data = try fileSystem.readData(at: url)
      entries.append(
        RelocationManifestEntry(
          relativePath: relativePath,
          kind: "file",
          size: UInt64(data.count),
          contentSHA256: LibraryPersistence.sha256(data)
        )
      )
    case .symbolicLink, .other:
      throw StorageRelocationError(.sourceChanged, path: url.path)
    }
  }

  func availableCapacity(at url: URL) -> UInt64? {
    capacityProvider(url)
  }

  static func systemAvailableCapacity(at url: URL) -> UInt64? {
    guard
      let values = try? url.resourceValues(
        forKeys: [
          .volumeAvailableCapacityForImportantUsageKey,
          .volumeAvailableCapacityKey,
        ]
      )
    else { return nil }
    if let important = values.volumeAvailableCapacityForImportantUsage,
      important >= 0
    {
      return UInt64(important)
    }
    if let available = values.volumeAvailableCapacity, available >= 0 {
      return UInt64(available)
    }
    return nil
  }

  func requireDestinationAbsent(
    _ paths: ResolvedApplicationStoragePaths
  ) throws {
    guard
      !fileSystem.fileExists(at: paths.applicationRoot.url),
      !fileSystem.fileExists(at: paths.applicationArchiveRoot.url)
    else {
      throw StorageRelocationError(
        .unexpectedDestination,
        path: paths.canonicalBaseRootURL.path
      )
    }
    _ = try pathResolver.revalidateForMutation(paths.applicationRoot)
    _ = try pathResolver.revalidateForMutation(
      paths.applicationArchiveRoot
    )
  }

  func restoreOriginal(
    source: any ManagedMutationPath,
    destination: any ManagedMutationPath,
    staged: RelocationManagedPath,
    retired: RelocationManagedPath,
    strategy: StorageRelocationStrategy
  ) throws {
    if fileSystem.fileExists(at: source.url) {
      try removeIfPresent(destination)
      try removeIfPresent(staged)
      try removeIfPresent(retired)
      return
    }
    if fileSystem.fileExists(at: retired.url) {
      try move(retired, to: source)
      try removeIfPresent(destination)
      try removeIfPresent(staged)
      return
    }
    if strategy == .sameVolume,
      fileSystem.fileExists(at: destination.url)
    {
      try move(destination, to: source)
      try removeIfPresent(staged)
      return
    }
    if strategy == .sameVolume,
      fileSystem.fileExists(at: staged.url)
    {
      try move(staged, to: source)
      try removeIfPresent(destination)
      return
    }
    throw StorageRelocationError(
      .rollbackRequired,
      path: source.url.path
    )
  }

  func checkCancellation(
    _ cancellation: StorageRelocationCancellation
  ) throws {
    if cancellation.isCancelled {
      throw StorageRelocationError(.cancelled)
    }
  }

  func exists(_ path: any ManagedMutationPath) -> Bool {
    fileSystem.fileExists(at: path.url)
  }

  func createDirectory(_ path: any ManagedMutationPath) throws {
    let url = try pathResolver.revalidateForMutation(path)
    if fileSystem is LocalFileSystem,
      let securePath = try securePath(path)
    {
      let secureFileSystem = try SecureManagedFileSystem(
        rootURL: path.validationContext.canonicalBaseRootURL
      )
      try secureFileSystem.createDirectory(at: securePath)
      return
    }
    try fileSystem.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    try fileSystem.setPOSIXPermissions(0o700, at: url)
  }

  func copy(
    _ source: any ManagedMutationPath,
    to destination: any ManagedMutationPath
  ) throws {
    let sourceURL = try pathResolver.revalidateForMutation(source)
    let destinationURL = try pathResolver.revalidateForMutation(destination)
    guard !fileSystem.fileExists(at: destinationURL) else {
      throw StorageRelocationError(
        .unexpectedDestination,
        path: destinationURL.path
      )
    }
    if fileSystem is LocalFileSystem,
      let sourcePath = try securePath(source),
      let destinationPath = try securePath(destination)
    {
      let sourceFileSystem = try SecureManagedFileSystem(
        rootURL: source.validationContext.canonicalBaseRootURL
      )
      let destinationFileSystem = try SecureManagedFileSystem(
        rootURL: destination.validationContext.canonicalBaseRootURL
      )
      try sourceFileSystem.copyTree(
        from: sourcePath,
        to: destinationPath,
        in: destinationFileSystem
      )
      return
    }
    try fileSystem.copyItem(at: sourceURL, to: destinationURL)
  }

  func move(
    _ source: any ManagedMutationPath,
    to destination: any ManagedMutationPath
  ) throws {
    let sourceURL = try pathResolver.revalidateForMutation(source)
    let destinationURL = try pathResolver.revalidateForMutation(destination)
    guard !fileSystem.fileExists(at: destinationURL) else {
      throw StorageRelocationError(
        .unexpectedDestination,
        path: destinationURL.path
      )
    }
    if fileSystem is LocalFileSystem,
      source.validationContext.canonicalBaseRootURL
        == destination.validationContext.canonicalBaseRootURL,
      let sourcePath = try securePath(source),
      let destinationPath = try securePath(destination)
    {
      let secureFileSystem = try SecureManagedFileSystem(
        rootURL: source.validationContext.canonicalBaseRootURL
      )
      try secureFileSystem.rename(
        from: sourcePath,
        to: destinationPath
      )
      return
    }
    try fileSystem.moveItem(at: sourceURL, to: destinationURL)
  }

  func removeIfPresent(
    _ path: any ManagedMutationPath
  ) throws {
    guard fileSystem.fileExists(at: path.url) else { return }
    let url = try pathResolver.revalidateForMutation(path)
    if fileSystem is LocalFileSystem,
      let securePath = try securePath(path)
    {
      let secureFileSystem = try SecureManagedFileSystem(
        rootURL: path.validationContext.canonicalBaseRootURL
      )
      try secureFileSystem.removeTree(at: securePath)
      return
    }
    try fileSystem.removeItem(at: url)
  }

  func securePath(
    _ path: any ManagedMutationPath
  ) throws -> SecureManagedPath? {
    let rootComponents =
      path.validationContext.canonicalBaseRootURL.pathComponents
    let pathComponents = path.url.pathComponents
    guard
      pathComponents.count > rootComponents.count,
      Array(pathComponents.prefix(rootComponents.count))
        == rootComponents
    else { return nil }
    return try SecureManagedPath(
      Array(pathComponents.dropFirst(rootComponents.count))
    )
  }

  func persist(
    _ receipt: StorageRelocationReceipt,
    at path: RelocationReceiptPath
  ) throws {
    let data = try encoder.encode(receipt)
    // The resolver's mutation path contract describes directories. Validate
    // the containing transaction directory immediately before writing the
    // fixed receipt filename, rather than treating an existing JSON file as
    // a directory target on subsequent state transitions.
    let parent = RelocationManagedPath(
      url: path.url.deletingLastPathComponent(),
      validationContext: path.validationContext
    )
    _ = try pathResolver.revalidateForMutation(parent)
    try fileSystem.writeDataAtomically(data, to: path.url)
  }

  func child(
    _ name: String,
    in staging: ManagedStagingRootPath
  ) -> RelocationManagedPath {
    RelocationManagedPath(
      url: staging.url.appendingPathComponent(name, isDirectory: true),
      validationContext: staging.validationContext
    )
  }

  func childFile(
    _ name: String,
    in staging: ManagedStagingRootPath
  ) -> RelocationReceiptPath {
    RelocationReceiptPath(
      url: staging.url.appendingPathComponent(name, isDirectory: false),
      validationContext: staging.validationContext
    )
  }

  func userDataValue(in profile: LaunchProfile) -> String? {
    for argument in profile.arguments {
      guard argument.hasPrefix("--user-data-dir=") else { continue }
      let value = String(
        argument.dropFirst("--user-data-dir=".count)
      )
      if !value.isEmpty { return value }
    }
    return nil
  }

  func settingUserDataValue(
    _ value: String,
    in text: String
  ) -> String {
    var replaced = false
    let replacement = "--user-data-dir=\(value)"
    var arguments = ShellWordsParser.parse(text).map { argument in
      guard argument.hasPrefix("--user-data-dir=") else {
        return argument
      }
      replaced = true
      return replacement
    }
    if !replaced {
      arguments.append(replacement)
    }
    return arguments.map(ShellWordsParser.quote).joined(separator: " ")
  }

  func environmentValue(
    _ key: String,
    in text: String
  ) -> String? {
    for line in text.split(whereSeparator: \.isNewline) {
      let string = String(line)
      guard let separator = string.firstIndex(of: "=") else { continue }
      let candidate = string[..<separator]
        .trimmingCharacters(in: .whitespaces)
      guard candidate == key else { continue }
      return String(string[string.index(after: separator)...])
        .trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  func settingEnvironmentValue(
    _ key: String,
    to value: String,
    in text: String
  ) -> String {
    var replaced = false
    let lines = text.split(
      separator: "\n",
      omittingEmptySubsequences: false
    ).map { line -> String in
      let string = String(line)
      guard let separator = string.firstIndex(of: "=") else {
        return string
      }
      let candidate = string[..<separator]
        .trimmingCharacters(in: .whitespaces)
      guard candidate == key else { return string }
      replaced = true
      return "\(key)=\(value)"
    }
    if replaced {
      return lines.joined(separator: "\n")
    }
    let suffix = "\(key)=\(value)"
    return text.isEmpty ? suffix : text + "\n" + suffix
  }
}
