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
    }
}
