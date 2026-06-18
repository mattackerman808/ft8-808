import SwiftUI
import AppKit

// NOTE: this file must NOT be named main.swift — @main + a main.swift would be
// two top-level entry points and fail to compile.

@main
struct FT8808App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("FT8-808 — Waterfall") {
            ContentView()
        }
        .windowToolbarStyle(.unified)
    }
}

/// A SwiftPM executable launches as an "accessory" app by default; promote it to
/// a regular foreground app so the window appears and takes focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
