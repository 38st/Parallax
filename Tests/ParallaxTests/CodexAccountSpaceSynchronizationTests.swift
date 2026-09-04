import Foundation
import XCTest
@testable import Parallax

final class CodexAccountSpaceSynchronizationTests: XCTestCase {
  private var temporaryDirectory = FileManager.default.temporaryDirectory
  private var defaults: UserDefaults?
  private var defaultsSuiteName: String?

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    let suiteName = "parallax.codex-space-sync.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults?.removePersistentDomain(forName: suiteName)
    defaultsSuiteName = suiteName
  }

  override func tearDownWithError() throws {
    if let defaults, let defaultsSuiteName {
      defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
    defaults = nil
    defaultsSuiteName = nil
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  @MainActor
  func testCreatesOneIsolatedSpacePerSignedInCodexAccount() throws {
    let first = account(
      provider: .codex,
      email: "first@example.com",
      isConnected: true
    )
    let second = account(
      provider: .codex,
      email: "second@example.com",
      isConnected: true
    )
    let signedOut = account(
      provider: .codex,
      email: "signed-out@example.com",
      isConnected: false
    )
    let claude = account(
      provider: .claude,
      email: "claude@example.com",
      isConnected: true
    )
    let manual = LaunchProfile(
      name: "first",
      environmentText: "CODEX_HOME=/manual/codex-home"
    )
    let application = ManagedApplication(
      displayName: "ChatGPT",
      bundleIdentifier: "com.openai.codex",
      appPath: "/Applications/ChatGPT.app",
      preset: .automatic,
      baseStoragePath: temporaryDirectory.path,
      profiles: [manual]
    )
    let store = try makeStore(applications: [application])
    let homes = Dictionary(uniqueKeysWithValues: [first, second].map {
      ($0.id, temporaryDirectory
        .appendingPathComponent($0.id.uuidString.lowercased())
        .appendingPathComponent("CodexHome"))
    })

    let created = store.synchronizeCodexAccountSpaces(
      accounts: [first, second, signedOut, claude],
      codexHomeResolver: { try XCTUnwrap(homes[$0]) }
    )

    XCTAssertEqual(created, 2)
    let profiles = try XCTUnwrap(store.applications.first?.profiles)
    XCTAssertEqual(profiles.map(\.name), ["first", "first 2", "second"])
    XCTAssertEqual(profiles.first, manual)
    for account in [first, second] {
      let expectedHome = try XCTUnwrap(homes[account.id])
        .standardizedFileURL
      let profile = try XCTUnwrap(profiles.first(where: {
        LibraryStore.environmentValue("CODEX_HOME", in: $0)
          .map { URL(fileURLWithPath: $0).standardizedFileURL }
          == expectedHome
      }))
      XCTAssertEqual(profile.isolationOwnership.codexHome, .explicit)
      XCTAssertEqual(profile.isolationOwnership.userData, .generated)
      XCTAssertNotNil(
        LibraryStore.userDataDirectoryArgumentValue(in: profile)
      )
    }
  }

  @MainActor
  func testRepeatedSynchronizationAndExistingAccountHomeAreIdempotent()
    throws
  {
    let tracked = account(
      provider: .codex,
      email: "tracked@example.com",
      isConnected: true
    )
    let accountHome = temporaryDirectory
      .appendingPathComponent("AccountHome", isDirectory: true)
    let linked = LaunchProfile(
      name: "My Existing Space",
      environmentText: "CODEX_HOME=\(accountHome.path)"
    )
    let application = ManagedApplication(
      displayName: "Codex",
      appPath: "/Applications/Codex.app",
      preset: .codex,
      baseStoragePath: temporaryDirectory.path,
      profiles: [linked]
    )
    let store = try makeStore(applications: [application])

    XCTAssertEqual(
      store.synchronizeCodexAccountSpaces(
        accounts: [tracked],
        codexHomeResolver: { _ in accountHome }
      ),
      0
    )
    XCTAssertEqual(store.applications.first?.profiles, [linked])

    let newAccount = account(
      provider: .codex,
      email: "new@example.com",
      isConnected: true
    )
    let newHome = temporaryDirectory
      .appendingPathComponent("NewAccountHome", isDirectory: true)
    XCTAssertEqual(
      store.synchronizeCodexAccountSpaces(
        accounts: [tracked, newAccount],
        codexHomeResolver: {
          $0 == tracked.id ? accountHome : newHome
        }
      ),
      1
    )
    XCTAssertEqual(
      store.synchronizeCodexAccountSpaces(
        accounts: [tracked, newAccount],
        codexHomeResolver: {
          $0 == tracked.id ? accountHome : newHome
        }
      ),
      0
    )
    XCTAssertEqual(store.applications.first?.profiles.count, 2)
  }

  @MainActor
  func testDoesNothingWithoutAManagedCodexApplication() throws {
    let tracked = account(
      provider: .codex,
      email: "tracked@example.com",
      isConnected: true
    )
    let application = ManagedApplication(
      displayName: "Notes",
      appPath: "/Applications/Notes.app",
      preset: .custom,
      profiles: []
    )
    let store = try makeStore(applications: [application])
    var resolverCalls = 0

    XCTAssertEqual(
      store.synchronizeCodexAccountSpaces(
        accounts: [tracked],
        codexHomeResolver: { _ in
          resolverCalls += 1
          return self.temporaryDirectory
        }
      ),
      0
    )
    XCTAssertEqual(resolverCalls, 0)
    XCTAssertTrue(store.applications[0].profiles.isEmpty)
  }

  private func account(
    provider: AIProvider,
    email: String,
    isConnected: Bool
  ) -> TrackedAIAccount {
    TrackedAIAccount(
      id: UUID(),
      provider: provider,
      label: provider.displayName,
      email: email,
      planName: "Pro",
      usagePercent: 0,
      resetsAt: Date(timeIntervalSince1970: 10_000),
      lastCheckedAt: Date(timeIntervalSince1970: 9_000),
      isConnected: isConnected,
      lifetimeTokens: nil
    )
  }

  @MainActor
  private func makeStore(
    applications: [ManagedApplication]
  ) throws -> LibraryStore {
    let settings = AppSettings(userDefaults: try XCTUnwrap(defaults))
    settings.defaultBaseStoragePath = temporaryDirectory.path
    return LibraryStore(
      persistence: CodexAccountSpacePersistence(
        applications: applications
      ),
      settings: settings
    )
  }
}

private final class CodexAccountSpacePersistence: LibraryPersisting {
  private var applications: [ManagedApplication]

  init(applications: [ManagedApplication]) {
    self.applications = applications
  }

  func load() throws -> [ManagedApplication] {
    applications
  }

  func loadResult() throws -> LibraryLoadResult {
    .current(applications)
  }

  func save(_ applications: [ManagedApplication]) throws {
    self.applications = applications
  }
}
