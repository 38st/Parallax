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
    text.isEmpty || text.utf8.last == 0x0a ? text + line : "\(text)\n\(line)"
  }

  static func appendingArgument(_ argument: String, to text: String) -> String {
    text.isEmpty ? argument : "\(text) \(argument)"
  }

  static func settingEnvironmentValue(_ key: String, to value: String, in text: String) -> String {
    let replacement = "\(key)=\(value)"
    let proposed = LaunchEnvironmentParser.parse(replacement)
    let parsed = LaunchEnvironmentParser.parse(text)
    guard !proposed.hasErrors,
      proposed.entries.count == 1,
      proposed.entries.first?.name == key,
      proposed.entries.first?.operation == .set(value)
    else { return text }
    let matches = parsed.entries.filter { $0.name == key }
    guard !matches.isEmpty else {
      return appendingEnvironmentLine(replacement, to: text)
    }
    let updated = NSMutableString(string: text)
    for entry in matches.reversed() {
      updated.replaceCharacters(
        in: NSRange(
          location: entry.range.start.utf16Offset,
          length: entry.range.end.utf16Offset - entry.range.start.utf16Offset
        ),
        with: replacement
      )
    }
    return updated as String
  }

  static func settingArgument(named name: String, to value: String, in text: String) -> String {
    let parsed = LaunchArgumentParser.parse(text)
    guard !parsed.hasErrors else { return text }
    let replacement = ShellWordsParser.quote("\(name)=\(value)")
    if name == "--user-data-dir" {
      let resolution = UserDataDirectoryOptionResolver.resolve(in: parsed.tokens)
      guard resolution.occurrences.count <= 1 else { return text }
      if let occurrence = resolution.occurrences.first {
        let updated = NSMutableString(string: text)
        let end = occurrence.valueRange?.end ?? occurrence.optionRange.end
        updated.replaceCharacters(
          in: NSRange(
            location: occurrence.optionRange.start.utf16Offset,
            length: end.utf16Offset - occurrence.optionRange.start.utf16Offset
          ),
          with: replacement
        )
        return updated as String
      }
    }
    let matches = parsed.tokens.prefix { $0.value != "--" }.filter {
      $0.value.hasPrefix("\(name)=")
    }
    if !matches.isEmpty {
      let updated = NSMutableString(string: text)
      for token in matches.reversed() {
        updated.replaceCharacters(
          in: NSRange(
            location: token.range.start.utf16Offset,
            length: token.range.end.utf16Offset - token.range.start.utf16Offset
          ),
          with: replacement
        )
      }
      return updated as String
    }
    if let terminator = parsed.tokens.first(where: { $0.value == "--" }) {
      let updated = NSMutableString(string: text)
      updated.insert(replacement + " ", at: terminator.range.start.utf16Offset)
      return updated as String
    }
    return appendingArgument(replacement, to: text)
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
      diagnosticCodes: (parsed.diagnostics + resolution.diagnostics).map(\.code)
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
