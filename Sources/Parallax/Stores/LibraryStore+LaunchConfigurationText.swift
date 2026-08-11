import AppKit
import Foundation
import Observation

// MARK: - Launch configuration text

extension LibraryStore {
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


  struct IsolationOptionConfiguration: Equatable {
    let occurrences: [String]
    let diagnosticCodes: [LaunchParsingDiagnosticCode]
  }

}
