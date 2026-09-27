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

  func checkCancellation(
    _ cancellation: StorageRelocationCancellation
  ) throws {
    if cancellation.isCancelled {
      throw StorageRelocationError(.cancelled)
    }
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

}
