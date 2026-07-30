import Foundation

struct WebSpace: Codable, Hashable, Identifiable, Sendable {
    enum Service: String, Codable, CaseIterable, Identifiable, Sendable {
        case instagram
        case chatGPT
        case custom

        var id: Self { self }

        var title: String {
            switch self {
            case .instagram: "Instagram"
            case .chatGPT: "ChatGPT"
            case .custom: "Website"
            }
        }

        var systemImage: String {
            switch self {
            case .instagram: "camera.aperture"
            case .chatGPT: "bubble.left.and.sparkles"
            case .custom: "globe"
            }
        }

        var defaultURL: URL {
            switch self {
            case .instagram:
                URL(string: "https://www.instagram.com/")!
            case .chatGPT:
                URL(string: "https://chatgpt.com/")!
            case .custom:
                URL(string: "https://example.com/")!
            }
        }
    }

    let id: UUID
    var name: String
    var service: Service
    var startURL: URL
    let dataStoreID: UUID

    init(
        id: UUID = UUID(),
        name: String,
        service: Service,
        startURL: URL? = nil,
        dataStoreID: UUID = UUID()
    ) {
        self.id = id
        self.name = name
        self.service = service
        self.startURL = startURL ?? service.defaultURL
        self.dataStoreID = dataStoreID
    }
}

extension WebSpace {
    static func starterSpaces() -> [WebSpace] {
        [
            WebSpace(name: "Instagram Personal", service: .instagram),
            WebSpace(name: "Instagram Work", service: .instagram),
            WebSpace(name: "ChatGPT Personal", service: .chatGPT),
            WebSpace(name: "ChatGPT Work", service: .chatGPT),
        ]
    }
}

