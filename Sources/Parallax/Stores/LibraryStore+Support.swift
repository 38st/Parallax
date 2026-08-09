import AppKit
import Foundation
import Observation

// MARK: - Shared implementation support

enum GeneratedDisplayNameError: LocalizedError, Equatable {
  case importedCopyUnavailable

  var errorDescription: String? {
    switch self {
    case .importedCopyUnavailable:
      String(
        localized:
          "Parallax could not create a unique valid name for the imported copy."
      )
    }
  }
}

extension LibraryStore {
  func externalDataHandling(
    for profile: LaunchProfile
  ) -> ProfileExternalDataHandling {
    var configuredKinds: [String] = []
    if profile.isolationOwnership.userData != .generated,
      hasUserDataDirectoryConfigured(in: profile)
    {
      configuredKinds.append("user-data-dir")
    }
    if profile.isolationOwnership.codexHome != .generated,
      hasCodexHomeConfigured(in: profile)
    {
      configuredKinds.append("CODEX_HOME")
    }
    return configuredKinds.isEmpty
      ? .notConfigured
      : .configurationOnly(configuredPaths: configuredKinds)
  }

  func canMutateLibrary() -> Bool {
    guard !isProfileDataOperationRunning else {
      errorMessage = String(
        localized:
          "Wait for the current profile data operation to finish."
      )
      return false
    }
    guard case .loaded = loadState else {
      errorMessage = String(
        localized: "The library is read-only until its load or recovery problem is resolved."
      )
      return false
    }
    guard migrationRequiredLibrary == nil else {
      errorMessage = String(
        localized: "This legacy library is read-only until its profile data is migrated."
      )
      return false
    }
    return true
  }

