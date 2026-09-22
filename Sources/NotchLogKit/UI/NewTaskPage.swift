import AppKit
import SwiftUI

/// Page 3: capture a task or idea and associate it with applications.
///
/// Everything typed here is the user's own content, stored alongside the metrics but
/// never purged by retention and never part of an export.
public struct NewTaskPage: View {
    @ObservedObject var model: TaskModel
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, notes, search }

    public init(model: TaskModel) { self.model = model }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            editor.frame(width: 352)
            Divider().opacity(0.4)
            appPicker.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.loadInstalledApps()
            // The panel arrives by a swipe, not a click, so nothing has focus yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = .title }
        }
        .onChange(of: focus) { _, newValue in model.isEditing = newValue != nil }
        .onDisappear { model.isEditing = false }
    }

    // MARK: - left: what needs doing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("What needs doing?", text: $model.draftTitle, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1...2)
                .focused($focus, equals: .title)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(field(focused: focus == .title))

            ZStack(alignment: .topLeading) {
                if model.draftNotes.isEmpty {
                    Text("Details, context, why it matters…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.draftNotes)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .notes)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
            }
            .frame(maxHeight: .infinity)
            .background(field(focused: focus == .notes))

            HStack(spacing: 8) {
                Button(action: { model.save(); focus = .title }) {
                    Label("Save task", systemImage: "arrow.down.to.line")
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
                Spacer(minLength: 0)
            }

            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let message = model.saveMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Palette.network)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Command-Return saves · today's date is recorded automatically.")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
    }

    private func field(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Palette.cpu.opacity(0.7)
                                          : Color.primary.opacity(0.08),
                                  lineWidth: focused ? 1.2 : 0.8))
    }

    // MARK: - right: which apps should remind me

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("REMIND ME IN")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary).tracking(0.4)
                Spacer(minLength: 0)
                if !model.draftApps.isEmpty {
                    Button("Clear") { model.draftApps.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                }
            }

            if model.draftApps.isEmpty {
                Text("Pick the apps that should remind you. Leave empty for a plain note.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(model.selectedApps) { app in
                        AppChip(app: app, model: model, selected: true) {
                            model.draftApps.remove(app.id)
                        }
                    }
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                TextField("Search", text: $model.appSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($focus, equals: .search)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(field(focused: focus == .search))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.runningApps.isEmpty && model.appSearch.isEmpty {
                        section("RUNNING NOW", model.runningApps)
                    }
                    section(model.appSearch.isEmpty ? "ALL APPLICATIONS" : "MATCHES",
                            model.unselectedApps)
                    if model.isScanning {
                        Text("Scanning applications…")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ apps: [InstalledApp]) -> some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary).tracking(0.4)
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(apps) { app in
                        AppChip(app: app, model: model,
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
        }
    }
}

private struct AppChip: View {
    let app: InstalledApp
    @ObservedObject var model: TaskModel
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let icon = model.icon(for: app) {
                Image(nsImage: icon).resizable().frame(width: 13, height: 13)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 9)).foregroundStyle(.quaternary).frame(width: 13)
            }
            Text(app.name)
                .font(.system(size: 10, weight: selected ? .medium : .regular))
                .lineLimit(1)
            if selected {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Palette.cpu.opacity(0.18) : Color.primary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Palette.cpu.opacity(0.55) : Color.clear,
                                  lineWidth: 1)))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}
