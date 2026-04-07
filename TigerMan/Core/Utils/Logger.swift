import Foundation

enum Logger {
    static func info(_ message: String) {
        NSLog("[TigerMan] %@", message)
        DiagnosticsFileLogger.appendRuntimeLog(level: "info", message: message)
    }

    static func error(_ message: String) {
        NSLog("[TigerMan][Error] %@", message)
        DiagnosticsFileLogger.appendRuntimeLog(level: "error", message: message)
    }
}
