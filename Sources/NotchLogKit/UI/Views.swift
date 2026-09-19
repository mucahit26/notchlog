import AppKit
import SwiftUI

/// Content of the expanded panel.
///
/// The top `topInset` points sit behind the camera housing on a notched Mac, where there
/// are no pixels, so nothing readable is ever placed there.
///
/// Each column ranks apps on one metric and draws a bar relative to the busiest app in
/// **that** column. Bars are never compared across columns: percent, bytes and bytes per
/// interval share no scale, and a bar that spanned two of them would be meaningless.
public struct ExpandedView: View {
    @ObservedObject var model: LiveModel
    @ObservedObject var panel: PanelState
    @ObservedObject var calendarModel: CalendarModel
    @ObservedObject var calendarService: CalendarService
    let topInset: CGFloat
    let onExport: () -> Void
    let onRevealData: () -> Void
    let onQuit: () -> Void

    public init(model: LiveModel,
                panel: PanelState,
                calendarModel: CalendarModel,
                calendarService: CalendarService,
                topInset: CGFloat,
                onExport: @escaping () -> Void,
                onRevealData: @escaping () -> Void = {},
                onQuit: @escaping () -> Void) {
        self.model = model
        self.panel = panel
        self.calendarModel = calendarModel
        self.calendarService = calendarService
        self.topInset = topInset
        self.onExport = onExport
        self.onRevealData = onRevealData
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            pages
            PageDots(current: panel.page, count: PanelState.pageCount) { panel.page = $0 }
                .frame(maxWidth: .infinity)
            Divider().opacity(0.4)
            footer
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var pages: some View {
        ZStack {
            if panel.page == 0 {
                metricsPage
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                CalendarPage(model: calendarModel, calendarService: calendarService)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
        .animation(.easeOut(duration: 0.24), value: panel.page)
    }

    private var metricsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                MetricColumn(title: "CPU", accent: Palette.cpu, rows: model.topCPU, model: model,
                             value: { Format.percent($0.cpuPercent(interval: model.interval)) },
                             fraction: { row in
                                 guard model.cpuMax > 0 else { return 0 }
                                 return row.cpuPercent(interval: model.interval) / model.cpuMax
                             })
                MetricColumn(title: "MEMORY", accent: Palette.memory, rows: model.topRAM, model: model,
                             value: { Format.kilobytes($0.rssKB) },
                             fraction: { row in
                                 guard model.ramMax > 0 else { return 0 }
                                 return Double(row.rssKB) / Double(model.ramMax)
                             })
                MetricColumn(title: "NETWORK", accent: Palette.network, rows: model.topNet, model: model,
                             value: { Format.bytes($0.netTotal) },
                             fraction: { row in
                                 guard model.netMax > 0 else { return 0 }
                                 return Double(row.netTotal) / Double(model.netMax)
                             })
            }
            diskLine
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("NotchLog").font(.system(size: 13, weight: .semibold))
            Text("live · \(Int(model.interval))s")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            } else {
                Stat(label: "CPU", value: Format.percent(model.systemCPUPercent),
                     help: "Share of all \(ProcessInfo.processInfo.activeProcessorCount) cores. "
                         + "Per-app figures below are a share of one core, so they can exceed 100%.")
                Stat(label: "RAM", value: Format.kilobytes(model.totalRSSKB),
                     help: "Sum of resident memory. Helper processes are counted under their "
                         + "parent app, which double-counts shared framework pages.")
                Stat(label: "NET",
                     value: "↓\(Format.bytes(model.netInRate))/s  ↑\(Format.bytes(model.netOutRate))/s",
                     help: "Measured per open socket, so totals are a lower bound.")
            }
        }
    }

    // MARK: - disk

    private var diskLine: some View {
        HStack(spacing: 6) {
            Text("DISK")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            // Disk is a single line rather than a fourth column because it covers only
            // the user's own processes — it is not comparable with the other three.
            Text("your processes only")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if model.topDisk.isEmpty {
                Text("idle").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Text(model.topDisk.map { "\($0.name) \(Format.bytes($0.diskTotal))" }
                        .joined(separator: "   ·   "))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onExport) {
                Label(model.isExporting ? "Exporting…" : "Export last 24 hours",
                      systemImage: "arrow.down.document")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isExporting)

            if let status = model.exportStatus {
                Text(status)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Label(Format.bytes(UInt64(max(0, model.databaseBytes))), systemImage: "internaldrive")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .help("Database size — capped at 7 days")

            // A menu rather than a bare quit button: revealing the data folder is the
            // other thing anyone actually wants from here, and it makes the "where does
            // my data live" question answerable without reading the README.
            Menu {
                Button("Reveal Data Folder in Finder", action: onRevealData)
                Divider()
                Button("Quit NotchLog", action: onQuit)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options")
        }
    }
}

/// A headline number in the header strip.
private struct Stat: View {
    let label: String
    let value: String
    var help: String = ""

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(help)
    }
}

private struct MetricColumn: View {
    let title: String
    let accent: Color
    let rows: [AppUsage]
    @ObservedObject var model: LiveModel
    let value: (AppUsage) -> String
    let fraction: (AppUsage) -> Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                // The swatch carries identity; the label carries it in text too, so the
                // column is still legible without colour vision.
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accent)
                    .frame(width: 3, height: 9)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
            }
            if rows.isEmpty {
                Text("idle").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(rows, id: \.name) { row in
                MetricRow(row: row, accent: accent, model: model,
                          value: value(row), fraction: fraction(row))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MetricRow: View {
    let row: AppUsage
    let accent: Color
    @ObservedObject var model: LiveModel
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let icon = model.icon(for: row) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                } else {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                        .frame(width: 13)
                }
                Text(row.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // Values wear text tokens, never the series colour — the swatch and the
                // bar carry identity, the number stays legible ink.
                Text(value)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.16))
                    Capsule()
                        .fill(accent)
                        // Keep a sliver visible for tiny values so a row never reads as
                        // zero when it is merely small.
                        .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 3)
        }
        .padding(.leading, 0)
    }
}


/// Page indicator. Clickable as well as swipeable — a gesture with no visible
/// affordance is a feature nobody discovers.
private struct PageDots: View {
    let current: Int
    let count: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary.opacity(0.65)
                                           : Color.primary.opacity(0.18))
                    .frame(width: 5, height: 5)
                    .onTapGesture { select(index) }
            }
        }
        .help("Swipe left or right with two fingers to switch pages")
    }
}
