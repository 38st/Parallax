import Foundation
import WebKit

@MainActor
final class SpaceStore: ObservableObject {
    @Published private(set) var spaces: [WebSpace]

    private let defaults: UserDefaults
    private let storageKey = "parallax.web-spaces.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: storageKey),
            let decoded = try? decoder.decode([WebSpace].self, from: data)
        {
            spaces = decoded
        } else {
            spaces = WebSpace.starterSpaces()
            persist()
        }
    }

    func add(_ space: WebSpace) {
        spaces.append(space)
        persist()
    }

    func delete(_ space: WebSpace) {
        spaces.removeAll { $0.id == space.id }
        persist()

        WKWebsiteDataStore.remove(forIdentifier: space.dataStoreID) { error in
            if let error {
                print("Could not remove website data store: \(error)")
            }
        }
    }

    func reset(_ space: WebSpace, completion: @escaping () -> Void = {}) {
        let dataStore = WKWebsiteDataStore(forIdentifier: space.dataStoreID)
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {
            completion()
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(spaces) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

