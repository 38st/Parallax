import SwiftUI

struct ApplicationIsolationCapabilitiesView: View {
    let application: ManagedApplication
    @State private var policyState = ApplicationCapabilityPolicyState()

    var body: some View {
        let preset = application.preset == .automatic
            ? AppPreset.detected(displayName: application.displayName, bundleIdentifier: application.bundleIdentifier)
            : application.preset
        let policy = policyState.policy(for: application.appPath)
        let capabilities = ApplicationIsolationCapabilities(preset: preset, multipleInstancePolicy: policy ?? .unknown)
        VStack(alignment: .leading, spacing: 8) {
            Text(capabilities.dataSummary)
            if policy != nil {
                Text(capabilities.instanceSummary)
            } else {
                Text("Checking application capabilities…")
            }
            Text("Spaces are not a macOS security boundary. Shared system resources can remain shared.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("application.isolation-capabilities")
        .task(id: application.appPath) {
            let url = URL(fileURLWithPath: application.appPath)
            let result = await Task.detached(priority: .utility) {
                ApplicationIsolationCapabilities.readPolicy(at: url)
            }.value
            guard !Task.isCancelled else { return }
            policyState.record(result, for: url.path)
        }
    }
}

struct AddedApplicationCapabilitiesView: View {
    let application: ManagedApplication
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(application.displayName).font(.title2.bold())
            ApplicationIsolationCapabilitiesView(application: application)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}
