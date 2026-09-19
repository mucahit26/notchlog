import AppKit
import NotchLogKit

/// Owns the monitor and the panel for the lifetime of the process.
///
/// A delegate rather than top-level variables because top-level code cannot hold
/// main-actor-isolated state, and because it gives a clean place to shut the sampler
/// down when the process is asked to quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let monitor = try Monitor()
            let controller = NotchController(monitor: monitor)
            monitor.start()
            controller.show()
            self.monitor = monitor
            self.controller = controller
        } catch {
            FileHandle.standardError.write(Data("notchlog: failed to start: \(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}
