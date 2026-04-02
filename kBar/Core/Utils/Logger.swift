import Foundation

enum Logger {
    static func info(_ message: String) {
        NSLog("[kBar] %@", message)
        DiagnosticsFileLogger.appendRuntimeLog(level: "info", message: message)
    }

    static func error(_ message: String) {
        NSLog("[kBar][Error] %@", message)
        DiagnosticsFileLogger.appendRuntimeLog(level: "error", message: message)
    }
}
