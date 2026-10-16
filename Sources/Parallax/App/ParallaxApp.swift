import AppKit
import SwiftUI

@main
struct ParallaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() { LaunchPlanner.dropInheritedIdentity() }

    var body: some Scene {
        Window("Parallax", id: "main") {
            ContentView(model: delegate.model).frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 700)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.quitRequested() ? .terminateLater : .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