  func revealManagedFolder(_ path: any ManagedMutationPath) -> Bool {
    do {
      let target = path.url.standardizedFileURL
      let revealURL: URL
      if fileSystem.fileExists(at: target) {
        let attributes = try fileSystem.attributesOfItem(at: target)
        guard attributes.kind == .directory else {
          throw ManagedPathError(.targetNotDirectory, path: target.path)
        }
        revealURL = target
      } else {
        var parent = target.deletingLastPathComponent()
        while !fileSystem.fileExists(at: parent),
          parent.path != "/"
        {
          parent.deleteLastPathComponent()
        }
        guard fileSystem.fileExists(at: parent) else {
          throw ManagedPathError(.baseRootUnavailable, path: target.path)
        }
        revealURL = parent
        launchStatusMessage = String(
          localized: "The managed folder does not exist. Revealed its nearest existing parent."
        )
      }
      NSWorkspace.shared.activateFileViewerSelecting([revealURL])
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func revealExternalFolder(_ path: ExternalIsolationPath) -> Bool {
    guard isDirectory(at: path.url) else {
      errorMessage = String(localized: "The external isolation folder does not exist.")
      return false
    }
    NSWorkspace.shared.activateFileViewerSelecting([path.url])
    return true
  }

  func archiveProfileData(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) throws -> ManagedArchiveEntryPath? {
    let paths = try managedPaths(for: application, profile: profile)
    guard fileSystem.fileExists(at: paths.profileRoot.url) else { return nil }
    return try moveToArchive(
      source: paths.profileRoot,
      archiveRoot: paths.archiveRoot
    )
  }

  func deleteProfileData(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) throws {
    let profileRoot = try managedPaths(
      for: application,
      profile: profile
    ).profileRoot
    guard fileSystem.fileExists(at: profileRoot.url) else { return }
    try removeManagedItem(at: profileRoot)
  }

  func defaultProfile(for application: ManagedApplication) throws -> LaunchProfile {
    let preset = Self.resolvedPreset(for: application)

    if preset.supportsUserDataDir {
      var profile = LaunchProfile(
        name: String(localized: "Personal")
      )
      let paths = try managedPaths(for: application, profile: profile)
      profile.argumentsText = ShellWordsParser.quote(
        "--user-data-dir=\(paths.userData.url.path)"
      )
      profile.environmentText =
        preset.needsCodexHome
        ? "CODEX_HOME=\(paths.codexHome.url.path)"
        : ""
      profile.isolationOwnership.userData = .generated
      if preset.needsCodexHome {
        profile.isolationOwnership.codexHome = .generated
      }
      return profile
    }

    return LaunchProfile(
      name: String(localized: "Default")
    )
  }

  func continueMergeImport() throws {
    guard let pending = pendingLibraryImport else { return }
    try validatePendingImportVersion(pending)
    let existing = applications.map {
      LibraryImportApplication(
        application: $0,
        canonicalApplicationPath: URL(
          fileURLWithPath: $0.appPath
        ).standardizedFileURL.path
      )
    }
    let result = try LibraryImportConflictEngine.resolve(
      existing: existing,
      imported: pending.canonicalApplications,
      resolutions: pendingImportResolutions
    )
    if let conflict = result.conflicts.first(where: {
      result.unresolvedConflictIDs.contains($0.id)
    }) {
      pendingImportConflict = conflict
      isShowingImportConflictResolution = true
      return
    }
    guard let candidate = result.applications else {
      throw LibraryImportStoreError.unresolvedConflict
    }
    let selectedApplication = candidate.first?.id
    let selectedProfile = candidate.first?.profiles.first?.id
    guard
      commit(
        candidate,
        selectedApplicationID: selectedApplication,
        selectedProfileID: selectedProfile
      )
    else {
      return
    }
    finishImport()
    launchStatusMessage = String(localized: "Imported library metadata")
  }

  func validatePendingImportVersion(
    _ pending: PendingLibraryImport
  ) throws {
    guard pending.expectedVersion == libraryVersionToken else {
      finishImport()
      throw LibraryImportStoreError.staleImportSession
    }
  }

  func finishImport() {
    pendingLibraryImport = nil
    pendingImportResolutions = [:]
    pendingImportConflict = nil
    pendingImportSummary = nil
    isShowingImportChoice = false
    isShowingImportConflictResolution = false
  }

  func encodedImportApplications(
    _ applications: [ManagedApplication]
  ) throws -> Data {
    try encodedImportDocument(
      LibraryDocument(applications: applications)
    )
  }

  func encodedImportDocument(
    _ document: LibraryDocument
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(document)
  }

  func keepBothResolution(
    for conflict: LibraryImportConflict,
    pending: PendingLibraryImport
  ) throws -> LibraryImportConflictResolution {
    if conflict.scope == .application {
      guard
        let application = pending.applications.first(where: {
          $0.id == conflict.importedApplicationID
        })
      else {
        throw LibraryImportStoreError.unresolvedConflict
      }
      let occupiedNames = Set(
        applications.map {
          Self.normalizedImportName($0.displayName)
        }
      ).union(
        pendingImportResolutions.values.compactMap {
          guard
            case .keepBoth(.application(let name, _)) = $0
          else { return nil }
          return Self.normalizedImportName(name)
        }
      )
      guard let rename = Self.uniqueImportedName(
        application.displayName,
        occupied: occupiedNames
      ) else {
        throw GeneratedDisplayNameError.importedCopyUnavailable
      }
      let identities = Dictionary(
        uniqueKeysWithValues: application.profiles.map {
          (
            $0.id,
            LibraryImportFreshProfileIdentity(
              id: UUID(),
              storageID: UUID()
            )
          )
        }
      )
      return .keepBoth(
        .application(
          renamedTo: rename,
          identity: LibraryImportFreshApplicationIdentity(
            id: UUID(),
            storageID: UUID(),
            profileIdentities: identities
          )
        )
      )
    }
    guard
      let importedProfileID = conflict.importedProfileID,
      let profile = pending.applications
        .flatMap(\.profiles)
        .first(where: { $0.id == importedProfileID })
    else {
      throw LibraryImportStoreError.unresolvedConflict
    }
    let occupiedNames = Set(
      applications.flatMap(\.profiles).map {
        Self.normalizedImportName($0.name)
      }
    ).union(
      pendingImportResolutions.values.compactMap {
        guard
          case .keepBoth(.profile(let name, _)) = $0
        else { return nil }
        return Self.normalizedImportName(name)
      }
    )
    guard let rename = Self.uniqueImportedName(
      profile.name,
      occupied: occupiedNames
    ) else {
      throw GeneratedDisplayNameError.importedCopyUnavailable
    }
    return .keepBoth(
      .profile(
        renamedTo: rename,
        identity: LibraryImportFreshProfileIdentity(
          id: UUID(),
          storageID: UUID()
        )
      )
    )
  }

  static func uniqueImportedName(
    _ base: String,
    occupied: Set<String>
  ) -> String? {
    uniqueGeneratedDisplayName(
      basedOn: base,
      requiredSuffix:
        " \(String(localized: "Imported"))",
      occupied: occupied
    )
  }

  static func normalizedImportName(_ value: String) -> String {
    DisplayNameValidator.collisionKey(value)
  }

  static func resolvedPreset(for application: ManagedApplication) -> AppPreset {
    application.preset == .automatic
      ? AppPreset.detected(
        displayName: application.displayName, bundleIdentifier: application.bundleIdentifier)
      : application.preset
  }

  func configuredBaseRoot(for application: ManagedApplication) -> String {
    let trimmed = application.baseStoragePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? Self.defaultProfilesRootPath : application.baseStoragePath ?? ""
  }

  func profile(
    named name: String,
    template: ProfileTemplate?,
    for application: ManagedApplication
  ) throws -> LaunchProfile {
    var profile = LaunchProfile(
      name: name,
      argumentsText: template?.argumentsText ?? "",
      environmentText: template?.environmentText ?? "",
      notes: template?.notes ?? ""
    )
    profile = try applyingRecommendedSettings(
      to: profile,
      for: application
    )
    return profile
  }

  func applyingRecommendedSettings(
    to profile: LaunchProfile,
    for application: ManagedApplication,
    replacingExistingIsolation: Bool = false
  ) throws -> LaunchProfile {
    var migratedProfile = profile

    let preset = Self.resolvedPreset(for: application)
    let paths = try managedPaths(for: application, profile: migratedProfile)

    if preset.needsCodexHome,
      replacingExistingIsolation || Self.environmentValue("CODEX_HOME", in: profile) == nil
    {
      migratedProfile.environmentText = Self.settingEnvironmentValue(
        "CODEX_HOME",
        to: paths.codexHome.url.path,
        in: migratedProfile.environmentText
      )
      migratedProfile.isolationOwnership.codexHome = .generated
    }

    if preset.supportsUserDataDir,
      replacingExistingIsolation || Self.userDataDirectoryArgumentValue(in: profile) == nil
    {
      migratedProfile.argumentsText = Self.settingArgument(
        named: "--user-data-dir",
        to: paths.userData.url.path,
        in: migratedProfile.argumentsText
      )
      migratedProfile.isolationOwnership.userData = .generated
    }

    return migratedProfile
  }

  static func nextProfileName(for application: ManagedApplication?, templates: [String]) -> String {
    guard let application else {
      return String(localized: "New Space")
    }
    let existingNames = Set(application.profiles.map(\.name))

    if let templateName = templates.first(where: { !existingNames.contains($0) }) {
      return templateName
    }

    var index = 2
    while existingNames.contains(
      String(localized: "Space \(index)")
    ) {
      index += 1
    }
    return String(localized: "Space \(index)")
  }

  static func uniqueProfileName(
    basedOn name: String,
    existingProfiles: [LaunchProfile]
  ) -> String? {
    uniqueProfileName(
      basedOn: name,
      requiredSuffix: "",
      existingProfiles: existingProfiles
    )
  }

  private static func uniqueProfileName(
    basedOn name: String,
    requiredSuffix: String,
    existingProfiles: [LaunchProfile]
  ) -> String? {
    let occupied = Set(
      existingProfiles.map {
        DisplayNameValidator.collisionKey($0.name)
      }
    )
    return uniqueGeneratedDisplayName(
      basedOn: name,
      requiredSuffix: requiredSuffix,
      occupied: occupied
    )
  }

  private static func uniqueGeneratedDisplayName(
    basedOn name: String,
    requiredSuffix: String,
    occupied: Set<String>
  ) -> String? {
    guard
      let normalizedBase = DisplayNameValidator.normalized(
        name,
        maximumUTF8Bytes: .max
      )
    else {
      return nil
    }
    if let candidate = fittedProfileName(
      base: normalizedBase,
      suffix: requiredSuffix
    ), !occupied.contains(
      DisplayNameValidator.collisionKey(candidate)
    ) {
      return candidate
    }

    // At most one existing record can occupy each deterministic numeric
    // suffix, so count + 2 is a bounded collision-free search.
    for index in 2...(occupied.count + 2) {
      guard let candidate = fittedProfileName(
        base: normalizedBase,
        suffix: "\(requiredSuffix) \(index)"
      ) else {
        return nil
      }
      if !occupied.contains(
        DisplayNameValidator.collisionKey(candidate)
      ) {
        return candidate
      }
    }
    return nil
  }

  static func duplicateProfileName(
    basedOn sourceName: String,
    existingProfiles: [LaunchProfile]
  ) -> String? {
    let source = DisplayNameValidator.normalized(
      sourceName,
      maximumUTF8Bytes: .max
    )
    let copySuffix = " \(String(localized: "Copy"))"
    if let source,
      let generated = uniqueProfileName(
        basedOn: source,
        requiredSuffix: copySuffix,
        existingProfiles: existingProfiles
      )
    {
      return generated
    }
    return uniqueProfileName(
      basedOn: String(localized: "Space"),
      requiredSuffix: copySuffix,
      existingProfiles: existingProfiles
    )
  }

  private static func fittedProfileName(
    base: String,
    suffix: String
  ) -> String? {
    let byteLimit = DisplayNameValidator.maximumUTF8Bytes
    let suffixBytes = suffix.utf8.count
    guard suffixBytes < byteLimit else { return nil }

    var prefix = ""
    var prefixBytes = 0
    for character in base {
      let fragment = String(character)
      let fragmentBytes = fragment.utf8.count
      guard prefixBytes + fragmentBytes + suffixBytes
        <= byteLimit
      else { break }
      prefix.append(character)
      prefixBytes += fragmentBytes
    }
    let trimmedPrefix = prefix.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmedPrefix.isEmpty else { return nil }
    return DisplayNameValidator.normalized(
      trimmedPrefix + suffix
    )
  }

  func matchesApplication(
    _ application: ManagedApplication,
    appPath: String,
    bundleIdentifier: String?
  ) -> Bool {
    if let bundleIdentifier,
      !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      application.bundleIdentifier == bundleIdentifier
    {
      return true
    }

    return normalizedApplicationPath(application.appPath) == normalizedApplicationPath(appPath)
  }

  func normalizedApplicationPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    return (try? fileSystem.canonicalURL(for: url))?.path
      ?? url.standardizedFileURL.path
  }

  static func appendingEnvironmentLine(_ line: String, to text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? line : "\(trimmed)\n\(line)"
  }

  static func appendingArgument(_ argument: String, to text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? argument : "\(trimmed) \(argument)"
  }

  static func settingEnvironmentValue(_ key: String, to value: String, in text: String) -> String {
    var didReplace = false
    let lines = text.split(whereSeparator: \.isNewline).map { line -> String in
      let string = String(line)
      guard environmentKey(in: string) == key else { return string }
      didReplace = true
      return "\(key)=\(value)"
    }
    let updated = lines.joined(separator: "\n")
    return didReplace ? updated : appendingEnvironmentLine("\(key)=\(value)", to: text)
  }

  static func settingArgument(named name: String, to value: String, in text: String) -> String {
    let replacement = "\(name)=\(value)"
    var didReplace = false
    let arguments = ShellWordsParser.parse(text).map { argument -> String in
      guard argument.hasPrefix("\(name)=") else { return argument }
      didReplace = true
      return replacement
    }

    if didReplace {
      return arguments.map(ShellWordsParser.quote).joined(separator: " ")
    }

    return appendingArgument(ShellWordsParser.quote(replacement), to: text)
  }

  static func environmentKey(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
    guard let separator = trimmed.firstIndex(of: "=") else { return nil }

    let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
    return key.isEmpty ? nil : key
  }

  nonisolated static func environmentValue(
    _ key: String,
    in profile: LaunchProfile
  ) -> String? {
    guard
      let value = LaunchEnvironmentParser.parse(
        profile.environmentText
      ).effectiveValues[key],
      !value.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
    else { return nil }
    return value
  }

  nonisolated static func userDataDirectoryArgumentValue(
    in profile: LaunchProfile
  ) -> String? {
    userDataDirectoryResolution(
      in: profile.argumentsText
    ).resolvedValue
  }

  nonisolated static func userDataDirectoryResolution(
    in text: String
  ) -> UserDataDirectoryResolution {
    let parsed = LaunchArgumentParser.parse(text)
    let resolution = UserDataDirectoryOptionResolver.resolve(
      in: parsed.tokens
    )
    return UserDataDirectoryResolution(
      occurrences: resolution.occurrences,
      diagnostics:
        parsed.diagnostics + resolution.diagnostics
    )
  }

  static func userDataDirectoryConfiguration(
    in text: String
  ) -> IsolationOptionConfiguration {
    let parsed = LaunchArgumentParser.parse(text)
    let resolution = UserDataDirectoryOptionResolver.resolve(
      in: parsed.tokens
    )
    return IsolationOptionConfiguration(
      occurrences: resolution.occurrences.map {
        "\($0.form.rawValue):\($0.value)"
      },
      diagnosticCodes: resolution.diagnostics.map(\.code)
    )
  }

  static func environmentConfiguration(
    _ key: String,
    in text: String
  ) -> LaunchEnvironmentOperation? {
    LaunchEnvironmentParser.parse(text).effectiveOperations[key]
  }

  func profileHealthInput(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> ProfileHealthInput {
    let expander = PathSpecificTildeExpander(
      homeDirectory:
        FileManager.default.homeDirectoryForCurrentUser.path
    )
    var isolationPaths: [ProfileIsolationHealthInput] = []
    switch profile.isolationOwnership.userData {
    case .generated:
      isolationPaths.append(
        ProfileIsolationHealthInput(
          role: .managedUserData,
          source: .managedUserData
        )
      )
    case .explicit, .legacyUnknown:
      if let configured =
        Self
        .userDataDirectoryArgumentValue(in: profile)
      {
        isolationPaths.append(
          ProfileIsolationHealthInput(
            role: .externalUserData,
            source: .external(
              expander.argumentValue(
                configured,
                forOption: "--user-data-dir"
              )
            )
          )
        )
      }
    }
    switch profile.isolationOwnership.codexHome {
    case .generated:
      isolationPaths.append(
        ProfileIsolationHealthInput(
          role: .managedCodexHome,
          source: .managedCodexHome
        )
      )
    case .explicit, .legacyUnknown:
      if let configured = Self.environmentValue(
        "CODEX_HOME",
        in: profile
      ) {
        isolationPaths.append(
          ProfileIsolationHealthInput(
            role: .externalCodexHome,
            source: .external(
              expander.environmentValue(
                configured,
                forKey: "CODEX_HOME"
              )
            )
          )
        )
      }
    }
    return ProfileHealthInput(
      applicationID: application.id,
      profileID: profile.id,
      applicationStorageID: application.storageID,
      profileStorageID: profile.storageID,
      configuredBaseRoot: configuredBaseRoot(for: application),
      isolationPaths: isolationPaths
    )
  }

  func healthInspectionSource(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> HealthInspectionSource {
    HealthInspectionSource(
      application: application,
      profile: profile,
      preset: Self.resolvedPreset(for: application),
      applicationInput: ApplicationHealthInput(
        applicationID: application.id,
        applicationURL: URL(fileURLWithPath: application.appPath),
        expectedBundleIdentifier: application.bundleIdentifier
      ),
      profileInputs: application.profiles.map {
        profileHealthInput(for: application, profile: $0)
      }
    )
  }

  nonisolated static func isHealthyPath(
    _ path: ProfileHealthPathReport
  ) -> Bool {
    path.state == .existingDirectory
      || path.state == .missingCreatable
  }

  func moveToArchive(
    source: ManagedProfileRootPath,
    archiveRoot: ManagedArchiveRootPath
  ) throws -> ManagedArchiveEntryPath {
    var destination = archiveRoot.entry()
    while fileSystem.fileExists(at: destination.url) {
      destination = archiveRoot.entry()
    }
    let archiveDirectoryURL = try pathResolver.revalidateForMutation(archiveRoot)
    try fileSystem.createDirectory(
      at: archiveDirectoryURL,
      withIntermediateDirectories: true
    )
    try moveManagedItem(at: source, to: destination)
    return destination
  }

  func removeManagedItem(at path: any ManagedMutationPath) throws {
    let url = try pathResolver.revalidateForMutation(path)
    try fileSystem.removeItem(at: url)
  }

  func copyManagedItem(
    at source: any ManagedMutationPath,
    to destination: any ManagedMutationPath
  ) throws {
    let sourceURL = try pathResolver.revalidateForMutation(source)
    let destinationURL = try pathResolver.revalidateForMutation(destination)
    try fileSystem.copyItem(at: sourceURL, to: destinationURL)
  }

  func moveManagedItem(
    at source: any ManagedMutationPath,
    to destination: any ManagedMutationPath
  ) throws {
    let sourceURL = try pathResolver.revalidateForMutation(source)
    let destinationURL = try pathResolver.revalidateForMutation(destination)
    try fileSystem.moveItem(at: sourceURL, to: destinationURL)
  }

  static let launchTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
  }()

  struct PendingLibraryImport {
    let sourceSHA256: String
    let expectedVersion: LibraryVersionToken?
    let applications: [ManagedApplication]
    let canonicalApplications: [LibraryImportApplication]
    let warnings: [String]
  }

  struct PendingImportedLaunch {
    let applicationID: UUID
    let profileID: UUID
    let review: ImportedLaunchReview
  }

  struct PendingLaunchDiagnosticRequest {
    let source: LaunchConfigurationSource
    let profileName: String
    let fingerprint: LaunchConfigurationFingerprint
    let diagnostics: [LaunchCompilerDiagnostic]
  }

  struct PendingConcurrentLaunchRequest {
    let source: LaunchConfigurationSource
    let profileName: String
    let fingerprint: LaunchConfigurationFingerprint
  }

  struct IsolationOptionConfiguration: Equatable {
    let occurrences: [String]
    let diagnosticCodes: [LaunchParsingDiagnosticCode]
  }

  struct HealthCacheKey: Hashable {
    let application: ManagedApplication
    let profileID: UUID
  }

  struct HealthInspectionSource: Sendable {
    let application: ManagedApplication
    let profile: LaunchProfile
    let preset: AppPreset
    let applicationInput: ApplicationHealthInput
    let profileInputs: [ProfileHealthInput]
  }
}
