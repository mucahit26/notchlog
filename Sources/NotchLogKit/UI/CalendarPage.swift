import AppKit
import SwiftUI

/// Page 2: a month grid tinted by how hard the machine worked each day, beside the
/// selected day's calendar events and busiest applications.
public struct CalendarPage: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var calendarService: CalendarService

    public init(model: CalendarModel, calendarService: CalendarService) {
        self.model = model
        self.calendarService = calendarService
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 18) {
            monthGrid.frame(width: 288)
            Divider().opacity(0.4)
            dayDetail.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - month grid

    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(model.monthTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Button { model.step(months: -1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                Button { model.goToToday() } label: {
                    Text("Today").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                Button { model.step(months: 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 2) {
                ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 38)
                }
            }

            VStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { week in
                    HStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let index = week * 7 + weekday
                            let days = model.gridDays
                            if index < days.count, let date = days[index] {
                                DayCell(date: date, model: model)
                                    .onTapGesture { model.select(date) }
                            } else {
                                Color.clear.frame(width: 38, height: 26)
                            }
                        }
                    }
                }
            }

            HeatLegend()
            // Without this the VStack distributes slack between its children when the
            // panel is taller than the grid, opening a gap above the legend.
            Spacer(minLength: 0)
        }
    }

    // MARK: - day detail

    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selectedTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            eventsSection
            Divider().opacity(0.4)
            activitySection
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        switch model.access {
        case .granted:
            let events = model.selectedEvents
            if events.isEmpty {
                Text("No events").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(events.prefix(4)) { event in
                        EventRow(event: event)
                    }
                    if events.count > 4 {
                        Text("+\(events.count - 4) more")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        case .notDetermined:
            // The prompt only ever appears because someone opened this page.
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(calendarService.isRequesting ? "Waiting for permission…"
                                                  : "Asking macOS for Calendar access…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 3) {
                Text("Calendar access is off")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text("The heat map below still works — it comes from NotchLog's own data. "
                     + "Enable Calendar in System Settings › Privacy & Security to see events.")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("ACTIVITY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary).tracking(0.4)
                if let activity = model.selectedActivity {
                    Text(Format.duration(Double(activity.cpuMS) / 1000) + " CPU")
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.quaternary)
                    Text(Format.bytes(UInt64(max(0, activity.netBytes))) + " net")
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if model.dayApps.isEmpty {
                Text(model.selected > Date() ? "In the future"
                                             : "Nothing recorded for this day")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                ForEach(model.dayApps) { app in
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 10)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.duration(Double(app.cpuMS) / 1000))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - pieces

private struct DayCell: View {
    let date: Date
    @ObservedObject var model: CalendarModel

    var body: some View {
        let level = model.heatLevel(for: date)
        let selected = model.isSelected(date)
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Palette.cpu : Palette.cpu.opacity(HeatScale.opacity(level)))
            if model.isToday(date) && !selected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Palette.cpu, lineWidth: 1.2)
            }
            VStack(spacing: 1) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 10, weight: selected || model.isToday(date) ? .semibold : .regular))
                    // The number stays ink, never the series colour, so it is legible at
                    // every heat level — including level 0 and the filled selection.
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Circle()
                    .fill(model.hasEvents(date)
                          ? (selected ? Color.white : Color.secondary)
                          : Color.clear)
                    .frame(width: 3, height: 3)
            }
        }
        .frame(width: 38, height: 26)
        .opacity(model.isInDisplayedMonth(date) ? 1 : 0.35)
        .contentShape(Rectangle())
    }
}

/// Discrete heat steps. A ramp of one hue, light to dark — never a rainbow — and
/// discrete rather than continuous because a 38x26 cell cannot carry a fine gradient.
enum HeatScale {
    static func opacity(_ level: Int) -> Double {
        switch level {
        case 1: return 0.18
        case 2: return 0.36
        case 3: return 0.58
        case 4: return 0.82
        default: return 0.06
        }
    }
}

private struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less").font(.system(size: 8)).foregroundStyle(.quaternary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.cpu.opacity(HeatScale.opacity(level)))
                    .frame(width: 10, height: 8)
            }
            Text("More CPU").font(.system(size: 8)).foregroundStyle(.quaternary)
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(event.colorHex.map { Color(nsColor: NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255,
                                                                  green: CGFloat(($0 >> 8) & 0xFF) / 255,
                                                                  blue: CGFloat($0 & 0xFF) / 255,
                                                                  alpha: 1)) } ?? Color.secondary)
                .frame(width: 3, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 11)).lineLimit(1)
                Text(event.isAllDay ? "All day" : Self.range(event))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func range(_ event: CalendarEvent) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeStyle = .short
        f.dateStyle = .none
        return "\(f.string(from: event.start)) – \(f.string(from: event.end))"
    }
}
