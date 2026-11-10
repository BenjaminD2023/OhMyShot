import Foundation

/// Apps are the choices; windows are revealed only inside the chosen app. No system/helper processes
/// enter this model: WindowCatalog has already filtered the shareable content to normal applications.
struct WindowPickerModel {
    struct Application: Equatable {
        let processID: pid_t
        let name: String
        let windows: [WindowCatalog.Choice]
    }

    private var all: [Application] = []
    private var remembered: [pid_t: UInt32] = [:]
    private(set) var applications: [Application] = []
    private(set) var selectedProcessID: pid_t?
    private(set) var selectedWindowID: UInt32?
    private(set) var query = ""

    var application: Application? { applications.first { $0.processID == selectedProcessID } }
    var selected: WindowCatalog.Choice? { application?.windows.first { $0.target.id == selectedWindowID } }

    mutating func replace(_ windows: [WindowCatalog.Choice], preferredProcessID: pid_t?) {
        var seen: Set<UInt32> = []
        let unique = windows.filter { seen.insert($0.target.id).inserted }
        all = Dictionary(grouping: unique, by: \.processID).compactMap { pid, windows in
            guard let first = windows.first else { return nil }
            // Visible windows lead, preserving ScreenCaptureKit's order within each group.
            let ordered = windows.filter(\.isOnScreen) + windows.filter { !$0.isOnScreen }
            return Application(processID: pid, name: first.target.ownerName, windows: ordered)
        }.sorted {
            if ($0.processID == preferredProcessID) != ($1.processID == preferredProcessID) { return $0.processID == preferredProcessID }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        filter(query)
    }

    mutating func filter(_ query: String) {
        self.query = query
        applications = all.compactMap { app in
            let matching = app.windows.filter { $0.matches(query) }
            return matching.isEmpty ? nil : Application(processID: app.processID, name: app.name, windows: matching)
        }
        selectApplication(selectedProcessID.flatMap { id in applications.first { $0.processID == id } }?.processID ?? applications.first?.processID)
    }

    mutating func selectApplication(_ processID: pid_t?) {
        selectedProcessID = processID
        guard let app = application else { selectedWindowID = nil; return }
        selectedWindowID = app.windows.first { $0.target.id == remembered[app.processID] }?.target.id ?? app.windows.first?.target.id
    }

    mutating func selectWindow(_ id: UInt32) {
        guard let app = application, app.windows.contains(where: { $0.target.id == id }) else { return }
        remembered[app.processID] = id
        selectedWindowID = id
    }

    /// The chosen app's next or previous window, around the ends; remembered for the app as one picked by hand is.
    mutating func moveWindow(by step: Int) {
        guard let app = application, app.windows.count > 1 else { return }
        let current = app.windows.firstIndex { $0.target.id == selectedWindowID } ?? 0
        selectWindow(app.windows[(current + step + app.windows.count) % app.windows.count].target.id)
    }

    mutating func moveApplication(by step: Int) {
        guard !applications.isEmpty else { return }
        let current = applications.firstIndex { $0.processID == selectedProcessID } ?? 0
        selectApplication(applications[(current + step + applications.count) % applications.count].processID)
    }
}
