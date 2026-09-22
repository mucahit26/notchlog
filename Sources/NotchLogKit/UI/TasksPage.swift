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
            Text("\(model.showArchive ? model.archive.count : model.open.count)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
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
        let rows = model.showArchive ? model.archive : model.open
        if rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.showArchive ? "Nothing finished yet" : "No open tasks")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if !model.showArchive {
                    Text("Swipe left with two fingers to write one down.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { task in
                        TaskRow(task: task, model: model)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: .infinity)
        }
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
                        Text(Self.stamp(task))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        ForEach(task.apps.prefix(3), id: \.self) { app in
                            Text(app.name)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.07)))
                                .foregroundStyle(.secondary)
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
