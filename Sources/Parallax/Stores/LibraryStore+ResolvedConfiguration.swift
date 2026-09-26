import Foundation

// MARK: - Resolved launch configuration

extension LibraryStore {
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
