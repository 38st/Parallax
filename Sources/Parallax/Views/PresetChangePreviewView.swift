import SwiftUI

struct PresetChangePreviewView: View {
    let preview: PresetChangePreview
    let applyMetadataOnly: () -> Void
    let applyAndRefresh: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Preset Change")
                .font(.title2.bold())

            Text(
                "Changing the app type does not silently rewrite space configuration. Review the generated-value plan, then choose whether to change metadata only or intentionally refresh the listed generated values."
            )
            .foregroundStyle(.secondary)

            List(
                Array(preview.changes.enumerated()),
                id: \.offset
            ) { _, change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.profileName)
                        .font(.headline)
                    Text(
                        "\(label(for: change.kind)): \(label(for: change.disposition))"
                    )
                    .font(.subheadline)
                    if change.priorOwnership != .generated {
                        Text(
                            "Explicit or legacy-ambiguous value retained."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if preview.changes.isEmpty {
                Text("No generated space values would change.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Spacer()
                Button(
                    "Change Preset Only",
                    action: applyMetadataOnly
                )
                Button(
                    "Change and Refresh Generated Values",
                    action: applyAndRefresh
                )
                .buttonStyle(.borderedProminent)
                .disabled(preview.changes.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 420)
    }

    private func label(
        for kind: PresetGeneratedValueKind
    ) -> String {
        switch kind {
        case .userDataDirectory:
            String(localized: "User data directory")
        case .codexHome:
            String(localized: "Codex home")
        }
    }

    private func label(
        for disposition: PresetGeneratedValueDisposition
    ) -> String {
        switch disposition {
        case .added:
            String(localized: "Will be added")
        case .changed:
            String(localized: "Will be changed")
        case .retained:
            String(localized: "Will be retained")
        case .removed:
            String(localized: "Will be removed")
        }
    }
}
