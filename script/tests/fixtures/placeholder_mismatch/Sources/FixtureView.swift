import SwiftUI

struct FixtureView: View {
    let name: String
    var body: some View { Text(String(localized: "Hello \(name)")) }
}
