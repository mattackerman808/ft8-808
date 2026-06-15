import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Minimal raw-mode terminal control built on `termios` + ANSI escapes.
///
/// No ncurses dependency: this is a plain character stream, so it works fine
/// over SSH. We use the alternate screen buffer and restore the terminal on
/// exit (including Ctrl-C) so the user's shell is left clean.
enum Terminal {
    // Access is serialized: enabled once at startup, restored at exit / on
    // SIGINT. The signal handler runs in a C context that can't touch actors,
    // so these stay nonisolated.
    nonisolated(unsafe) private static var saved = termios()
    nonisolated(unsafe) private static var rawEnabled = false

    static func enableRawMode() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        // Disable canonical mode, echo, signals, flow control, CR->NL.
        raw.c_lflag &= ~UInt(ECHO | ICANON | IEXTEN | ISIG)
        raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~UInt(OPOST)
        // read() returns after >=1 byte, no inter-byte timeout.
        withUnsafeMutablePointer(to: &raw.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        rawEnabled = true
        write("\u{1b}[?1049h\u{1b}[?25l") // alt screen, hide cursor
    }

    static func restore() {
        guard rawEnabled else { return }
        write("\u{1b}[?25h\u{1b}[?1049l") // show cursor, leave alt screen
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        rawEnabled = false
    }

    static func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    static func size() -> (rows: Int, cols: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
            return (Int(ws.ws_row), Int(ws.ws_col))
        }
        return (24, 80)
    }

    // ANSI helpers ----------------------------------------------------------
    static let clear = "\u{1b}[2J\u{1b}[H"
    static func home() -> String { "\u{1b}[H" }
    static func move(_ row: Int, _ col: Int) -> String { "\u{1b}[\(row);\(col)H" }
    static let reset = "\u{1b}[0m"
    static let bold = "\u{1b}[1m"
    static let dim = "\u{1b}[2m"
    static func fg256(_ n: Int) -> String { "\u{1b}[38;5;\(n)m" }
    static func bg256(_ n: Int) -> String { "\u{1b}[48;5;\(n)m" }
}
