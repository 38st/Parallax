import CryptoKit
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
    let expanded = PathSpecificTildeExpander(homeDirectory: homeDirectory.path)
      .argumentValue(path, forOption: "--user-data-dir")
    return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
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
    try checkPreparationCancellation(at: url)
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
        .unsafeSource,
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
    try checkPreparationCancellation(at: url)
    let attributes = try fileSystem.attributesOfItem(at: url)
    switch attributes.kind {
    case .directory:
      entries.append(
        RelocationManifestEntry(
          relativePath: relativePath.precomposedStringWithCanonicalMapping,
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
      let digest = try contentDigest(at: url)
      entries.append(
        RelocationManifestEntry(
          relativePath: relativePath.precomposedStringWithCanonicalMapping,
          kind: "file",
          size: digest.size,
          contentSHA256: digest.sha256
        )
      )
    case .symbolicLink, .other:
      throw StorageRelocationError(.unsafeSource, path: url.path)
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
      do {
        try sourceFileSystem.copyTree(from: sourcePath, to: destinationPath, in: destinationFileSystem)
      } catch SecureManagedFileSystemError.manifestMismatch {
        throw StorageRelocationError(.copyVerificationFailed)
      }
      return
    }
    do { try fileSystem.copyItem(at: sourceURL, to: destinationURL) }
    catch SecureManagedFileSystemError.manifestMismatch { throw StorageRelocationError(.copyVerificationFailed) }
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
    LibraryStore.userDataDirectoryArgumentValue(in: profile)
  }

  func settingUserDataValue(_ value: String, in text: String) -> String {
    let parsed = LaunchArgumentParser.parse(text)
    let resolution = UserDataDirectoryOptionResolver.resolve(in: parsed.tokens)
    let replacement = ShellWordsParser.quote("--user-data-dir=\(value)")
    let updated = NSMutableString(string: text)
    if let occurrence = resolution.occurrences.first {
      let end = occurrence.valueRange?.end ?? occurrence.optionRange.end
      updated.replaceCharacters(in: NSRange(
        location: occurrence.optionRange.start.utf16Offset,
        length: end.utf16Offset - occurrence.optionRange.start.utf16Offset
      ), with: replacement)
    } else if let terminator = parsed.tokens.first(where: { $0.value == "--" }) {
      updated.insert(replacement + " ", at: terminator.range.start.utf16Offset)
    } else {
      updated.append(text.isEmpty ? replacement : " " + replacement)
    }
    return updated as String
  }

  func environmentValue(_ key: String, in text: String) -> String? {
    LaunchEnvironmentParser.parse(text).effectiveValues[key]
  }

  func settingEnvironmentValue(_ key: String, to value: String, in text: String) throws -> String {
    let replacement = "\(key)=\(value)"
    let proposed = LaunchEnvironmentParser.parse(replacement)
    guard !proposed.hasErrors, proposed.entries.count == 1,
      proposed.entries.first?.name == key,
      proposed.entries.first?.operation == .set(value)
    else { throw LaunchConfigurationTextError.invalidEnvironmentEntry }
    let matches = LaunchEnvironmentParser.parse(text).entries.filter { $0.name == key }
    guard !matches.isEmpty else {
      return text.isEmpty || text.utf8.last == 0x0a ? text + replacement : text + "\n" + replacement
    }
    let updated = NSMutableString(string: text)
    for entry in matches.reversed() {
      updated.replaceCharacters(in: NSRange(
        location: entry.range.start.utf16Offset,
        length: entry.range.end.utf16Offset - entry.range.start.utf16Offset
      ), with: replacement)
    }
    return updated as String
  }

  func excluding(_ reservation: ProfileActivityReservation) -> StorageRelocationCoordinator {
    var coordinator = self
    coordinator.activityProvider = reservation.activityProvider
    return coordinator
  }

  func activityIdentities(_ application: ManagedApplication) -> Set<ProfileActivityIdentity> {
    Set(application.profiles.map { profile in
      ProfileActivityIdentity(applicationID: application.id, applicationStorageID: application.storageID,
        profileID: profile.id, profileStorageID: profile.storageID)
    })
  }

  func isInsideManagedNamespace(_ url: URL) -> Bool {
    let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
    return components.indices.contains { index in
      components[index] == ".parallax" && components.indices.contains(index + 1)
        && ["applications", "archives"].contains(components[index + 1])
    }
  }

  func verifyPublication(_ preview: StorageRelocationPreview, plan: StorageRelocationControlPlan) throws {
    try verifyPublication(plan: plan, destination: preview.destination)
  }

  func verifyPublication(plan: StorageRelocationControlPlan, destination: ResolvedApplicationStoragePaths) throws {
    guard try loadControlPlan(plan.unsigned.transactionID).planSHA256 == plan.planSHA256,
      try loadControlReceiptIfPresent(plan: plan) == nil else {
      throw StorageRelocationError(.invalidReceipt)
    }
    try requireRecoveryCopy(destination.applicationRoot, snapshot: plan.unsigned.sourceApplicationSnapshot)
    try requireRecoveryCopy(destination.applicationArchiveRoot, snapshot: plan.unsigned.sourceArchiveSnapshot)
  }

  func synchronizeDestination(_ paths: ResolvedApplicationStoragePaths) throws {
    let roots: [any ManagedMutationPath] = [paths.applicationRoot, paths.applicationArchiveRoot]
    for path in roots {
      guard let relative = try securePath(path) else { continue }
      let secure = try SecureManagedFileSystem(rootURL: path.validationContext.canonicalBaseRootURL)
      guard try secure.itemState(at: relative) != .missing else { continue }
      try transactionBoundary?(.beforeDestinationSync(path.url))
      let (parent, leaf) = try secure.openParent(of: relative, createMissing: false)
      defer { close(parent) }
      let root = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard root >= 0 else { throw StorageRelocationError(.sourceChanged, path: path.url.path) }
      defer { close(root) }
      // copyTree already fsyncs every item. Flush the drive cache once for
      // this root and once for its publication directory, not for every file.
      try synchronizeDescriptor(root)
      try synchronizeDescriptor(parent)
      try secure.verifyRootIdentity()
    }
  }

  func checkPreparationCancellation(at url: URL) throws {
    guard let preparationCancellation else { return }
    try checkCancellation(preparationCancellation)
    try transactionBoundary?(.beforePreviewRead(url))
    try checkCancellation(preparationCancellation)
  }

  func contentDigest(at url: URL) throws -> (size: UInt64, sha256: String) {
    guard fileSystem is LocalFileSystem else {
      try checkPreparationCancellation(at: url)
      let data = try fileSystem.readData(at: url)
      try checkPreparationCancellation(at: url)
      return (UInt64(data.count), LibraryPersistence.sha256(data))
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw StorageRelocationError(.sourceChanged, path: url.path) }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1 else { throw StorageRelocationError(.unsafeSource, path: url.path) }
    return try contentDigest(descriptor: descriptor, url: url)
  }

  func contentDigest(descriptor: Int32, url: URL) throws -> (size: UInt64, sha256: String) {
    var hasher = SHA256()
    var size: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      try checkPreparationCancellation(at: url)
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw StorageRelocationError(.sourceChanged, path: url.path)
      }
      size += UInt64(count)
      hasher.update(data: Data(buffer.prefix(count)))
    }
    return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
  }

  func previewManifest(in secure: SecureManagedFileSystem, at path: SecureManagedPath,
    url: URL) throws -> [StorageRelocationManifestEntry] {
    let (parent, leaf) = try secure.openParent(of: path, createMissing: false)
    defer { close(parent) }
    func readItem(parent: Int32, name: String, components: [String]) throws -> [StorageRelocationManifestEntry] {
      let itemURL = components.reduce(url) { $0.appendingPathComponent($1) }
      try checkPreparationCancellation(at: itemURL)
      let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { throw StorageRelocationError(.unsafeSource, path: itemURL.path) }
      defer { close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFDIR || status.st_mode & S_IFMT == S_IFREG,
        status.st_mode & S_IFMT == S_IFDIR || status.st_nlink == 1
      else { throw StorageRelocationError(.unsafeSource, path: itemURL.path) }
      let directory = status.st_mode & S_IFMT == S_IFDIR
      let digest = directory ? nil : try contentDigest(descriptor: descriptor, url: itemURL)
      var entries = [StorageRelocationManifestEntry(relativeComponents: components,
        kind: directory ? "directory" : "regularFile", byteCount: digest?.size ?? 0,
        permissions: UInt16(status.st_mode & 0o777), sha256: digest?.sha256)]
      if directory {
        for child in try secure.directoryEntryNames(descriptor) {
          entries += try readItem(parent: descriptor, name: child, components: components + [child])
        }
      }
      var final = stat()
      guard fstat(descriptor, &final) == 0, SecureManagedFileSystem.isSameObject(status, final),
        status.st_size == final.st_size, status.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
        status.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec else {
        throw StorageRelocationError(.sourceChanged, path: itemURL.path)
      }
      return entries
    }
    let entries = try readItem(parent: parent, name: leaf, components: [])
    try secure.verifyRootIdentity()
    return entries
  }

  static func synchronizeFully(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    let code = errno
    guard code == EINVAL || code == ENOTSUP || code == ENOTTY || code == ENOSYS else {
      throw SecureManagedFileSystemError.systemCall(operation: "synchronize relocation data", code: code)
    }
    guard fsync(descriptor) == 0 else {
      throw SecureManagedFileSystemError.systemCall(operation: "synchronize relocation data", code: errno)
    }
  }
}
