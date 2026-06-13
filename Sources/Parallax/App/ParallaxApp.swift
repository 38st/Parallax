import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ParallaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()

    var body: some Scene {
        WindowGroup("Parallax", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Application") {
                    store.beginAddingApplication()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandMenu("Library") {
                Button("Import Library...") {
                    store.importLibrary()
                }

                Button("Export Library...") {
                    store.exportLibrary()
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}
