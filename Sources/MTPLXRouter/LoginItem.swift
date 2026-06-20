import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (works when running as a bundled .app).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            LogStore.shared.log("login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            return false
        }
    }
}
