import Foundation

/// Abstracts structured logging.
/// macOS uses os.Logger; Windows will use Event Log or file-based logging.
public protocol LogProvider: Sendable {
    func debug(_ message: String)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}
