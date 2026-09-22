import SwiftUI

/// Wraps subviews onto as many rows as they need, like text.
///
/// A vertical checkbox list of ninety applications reads as a system dialog. Chips that
/// wrap let the same choice sit in a quarter of the height and match how the rest of the
/// panel presents things.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width == .infinity ? (rows.map(\.width).max() ?? 0) : width,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
        }
    }

    private struct Item { let index: Int; let size: CGSize }
    private struct Row { var items: [Item] = []; var y: CGFloat = 0
                         var height: CGFloat = 0; var width: CGFloat = 0 }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.items.isEmpty, x + size.width > width {
                row.width = x - spacing
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
                x = 0
            }
            row.items.append(Item(index: index, size: size))
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }
        if !row.items.isEmpty {
            row.width = x - spacing
            rows.append(row)
        }
        return rows
    }
}
