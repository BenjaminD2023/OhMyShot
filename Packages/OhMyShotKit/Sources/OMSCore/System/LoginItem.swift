import ServiceManagement

/// Launch at login, through the system's login item list.
@MainActor
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// System Settings' Login Items, where the user can turn the app on or off when it can't do so itself.
    public static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
