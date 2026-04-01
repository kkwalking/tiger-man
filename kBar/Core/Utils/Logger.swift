import Foundation

enum Logger {
    static func info(_ message: String) {
        NSLog("[kBar] %@", message)
    }

    static func error(_ message: String) {
        NSLog("[kBar][Error] %@", message)
    }
}
