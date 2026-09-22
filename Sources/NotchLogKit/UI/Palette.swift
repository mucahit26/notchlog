import AppKit
import SwiftUI

/// Three categorical hues, one per metric column.
///
/// These are slots 1-3 of a validated categorical palette, with separate steps for the
/// light and dark surfaces rather than an automatic flip. Verified with the palette
/// validator on the all-pairs list in both modes: worst CVD ΔE 9.2 light / 9.4 dark
/// (≥8 target), worst normal-vision ΔE 24.0 light / 20.9 dark (≥15 floor).
///
/// Aqua sits at 2.74:1 against the light surface, below the 3:1 bar, so the "relief"
/// rule applies: every column carries a visible text label and every row shows its app
/// name and value as text. Identity is never communicated by colour alone.
public enum Palette {
    public static let cpu = dynamic(light: 0x2A78D6, dark: 0x3987E5)      // blue
    public static let memory = dynamic(light: 0xEB6834, dark: 0xD95926)   // orange
    public static let network = dynamic(light: 0x1BAF7A, dark: 0x199E70)  // aqua

    /// Reserved for state, never for a series: a missed deadline is a status, and
    /// reusing one of the three metric hues for it would make the same colour mean two
    /// different things on the same screen.
    public static let overdue = dynamic(light: 0xE34948, dark: 0xE66767)  // red

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
