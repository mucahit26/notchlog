import AppKit
import SwiftUI

/// Page 3: capture a task or idea and associate it with applications.
///
/// Everything typed here is the user's own content, stored alongside the metrics but
/// never purged by retention and never part of an export unless asked for.
public struct NewTaskPage: View {
    @ObservedObject var model: TaskModel
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, notes, search }

    public init(model: TaskModel) { self.model = model }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            editor.frame(width: 336)
            Divider().opacity(0.4)
            appPicker.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.loadInstalledApps()
            // The panel is opened by a swipe, not a click, so nothing has focus yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = .title }
        }
    }

    // MARK: - left: what needs doing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("NEW TASK", systemImage: "square.and.pencil")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary).tracking(0.4)

            TextField("What needs doing?", text: $model.draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .focused($focus, equals: .title)
                .onSubmit { focus = .notes }

            Divider().opacity(0.4)

            ZStack(alignment: .topLeading) {
                if model.draftNotes.isEmpty {
                    Text("Details, context, why it matters…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.draftNotes)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .notes)
            }
            .frame(height: 96)

            HStack(spacing: 8) {
                Button(action: { model.save() }) {
                    Label("Save", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canSave)
                .keyboardShortcut(.return, modifiers: .command)

                Button("Clear") { model.clearDraft(); focus = .title }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.draftTitle.isEmpty && model.draftNotes.isEmpty
                              && model.draftApps.isEmpty)

                if let message = model.saveMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Text("⌘↩ to save · today's date is recorded automatically")
                .font(.system(size: 9)).foregroundStyle(.quaternary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - right: which apps should remind me

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("REMIND ME IN", systemImage: "app.badge.checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary).tracking(0.4)
                Spacer(minLength: 0)
                if !model.draftApps.isEmpty {
                    Text("\(model.draftApps.count) selected")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.cpu)
                }
            }

            TextField("Search applications", text: $model.appSearch)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($focus, equals: .search)

            if model.isScanning {
                Text("Scanning applications…")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.filteredApps) { app in
                        AppToggle(app: app, model: model,
                                  selected: model.draftApps.contains(app.id)) {
                            if model.draftApps.contains(app.id) {
                                model.draftApps.remove(app.id)
                            } else {
                                model.draftApps.insert(app.id)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 2)

            Text("Leave empty for a task with no reminder")
                .font(.system(size: 9)).foregroundStyle(.quaternary)
        }
    }
}

private struct AppToggle: View {
    let app: InstalledApp
    @ObservedObject var model: TaskModel
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Palette.cpu : Color.secondary.opacity(0.6))
            if let icon = model.icon(for: app) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 10)).foregroundStyle(.quaternary).frame(width: 14)
            }
            Text(app.name).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(selected ? Palette.cpu.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}
