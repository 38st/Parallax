import AppKit
import CoreFoundation
import Foundation
import os

struct ProviderAuthURLPolicy {
    private static let allowedRegistrableDomains = [
        "openai.com",
        "chatgpt.com",
    ]

    static func validatedCodexURL(_ value: String) -> URL? {
        guard
            value.count <= 8_192,
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            let host = components.host?.lowercased(),
            allowedRegistrableDomains.contains(where: {
                host == $0 || host.hasSuffix(".\($0)")
            }),
            let url = components.url
        else {
            return nil
        }
        return url
    }
}

struct ProviderAuthURLOpener: Sendable {
    private let operation: @MainActor @Sendable (URL) -> Bool

    init(operation: @escaping @MainActor @Sendable (URL) -> Bool) {
        self.operation = operation
    }

    @MainActor
    func open(_ url: URL) -> Bool {
        operation(url)
    }

    static let workspace = ProviderAuthURLOpener { url in
        NSWorkspace.shared.open(url)
    }
}
