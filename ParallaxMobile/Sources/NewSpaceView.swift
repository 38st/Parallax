import SwiftUI

struct NewSpaceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpaceStore

    @State private var name = ""
    @State private var service: WebSpace.Service = .instagram
    @State private var urlText = WebSpace.Service.instagram.defaultURL.absoluteString

    var body: some View {
        NavigationStack {
            Form {
                Section("Space") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)

                    Picker("Service", selection: $service) {
                        ForEach(WebSpace.Service.allCases) { service in
                            Label(service.title, systemImage: service.systemImage)
                                .tag(service)
                        }
                    }
                    .onChange(of: service) { _, newValue in
                        urlText = newValue.defaultURL.absoluteString
                        if name.isEmpty {
                            name = newValue.title
                        }
                    }
                }

                Section {
                    TextField("https://example.com", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Website")
                } footer: {
                    Text(
                        "Every space receives its own persistent cookies and website storage."
                    )
                }
            }
            .navigationTitle("New Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createSpace()
                    }
                    .disabled(validatedURL == nil || trimmedName.isEmpty)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        guard
            let url = URL(string: urlText),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            return nil
        }
        return url
    }

    private func createSpace() {
        guard let url = validatedURL else { return }
        store.add(
            WebSpace(
                name: trimmedName,
                service: service,
                startURL: url
            )
        )
        dismiss()
    }
}
