import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Compatibility") {
                LabeledContent("Launch model", value: "Separate application instances")
                LabeledContent("Best support", value: "Apps with profile or data-directory flags")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
    }
}
