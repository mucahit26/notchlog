import AppKit
import SwiftUI

/// Content of the expanded panel.
///
/// The top `topInset` points sit behind the camera housing on a notched Mac, where there
/// are no pixels, so nothing readable is ever placed there.
public struct ExpandedView: View {
    @ObservedObject var model: LiveModel
    let topInset: CGFloat
    let onExport: () -> Void
    let onQuit: () -> Void

    public init(model: LiveModel, topInset: CGFloat,
                onExport: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.model = model
        self.topInset = topInset
        self.onExport = onExport
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 14) {
                Column(title: "CPU", systemImage: "cpu", rows: model.topCPU, model: model) {
                    Format.percent($0.cpuPercent(interval: model.interval))
                }
                Column(title: "MEMORY", systemImage: "memorychip", rows: model.topRAM, model: model) {
                    Format.kilobytes($0.rssKB)
                }
                Column(title: "NETWORK", systemImage: "arrow.up.arrow.down", rows: model.topNet, model: model) {
                    Format.bytes($0.netTotal)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("NotchLog").font(.system(size: 13, weight: .semibold))
            Text("live · last \(Int(model.interval))s")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            } else if !model.topDisk.isEmpty {
                // Disk is shown as a single line rather than a column: it covers only
                // the user's own processes, so it is not comparable with the others.
                Text("disk · " + model.topDisk.prefix(2).map {
                    "\($0.name) \(Format.bytes($0.diskTotal))"
                }.joined(separator: ", "))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onExport) {
                Label(model.isExporting ? "Exporting…" : "Export last 24 hours (.txt)",
                      systemImage: "square.and.arrow.down")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isExporting)

            if let status = model.exportStatus {
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Format.bytes(UInt64(max(0, model.databaseBytes))))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Button(action: onQuit) {
                Image(systemName: "power").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Quit NotchLog")
        }
    }
}

private struct Column: View {
    let title: String
    let systemImage: String
    let rows: [AppUsage]
    @ObservedObject var model: LiveModel
    let value: (AppUsage) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("idle").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 5) {
                    if let icon = model.icon(for: row) {
                        Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                    } else {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .frame(width: 13)
                    }
                    Text(row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(value(row))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
