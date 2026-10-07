import AppKit
import SwiftUI

@main
struct ParallaxApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Parallax", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 700)

        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        if let highest = model.accounts.compactMap(\.headline).map(\.percent).max() {
            Text("\(highest)%")
        } else {
            Image(systemName: "gauge.medium")
        }
    }
}
