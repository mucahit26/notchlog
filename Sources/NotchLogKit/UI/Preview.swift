import AppKit
import SwiftUI

/// Renders the expanded panel to a PNG without putting anything on screen.
///
/// A development aid: it makes the layout reviewable without a screen recording
/// permission and without asking someone to look at their own display. The data is
/// synthetic but shaped like real samples, including the long process names and the
/// wide dynamic range that break layouts.
@MainActor
public enum PanelPreview {
    public static func render(to url: URL, dark: Bool = true) throws {
        let model = LiveModel()
        model.apply(sampleSnapshot())
        model.databaseBytes = 34_500_000
        model.exportStatus = nil

        let view = ExpandedView(model: model, topInset: 45,
                                onExport: {}, onRevealData: {}, onQuit: {})
            .frame(width: NotchGeometry.expandedSize.width,
                   height: NotchGeometry.expandedSize.height)
            // The material background has no backdrop to sample offscreen, so the
            // preview puts a plain surface behind it to keep the render readable.
            .background(dark ? Color(white: 0.12) : Color(white: 0.92))

        // Rendered through a real NSHostingView in a real (offscreen) window rather than
        // through ImageRenderer. ImageRenderer does not resolve a bare
        // Image(systemName:) — it substitutes the "missing image" placeholder — so a
        // preview built on it reports icon bugs that do not exist and hides ones that do.
        let size = NotchGeometry.expandedSize
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance

        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000),
                                                  size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its layout and load app icons before the snapshot.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        // cacheDisplay renders at the rep's own backing resolution; rescaling the rep
        // after the fact just offsets the content inside a larger canvas.
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    static func sampleSnapshot() -> Snapshot {
        func app(_ name: String, _ bundle: String?, cpuMS: Int, rssKB: Int,
                 netIn: UInt64 = 0, netOut: UInt64 = 0,
                 diskR: UInt64? = nil, diskW: UInt64? = nil) -> AppUsage {
            AppUsage(name: name, bundlePath: bundle, cpuMS: cpuMS, rssKB: rssKB,
                     netIn: netIn, netOut: netOut, diskRead: diskR, diskWritten: diskW,
                     processCount: 1)
        }
        return Snapshot(date: Date(), interval: 2, apps: [
            app("WindowServer", nil, cpuMS: 834, rssKB: 81_504),
            app("Google Chrome", "/Applications/Google Chrome.app",
                cpuMS: 256, rssKB: 5_138_432, netIn: 16_284, netOut: 4_096,
                diskR: 58_700, diskW: 1_468_000),
            app("Claude", "/Applications/Claude.app",
                cpuMS: 418, rssKB: 1_258_291, netIn: 1_048, netOut: 31_948,
                diskR: 930_000, diskW: 214_000),
            app("com.apple.WebKit.WebContent", nil, cpuMS: 96, rssKB: 131_072),
            app("Adobe Acrobat", "/Applications/Adobe Acrobat.app", cpuMS: 34, rssKB: 201_728),
            app("WhatsApp", "/Applications/WhatsApp.app",
                cpuMS: 18, rssKB: 283_648, netIn: 80, netOut: 68, diskW: 4_200),
            app("mDNSResponder", nil, cpuMS: 8, rssKB: 12_288, netOut: 2_048),
            app("notchlog", nil, cpuMS: 104, rssKB: 61_440, diskW: 49_200),
        ], isGap: false)
    }
}
