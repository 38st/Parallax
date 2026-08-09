import SwiftUI

struct FixtureView: View {
    let name: String
    let maximumUTF8Bytes: Int

    var body: some View {
        VStack {
            Text("Ready")
            Text(String(localized: "Welcome"))
            Label("Profile", systemImage: "person")
            Text(String(localized: "Hello \(name)"))
            Text(
                String(
                    localized:
                        "Names must be \(maximumUTF8Bytes) UTF-8 bytes or fewer."
                )
            )
            Text(#"Raw \#(name)"#)
            Text(
                """
                Multiline \(name)
                """
            )
            Text(LocalizedStringKey("Explicit key"))
            Text(LocalizedStringResource("Resource key"))
            Text(String(localized: "item-count"))
            localizedRow("Helper title")
            externalLocalizedRow("External helper title")
            externalLocalizedValueRow(
                code: 1,
                detail: "Localization value helper title"
            )
            Text(verbatim: "Debug only")
            // Text("Commented out")
        }
    }

    private func localizedRow(_ title: LocalizedStringKey) -> some View {
        Text(title)
    }
}
