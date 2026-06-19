import SwiftUI
import AppKit
import HamlibRig

// NOTE: this file must NOT be named main.swift — @main + a main.swift would be
// two top-level entry points and fail to compile.

@main
struct FT8808App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("FT8-808") {
            ContentView()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 940)
    }
}

/// A SwiftPM executable launches as an "accessory" app by default; promote it to
/// a regular foreground app so the window appears and takes focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Drop PTT on Ctrl-C / kill (these bypass applicationWillTerminate, e.g.
        // when run from `swift run`) and on a crash, so the rig is never left keyed.
        signal(SIGINT)  { _ in HamlibRigController.panicUnkey(); exit(0) }
        signal(SIGTERM) { _ in HamlibRigController.panicUnkey(); exit(0) }
        for crashSig in [SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP] {
            signal(crashSig) { s in
                HamlibRigController.panicUnkey()
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Never leave the transmitter keyed on exit (Cmd-Q, window close, etc.).
    /// Synchronous best-effort PTT-off straight to the open rig — the radio would
    /// otherwise stay stuck transmitting and need a power cycle.
    func applicationWillTerminate(_ notification: Notification) {
        HamlibRigController.panicUnkey()
    }
}
