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

    /// True only while a text field on the capture page holds focus.
    ///
    /// The panel is pinned open while this is set, so a sentence is never cut off
    /// mid-word by the pointer drifting away. It is deliberately NOT pinned for the
    /// whole page: the draft lives here in the model and survives the panel closing,
    /// so there is nothing to protect once you stop typing — and a panel that never
    /// hides is worse than one that hides a little eagerly.
    @Published public var isEditing = false

    // List
    @Published public private(set) var open: [TaskItem] = []
    @Published public private(set) var archive: [TaskItem] = []
    @Published public var showArchive = false

    /// When set, only tasks associated with this application are listed.
    ///
    /// Cleared when the panel closes: a filter you cannot see the origin of is worse
    /// than no filter, and the panel reopening on a silently narrowed list would look
    /// like tasks had gone missing.
    @Published public var filterApp: String?

    // Picker
    @Published public private(set) var installed: [InstalledApp] = []
    @Published public private(set) var isScanning = false

    /// Set when an application launch surfaced tasks, so the list can explain why the
    /// panel opened by itself.
    @Published public var reminderContext: String?

    @Published public private(set) var errorMessage: String?

    /// Bundle ids of applications running right now, refreshed as they come and go.
    @Published public private(set) var runningBundleIDs: Set<String> = []

    private let db: Database
    /// Built once after the scan and then only read. Loading icons lazily from the view
    /// body meant mutating this dictionary during a SwiftUI update, on every scroll, for
    /// every row that came into view — which is what made the picker feel sticky.
    @Published private var icons: [String: NSImage] = [:]

    public init(database: Database) {
        self.db = database
        refreshRunning()
        // The grouping below is only useful if it keeps up with what is open, so it
        // follows the workspace rather than being sampled once when the page appears.
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunning() }
            }
        }
    }

    public func refreshRunning() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier))
    }

    /// True when at least one application this task is tied to is open right now.
    public func isActive(_ task: TaskItem) -> Bool {
        task.apps.contains { app in
            guard let bundle = app.bundleID else { return false }
            return runningBundleIDs.contains(bundle)
        }
    }

    public func isRunning(_ app: TaskApp) -> Bool {
        guard let bundle = app.bundleID else { return false }
        return runningBundleIDs.contains(bundle)
    }

    public func toggleFilter(_ appName: String) {
        filterApp = (filterApp == appName) ? nil : appName
    }

    public func clearFilter() { filterApp = nil }

    private func matchesFilter(_ task: TaskItem) -> Bool {
        guard let filterApp else { return true }
        return task.apps.contains { $0.name == filterApp }
    }

    /// Open tasks narrowed to the current filter, ungrouped — once you have asked for
    /// one application, splitting by "is it running" answers a question you just
    /// answered yourself.
    public var filteredOpen: [TaskItem] { open.filter(matchesFilter) }

    public var filteredArchive: [TaskItem] { archive.filter(matchesFilter) }

    /// Open tasks split into the ones you could act on right now and the rest.
    ///
    /// A task tied to nothing has no app to be waiting in, so it belongs with the
    /// second group rather than claiming the top of the list.
    public var groupedOpen: (active: [TaskItem], other: [TaskItem]) {
        var active: [TaskItem] = []
        var other: [TaskItem] = []
        for task in open {
            if isActive(task) { active.append(task) } else { other.append(task) }
        }
        return (active, other)
    }

    /// Names of the open applications that actually have tasks waiting, for the heading.
    public var activeAppNames: [String] {
        var names: [String] = []
        for task in groupedOpen.active {
            for app in task.apps where isRunning(app) && !names.contains(app.name) {
                names.append(app.name)
            }
        }
        return names
    }

    public var filteredApps: [InstalledApp] {
        let query = appSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return installed }
        return installed.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The apps already ticked, in the order they appear in the list.
    public var selectedApps: [InstalledApp] {
        installed.filter { draftApps.contains($0.id) }
    }

    public var unselectedApps: [InstalledApp] {
        filteredApps.filter { !draftApps.contains($0.id) }
    }

    /// Apps that are running right now, offered first — the task you are writing down
    /// is usually about something already in front of you.
    public var runningApps: [InstalledApp] {
        let live = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return installed.filter { app in
            guard let bundle = app.bundleID, live.contains(bundle) else { return false }
            return !draftApps.contains(app.id)
        }
    }

    public var canSave: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func icon(for app: InstalledApp) -> NSImage? { icons[app.path] }

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
            // Icons come from LaunchServices and are not cheap. They are loaded after
            // the list is already usable, in small batches on the main actor: NSImage
            // is not Sendable so it cannot cross an actor boundary, and doing all
            // ninety in one hop would block the main thread while the panel is open.
            let batchSize = 12
            for start in stride(from: 0, to: apps.count, by: batchSize) {
                let batch = Array(apps[start..<min(start + batchSize, apps.count)])
                await MainActor.run {
                    for app in batch {
                        if let image = InstalledApps.icon(forPath: app.path) {
                            self.icons[app.path] = image
                        }
                    }
                }
                await Task.yield()
            }
        }
    }

    public func reload() {
        let db = self.db
        refreshRunning()
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
