import Foundation
import OSLog

/// Unified logging; read with `log show --predicate 'subsystem == "<bundle id>"'`.
public let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.thorsten.clippboard", category: "app")
