import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditorEnvironmentPreviewLine: Equatable {
  let text: String
  let isSensitive: Bool
  let isRevealable: Bool
}

struct ProfileEditorEnvironmentSensitivityOption: Equatable {
  let key: String
  let isKeychainReference: Bool
  let isAutomaticallySensitive: Bool
}

enum ProfileEditorSecurityPresentation {
  static func argumentPreview(for text: String) -> [String] {
    let tokens = LaunchArgumentParser.parse(text).tokens
    let redacted = SensitiveLaunchArgumentPolicy().redactedWords(
      in: tokens
    )
    return redacted.enumerated().map { index, value in
      if EnvironmentSecretReference(
        token: tokens[index].value
      ) != nil {
        return String(
          localized: "<redacted Keychain reference>"
        )
      }
      return value
    }
  }

  static func environmentPreview(
    for text: String,
    explicitSensitiveKeys: Set<String>,
    revealSensitiveLiterals: Bool,
    childEnvironmentPolicy: ChildEnvironmentPolicy? = nil,
    identity: ChildEnvironmentIdentity = .current,
    processEnvironment: [String: String] =
      ProcessInfo.processInfo.environment
  ) -> [ProfileEditorEnvironmentPreviewLine] {
    let parsed = LaunchEnvironmentParser.parse(text)
    let policy = EnvironmentDisclosurePolicy(
      explicitSensitiveKeys: explicitSensitiveKeys
    )

    if let childEnvironmentPolicy {
      var effective = childEnvironmentPolicy.baseEnvironment(
        processEnvironment: processEnvironment,
        identity: identity
      ).mapValues { StoredEnvironmentValue.literal($0) }
      let expander = PathSpecificTildeExpander(
        homeDirectory: identity.homeDirectory
      )
      for entry in parsed.entries {
        switch entry.operation {
        case .set(let storedText):
          effective[entry.name] = StoredEnvironmentValue(
            storedText: expander.environmentValue(
              storedText,
              forKey: entry.name
            )
          )
        case .unset:
          effective.removeValue(forKey: entry.name)
        }
      }
      return effective.keys.sorted().compactMap { key in
        guard let storedValue = effective[key] else { return nil }
        return previewLine(
          key: key,
          storedValue: storedValue,
          policy: policy,
          revealSensitiveLiterals: revealSensitiveLiterals
        )
      }
    }

    return parsed.entries.map { entry in
      switch entry.operation {
      case .unset:
        return ProfileEditorEnvironmentPreviewLine(
          text: "unset \(entry.name)",
          isSensitive: false,
          isRevealable: false
        )

      case .set(let storedText):
        let storedValue = StoredEnvironmentValue(
          storedText: storedText
        )
        return previewLine(
          key: entry.name,
          storedValue: storedValue,
          policy: policy,
          revealSensitiveLiterals: revealSensitiveLiterals
        )
      }
    }
  }

  static func previewLine(
    key: String,
    storedValue: StoredEnvironmentValue,
    policy: EnvironmentDisclosurePolicy,
    revealSensitiveLiterals: Bool
  ) -> ProfileEditorEnvironmentPreviewLine {
    let assignment = StoredEnvironmentAssignment(
      key: key,
      value: storedValue
    )
    guard
      let preview = policy.preview(
        [assignment],
        revealSensitiveLiterals: revealSensitiveLiterals
      ).first
    else {
      return ProfileEditorEnvironmentPreviewLine(
        text: "\(key)=<redacted>",
        isSensitive: true,
        isRevealable: false
      )
    }
    let displayValue: String
    switch preview.displayValue {
    case .plain(let value):
      displayValue = value
    case .redacted:
      displayValue = String(localized: "<redacted>")
    }
    let isKeychainReference: Bool
    if case .secretReference = storedValue {
      isKeychainReference = true
    } else {
      isKeychainReference = false
    }
    return ProfileEditorEnvironmentPreviewLine(
      text: "\(key)=\(displayValue)",
      isSensitive: preview.isSensitive,
      isRevealable: preview.isSensitive && !isKeychainReference
    )
  }

  static func environmentSensitivityOptions(
    for text: String
  ) -> [ProfileEditorEnvironmentSensitivityOption] {
    let parsed = LaunchEnvironmentParser.parse(text)
    var effectiveValues: [String: StoredEnvironmentValue] = [:]
    for entry in parsed.entries {
      switch entry.operation {
      case .set(let storedText):
        effectiveValues[entry.name] = StoredEnvironmentValue(
          storedText: storedText
        )
      case .unset:
        effectiveValues.removeValue(forKey: entry.name)
      }
    }
    let automaticClassifier = SensitiveEnvironmentKeyClassifier()
    return effectiveValues.keys.sorted().compactMap { key in
      guard let value = effectiveValues[key] else { return nil }
      let isKeychainReference: Bool
      if case .secretReference = value {
        isKeychainReference = true
      } else {
        isKeychainReference = false
      }
      return ProfileEditorEnvironmentSensitivityOption(
        key: key,
        isKeychainReference: isKeychainReference,
        isAutomaticallySensitive: isKeychainReference
          || automaticClassifier.isSensitive(key)
      )
    }
  }

  static func updatingSensitiveKeys(
    _ current: [String],
    key: String,
    isSensitive: Bool
  ) -> [String] {
    var result = Set(current.map { $0.uppercased() })
    let normalizedKey = key.uppercased()
    if isSensitive {
      result.insert(normalizedKey)
    } else {
      result.remove(normalizedKey)
    }
    return result.sorted()
  }

  static func locationDescription(_ range: LaunchSourceRange) -> String {
    let finalColumn = max(range.start.column, range.end.column - 1)
    if range.start.line == range.end.line {
      return String(
        localized: "Line \(range.start.line), columns \(range.start.column)–\(finalColumn)"
      )
    }
    return String(
      localized:
        "Line \(range.start.line), column \(range.start.column) through line \(range.end.line), column \(finalColumn)"
    )
  }
}
