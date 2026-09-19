import Foundation

/// Collapses helper processes into the application a user would recognise.
///
/// The rule is the **leftmost** `.app` component of the executable path:
///
///     /Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper (Renderer).app/…
///                   ^^^^^^^^^^^^^^^^^ → "Google Chrome"
///
/// Without this, "top memory" is five Chrome renderer rows instead of one Chrome row.
/// Paths with no `.app` component are daemons or CLI tools; they keep their basename.
public enum AppIdentity {
    public struct Identity: Equatable, Sendable {
        public let name: String
        /// Path to the .app bundle, when the process belongs to one. Used for icons.
        public let bundlePath: String?
        public var isBundle: Bool { bundlePath != nil }
    }

    public static func identify(execPath: String) -> Identity {
        let parts = execPath.split(separator: "/", omittingEmptySubsequences: false)
        if let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let name = String(parts[idx].dropLast(4))
            let bundle = parts[...idx].joined(separator: "/")
            return Identity(name: name, bundlePath: bundle)
        }
        let base = parts.last.map(String.init) ?? execPath
        return Identity(name: base.isEmpty ? execPath : base, bundlePath: nil)
    }
}
