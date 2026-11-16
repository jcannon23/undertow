// Adapted from Ghostwriter (https://github.com/mshll/ghostwriter), GPL-3.0. Changed for Undertow, 2026-11.
import os

extension Logger {
    static func gw(_ category: String) -> Logger { Logger(subsystem: "app.undertow.Undertow", category: category) }
}

public protocol TokenCounting: Sendable {
    func countTokens(_ text: String) -> Int
}
