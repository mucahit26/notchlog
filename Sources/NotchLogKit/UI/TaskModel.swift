import AppKit
import Foundation
import SwiftUI

/// State for the two task pages: the capture form and the list.
@MainActor
public final class TaskModel: ObservableObject {
    // Capture form
    @Published public var draftTitle = ""
    @Published public var draftNotes = ""
    @Published public var draftApps: Set<String> = []      // keyed by InstalledApp.id (path)
    @Published public var appSearch = ""
    @Published public var saveMessage: String?

    // List
    @Published public private(set) var open: [TaskItem] = []
    @Published public private(set) var archive: [TaskItem] = []
    @Published public var showArchive = false

    // Picker
    @Published public private(set) var installed: [InstalledApp] = []
    @Published public private(set) var isScanning = false

    /// Set when an application launch surfaced tasks, so the list can explain why the
    /// panel opened by itself.
    @Published public var reminderContext: String?

    @Published public private(set) var errorMessage: String?

    private let db: Database
    private var iconCache: [String: NSImage] = [:]

    public init(database: Database) {
        self.db = database
    }

    public var filteredApps: [InstalledApp] {
        let query = appSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return installed }
        return installed.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    public var canSave: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func icon(for app: InstalledApp) -> NSImage? {
        if let hit = iconCache[app.path] { return hit }
        guard let image = InstalledApps.icon(forPath: app.path) else { return nil }
        iconCache[app.path] = image
        return image
    }

    // MARK: - loading

    public func loadInstalledApps() {
        guard installed.isEmpty, !isScanning else { return }
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let apps = InstalledApps.scan()
            await MainActor.run {
                self.installed = apps
                self.isScanning = false
            }
        }
    }

    public func reload() {
        let db = self.db
        Task.detached(priority: .userInitiated) {
            let result = Result { (try db.openTasks(), try db.completedTasks(limit: 50)) }
            await MainActor.run {
                switch result {
                case .success(let (open, archive)):
                    self.open = open
                    self.archive = archive
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = String(describing: error)
                }
            }
        }
    }

    // MARK: - actions

    public func save() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let notes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = installed.filter { draftApps.contains($0.id) }.map(\.taskApp)
        let db = self.db

        Task.detached(priority: .userInitiated) {
            let result = Result { try db.createTask(title: title, notes: notes, apps: apps) }
            await MainActor.run {
                switch result {
                case .success:
                    self.draftTitle = ""
                    self.draftNotes = ""
                    self.draftApps = []
                    self.appSearch = ""
                    self.saveMessage = apps.isEmpty
                        ? "Saved"
                        : "Saved — you'll be reminded when \(Self.describe(apps)) opens"
                    self.reload()
                case .failure(let error):
                    self.saveMessage = "Could not save: \(error)"
                }
            }
        }
    }

    public func setCompleted(_ task: TaskItem, completed: Bool) {
        let db = self.db
        Task.detached(priority: .userInitiated) {
            try? db.setTaskCompleted(id: task.id, completed: completed)
            await MainActor.run { self.reload() }
        }
    }

    public func delete(_ task: TaskItem) {
        let db = self.db
        Task.detached(priority: .userInitiated) {
            try? db.deleteTask(id: task.id)
            await MainActor.run { self.reload() }
        }
    }

    public func clearDraft() {
        draftTitle = ""
        draftNotes = ""
        draftApps = []
        appSearch = ""
        saveMessage = nil
    }

    private static func describe(_ apps: [TaskApp]) -> String {
        switch apps.count {
        case 1: return apps[0].name
        case 2: return "\(apps[0].name) or \(apps[1].name)"
        default: return "\(apps[0].name) or \(apps.count - 1) other apps"
        }
    }
}
