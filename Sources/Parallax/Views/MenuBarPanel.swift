import SwiftUI

struct MenuBarPanel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.accounts.isEmpty {
                Text("No usage accounts yet").foregroundStyle(.secondary)
            }
            ForEach(model.accounts) { account in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(account.label).font(.headline)
                        Spacer()
                        Text(account.provider.label).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(account.windows, id: \.title) { UsageBar(window: $0) }
                    if !account.signedIn { Text("Signed out").font(.caption).foregroundStyle(.orange) }
                }
            }
            let open = model.apps.flatMap { app in app.spaces.filter { model.running[$0.id] != nil }.map { (app, $0) } }
            if !open.isEmpty {
                Divider()
                Text("Open now").font(.caption).foregroundStyle(.secondary)
                ForEach(open, id: \.1.id) { app, space in
                    Button("\(app.name) · \(space.name)") { model.show(space.id) }
                        .buttonStyle(.borderless)
                }
            }
            Divider()
            HStack {
                Button("Open Parallax") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
