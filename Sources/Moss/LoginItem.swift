import Foundation
import ServiceManagement

/// Moss as an item that opens when the user logs in.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Moss: could not change the login item: \(error)")
            }
        }
    }
}
