import Foundation
import os

/// Diagnostics that come out somewhere copy-pasteable.
///
/// Two destinations, each switchable, and both off unless somebody turns them
/// on in Settings. They were on unconditionally while this was a thing one
/// person ran from Xcode; for anyone else they are noise, and an app writing a
/// line a second to the system log is worse than noise.
///
/// The third kind of diagnostic, the readout along the bottom of the picture,
/// is not here -- the view draws it, and `showDiagnostics` switches it.
///
///   * `os.Logger`, which shows up in Console.app and can be streamed from a
///     terminal without Xcode at all:
///
///         log stream --style compact \
///             --predicate 'subsystem == "org.malinowski.cochleagram"'
///
///   * plain stdout, so running the executable straight from a shell prints to
///     that shell:
///
///         ./Cochleagram.app/Contents/MacOS/Cochleagram
///
///     (Launched that way the responsible process is the terminal, so live
///     input will ask the terminal for microphone access -- fine for working
///     on the display, where Open File is enough.)
enum Log {

    /// Write to stdout, which is where Xcode's console reads from.
    static var toConsole = false
    /// Write to the unified log, for `log stream` and Console.app.
    static var toLogStream = false

    private static let logger = Logger(subsystem: "org.malinowski.cochleagram",
                                       category: "app")
    private static let start = Date()

    /// The message is an autoclosure, so a call site that builds a string
    /// costs nothing when both destinations are off -- which is now the
    /// normal case, and some of these sit on the drawing path.
    static func say(_ message: @autoclosure () -> String) {
        guard toConsole || toLogStream else { return }
        let text = message()
        if toLogStream { logger.notice("\(text, privacy: .public)") }
        if toConsole {
            let t = String(format: "%7.2f", Date().timeIntervalSince(start))
            print("[\(t)] \(text)")
            fflush(stdout)
        }
    }
}
