import Foundation
import os

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.parallax.Parallax"

    static let general = Logger(subsystem: subsystem, category: "general")
    static let launch = Logger(subsystem: subsystem, category: "launch")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let profiles = Logger(subsystem: subsystem, category: "profiles")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let provider = Logger(subsystem: subsystem, category: "provider")
}
