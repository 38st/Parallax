import Foundation

enum ConversationSearch {
    static func results(in library: ConversationLibrary, query: String) -> [LibraryConversation] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return library.conversations.values.filter { conversation in
            guard !conversation.archived else { return false }
            let text = conversation.title + " " + (conversation.revisions[conversation.head]?.workingDirectory ?? "")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted {
            let left = $0.revisions[$0.head]?.lastActivityAt ?? 0
            let right = $1.revisions[$1.head]?.lastActivityAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
    }
}
