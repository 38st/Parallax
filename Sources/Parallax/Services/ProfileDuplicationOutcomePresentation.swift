import Foundation

enum ProfileDuplicationOutcomePresentation {
  static func message(
    for outcome: ProfileDataTransactionOutcome,
    profileName: String
  ) -> String {
    let hasExternalConfiguration: Bool
    if case .configurationOnly = outcome.externalDataHandling {
      hasExternalConfiguration = true
    } else {
      hasExternalConfiguration = false
    }

    return switch (outcome.dataMutation, hasExternalConfiguration) {
    case (.copiedManagedData, true):
      String(
        localized:
          "Copied managed profile data to \(profileName). Explicit external data locations were not copied."
      )
    case (.copiedManagedData, false):
      String(
        localized: "Copied managed profile data to \(profileName)."
      )
    case (.noManagedData, true):
      String(
        localized:
          "Duplicated the configuration as \(profileName). No managed data existed to copy, and explicit external data locations were not copied."
      )
    case (.noManagedData, false):
      String(
        localized:
          "Duplicated the configuration as \(profileName). No managed data existed to copy."
      )
    default:
      String(
        localized:
          "Duplicated the profile configuration as \(profileName)."
      )
    }
  }
}
