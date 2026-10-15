import Foundation
import MIQCore
import OSLog

enum MIQLogger {
    /// See `MIQConfig.logSubsystem` (the extension's bundle identifier).
    static let subsystem = MIQConfig.logSubsystem

    static func make(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
