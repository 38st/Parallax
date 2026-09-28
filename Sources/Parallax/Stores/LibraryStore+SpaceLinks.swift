import AppKit
import Foundation

struct SpaceLinkRequest: Identifiable {
  let id = UUID()
  let application: ManagedApplication
  let profile: LaunchProfile
  let configuredBaseRoot: String
  let fingerprint: LaunchConfigurationFingerprint

  var message: String {
    String(localized: "A link asked Parallax to open “\(profile.name)” in “\(application.displayName)”. Open this space?")
  }
}

enum SpaceLinkError: LocalizedError {
  case invalid
  case unknownSpace
  case changed

  var errorDescription: String? {
    switch self {
    case .invalid:
      String(localized: "This Parallax link is invalid. Expected parallax://open?space=<space UUID>.")
    case .unknownSpace:
      String(localized: "This link refers to a space that is not in this library.")
    case .changed:
      String(localized: "The linked space changed or was removed. Open the link again to review its current configuration.")
    }
  }
}

enum SpaceLink {
  static func url(profileID: UUID) -> URL? {
    URL(string: "parallax://open?space=\(profileID.uuidString.lowercased())")
  }

  static func profileID(from url: URL) throws -> UUID {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "parallax",
      components.host?.lowercased() == "open",
      components.user == nil, components.password == nil, components.port == nil,
      components.path.isEmpty, components.fragment == nil,
      let items = components.queryItems, items.count == 1,
      items[0].name == "space", let value = items[0].value,
      value.count == 36, let id = UUID(uuidString: value),
      value.lowercased() == id.uuidString.lowercased()
    else { throw SpaceLinkError.invalid }
    return id
  }
}

extension LibraryStore {
  func spaceLinkRequest(for url: URL) throws -> SpaceLinkRequest {
    let id = try SpaceLink.profileID(from: url)
    let matches = applications.flatMap { application in
      application.profiles.filter { $0.id == id }.map { (application, $0) }
    }
    guard matches.count == 1, let (application, profile) = matches.first else {
      throw SpaceLinkError.unknownSpace
    }
    return SpaceLinkRequest(application: application, profile: profile,
                configuredBaseRoot: configuredBaseRoot(for: application),
                fingerprint: recoveryFingerprint(application: application, profile: profile))
  }

  @discardableResult
  func confirmSpaceLink(_ request: SpaceLinkRequest) -> Bool {
    guard let application = applications.first(where: { $0.id == request.application.id }),
      let profile = application.profiles.first(where: { $0.id == request.profile.id }),
      application.displayName == request.application.displayName,
      Self.resolvedPreset(for: application) == Self.resolvedPreset(for: request.application),
      profile.name == request.profile.name,
      configuredBaseRoot(for: application) == request.configuredBaseRoot,
      recoveryFingerprint(application: application, profile: profile) == request.fingerprint
    else {
      errorMessage = SpaceLinkError.changed.localizedDescription
      return false
    }
    if let pending = pendingProfileEditingDraft(applicationID: application.id, profileID: profile.id),
      pending.draft != pending.baseline {
      selectedApplicationID = application.id
      selectedProfileID = profile.id
      errorMessage = String(localized: "This space has unsaved changes. Review them, then use Save & Open so Parallax never opens stale settings.")
      return false
    }
    // The link prompt already confirmed these launch inputs. Keep imported
    // review and normal launch safety checks without asking a second time.
    beginLaunch(profile, application: application, requireGlobalConfirmation: false)
    return true
  }

  func copyLinkToSpace(_ profile: LaunchProfile) {
    guard let url = SpaceLink.url(profileID: profile.id) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }
}
