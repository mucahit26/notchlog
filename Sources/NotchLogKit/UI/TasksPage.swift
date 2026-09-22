import AppKit
import SwiftUI

/// Page 4: open tasks, and the archive of finished ones.
///
/// This is also the page the panel opens to on its own when an application you
/// associated with a task launches.
public struct TasksPage: View {
    @ObservedObject var model: TaskModel

    public init(model: TaskModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let context = model.reminderContext {
                reminderBanner(context)
            }
            list
        }
        .onAppear { model.reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(model.showArchive ? "ARCHIVE" : "OPEN TASKS",
                  systemImage: model.showArchive ? "archivebox" : "checklist")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary).tracking(0.4)
            Text("\(model.showArchive ? model.filteredArchive.count : model.filteredOpen.count)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            if let filter = model.filterApp {
                Button {
                    model.clearFilter()
                } label: {
                    HStack(spacing: 3) {
                        Text("only \(filter)").font(.system(size: 9, weight: .medium))
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.cpu.opacity(0.2)))
                    .foregroundStyle(Palette.cpu)
                }
                .buttonStyle(.borderless)
                .help("Show every task again")
            }
            Spacer(minLength: 8)
            Picker("", selection: $model.showArchive) {
                Text("Open").tag(false)
                Text("Done").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .controlSize(.small)
        }
    }

    private func reminderBanner(_ context: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 10)).foregroundStyle(Palette.memory)
            Text("You just opened \(context) — these were waiting")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                model.reminderContext = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Palette.memory.opacity(0.12)))
    }

    @ViewBuilder
    private var list: some View {
        if model.showArchive {
            if model.filteredArchive.isEmpty {
                emptyState(model.filterApp == nil ? "Nothing finished yet"
                                                  : "Nothing finished for \(model.filterApp!)",
                           hint: nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.filteredArchive) { TaskRow(task: $0, model: model) }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: .infinity)
            }
        } else if let filter = model.filterApp {
            if model.filteredOpen.isEmpty {
                emptyState("Nothing open for \(filter)", hint: nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.filteredOpen) { TaskRow(task: $0, model: model) }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: .infinity)
            }
        } else if model.open.isEmpty {
            emptyState("No open tasks",
                       hint: "Swipe left with two fingers to write one down.")
        } else {
            openList
        }
    }

    /// Open tasks, with the ones you could act on right now lifted to the top.
    ///
    /// The split is by whether an associated application is actually running: a task
    /// about Outlook is worth seeing while Outlook is open and is noise while it is
    /// not. Tasks tied to nothing sit in the second group — there is no app they are
    /// waiting in.
    private var openList: some View {
        let groups = model.groupedOpen
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if !groups.active.isEmpty {
                    openNowHeader
                    ForEach(groups.active) { TaskRow(task: $0, model: model) }
                }
                if !groups.other.isEmpty {
                    sectionHeader(groups.active.isEmpty ? "WAITING" : "NOT OPEN RIGHT NOW",
                                  detail: nil, accent: nil)
                    ForEach(groups.other) { TaskRow(task: $0, model: model) }
                }
            }
            .padding(.trailing, 4)
        }
        .frame(maxHeight: .infinity)
    }

    /// The running app names double as filters — the information is already on screen,
    /// so making it clickable costs nothing and saves scanning the list by eye.
    private var openNowHeader: some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.network).frame(width: 5, height: 5)
            Text("OPEN NOW")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.network)
                .tracking(0.5)
            ForEach(model.activeAppNames, id: \.self) { name in
                Button {
                    model.toggleFilter(name)
                } label: {
                    Text(name)
                        .font(.system(size: 9, weight: model.filterApp == name ? .semibold : .regular))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(model.filterApp == name
                                                   ? Palette.network.opacity(0.22)
                                                   : Color.primary.opacity(0.07)))
                        .foregroundStyle(model.filterApp == name
                                         ? AnyShapeStyle(Palette.network)
                                         : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help("Show only \(name) tasks")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, 1)
    }

    private func sectionHeader(_ title: String, detail: String?, accent: Color?) -> some View {
        HStack(spacing: 5) {
            if let accent {
                Circle().fill(accent).frame(width: 5, height: 5)
            }
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(accent == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(accent!))
                .tracking(0.5)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, 1)
    }

    private func emptyState(_ title: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TaskRow: View {
    let task: TaskItem
    @ObservedObject var model: TaskModel
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    model.setCompleted(task, completed: task.isOpen)
                } label: {
                    Image(systemName: task.isOpen ? "circle" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(task.isOpen ? Color.secondary.opacity(0.6) : Palette.network)
                }
                .buttonStyle(.borderless)
                .help(task.isOpen ? "Mark as done" : "Reopen")

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .strikethrough(!task.isOpen, color: .secondary)
                        .foregroundStyle(task.isOpen ? Color.primary : Color.secondary)
                        .lineLimit(expanded ? nil : 1)

                    if !task.notes.isEmpty {
                        Text(task.notes)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 1)
                    }

                    HStack(spacing: 5) {
                        if let due = task.dueAt {
                            DueBadge(task: task, due: due)
                        }
                        Text(Self.stamp(task))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        ForEach(task.apps.prefix(3), id: \.self) { app in
                            let running = model.isRunning(app)
                            HStack(spacing: 3) {
                                if running {
                                    Circle().fill(Palette.network).frame(width: 4, height: 4)
                                }
                                Text(app.name).font(.system(size: 9))
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(running ? Palette.network.opacity(0.16)
                                              : Color.primary.opacity(0.07)))
                            .foregroundStyle(running ? AnyShapeStyle(Palette.network)
                                                     : AnyShapeStyle(.secondary))
                        }
                        if task.apps.count > 3 {
                            Text("+\(task.apps.count - 3)")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 0)

                if hovering {
                    Button {
                        model.delete(task)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Delete permanently")
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.06 : 0.03)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
    }

    /// Deadline marker. Overdue wears the reserved status colour rather than one of the
    /// metric hues, so a missed deadline never looks like a category.
    private struct DueBadge: View {
        let task: TaskItem
        let due: Date

        var body: some View {
            let overdue = task.isOverdue
            let today = task.isDueToday
            let tint: Color = overdue ? Palette.overdue : (today ? Palette.memory : .secondary)
            HStack(spacing: 3) {
                Image(systemName: task.eventID == nil ? "flag.fill" : "calendar")
                    .font(.system(size: 7))
                Text(label)
                    .font(.system(size: 9, weight: overdue || today ? .semibold : .regular))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tint.opacity(overdue || today ? 0.18 : 0.08)))
            .foregroundStyle(tint)
            .help(task.eventID == nil ? "Deadline" : "Deadline — also in your calendar")
        }

        private var label: String {
            if task.isOverdue { return "overdue" }
            if task.isDueToday { return "due today" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "d MMM"
            return "due " + formatter.string(from: due)
        }
    }

    /// Created date for open tasks, finished date for archived ones — the date that
    /// matters is different depending on which list you are looking at.
    private static func stamp(_ task: TaskItem) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM HH:mm"
        if let done = task.completedAt {
            return "done " + formatter.string(from: done)
        }
        return "added " + formatter.string(from: task.createdAt)
    }
}
