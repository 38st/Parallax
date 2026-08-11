import Foundation

// MARK: - Resolved launch configuration

extension LibraryStore {
  func resolvedArguments(for profile: LaunchProfile) -> [String] {
    let parsed = LaunchArgumentParser.parse(profile.argumentsText)
    var arguments = parsed.words
    let resolution = UserDataDirectoryOptionResolver.resolve(
      in: parsed.tokens
    )
    guard let configured = resolution.resolvedValue else {
      return arguments
    }
    let expanded = PathSpecificTildeExpander(
      homeDirectory:
        FileManager.default.homeDirectoryForCurrentUser.path
    ).argumentValue(configured, forOption: "--user-data-dir")
    for index in arguments.indices {
      if arguments[index].hasPrefix("--user-data-dir=") {
        arguments[index] = "--user-data-dir=\(expanded)"
        return arguments
      }
      if arguments[index] == "--user-data-dir",
        arguments.indices.contains(index + 1)
      {
        arguments[index + 1] = expanded
        return arguments
      }
    }
    return arguments
  }

  func resolvedEnvironment(for profile: LaunchProfile) -> [(key: String, value: String)] {
    let entries = LaunchEnvironmentParser.parse(
      profile.environmentText
    ).entries
    var effective: [String: (index: Int, value: String?)] = [:]
    for (index, entry) in entries.enumerated() {
      switch entry.operation {
      case .set(let value):
        effective[entry.name] = (index, value)
      case .unset:
        effective[entry.name] = (index, nil)
      }
    }
    let expander = PathSpecificTildeExpander(
      homeDirectory:
        FileManager.default.homeDirectoryForCurrentUser.path
    )
    return
      effective
      .compactMap { key, indexed -> (key: String, value: String, index: Int)? in
        guard let value = indexed.value else { return nil }
        return (
          key,
          expander.environmentValue(value, forKey: key),
          indexed.index
        )
      }
      .sorted { $0.index < $1.index }
      .map { (key: $0.key, value: $0.value) }
  }
}
