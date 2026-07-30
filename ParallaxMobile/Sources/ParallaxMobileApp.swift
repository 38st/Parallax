import SwiftUI

@main
struct ParallaxMobileApp: App {
    @StateObject private var store = SpaceStore()

    var body: some Scene {
        WindowGroup {
            SpaceLibraryView()
                .environmentObject(store)
        }
    }
}

