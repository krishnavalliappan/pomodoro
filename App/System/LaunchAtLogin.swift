import Foundation
import Observation
import ServiceManagement

/// `SMAppService.Status`, narrowed to what Settings shows.
enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings → Login Items.
    case requiresApproval
    /// The system can't find the app as a login item, e.g. it's running from a disk image.
    case notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        case .notRegistered: self = .disabled
        @unknown default: self = .disabled
        }
    }

    /// Whether the user asked for it, approved yet or not, which is what the toggle shows.
    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

/// Wraps `SMAppService` so tests can stand in for the system.
@MainActor
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class MainAppLoginItem: LoginItemService {
    var status: LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The login item's state as Settings shows it.
///
/// The system is the source of truth, not `AppSettings.launchAtLogin`: the user can remove the
/// item in System Settings at any time, so every refresh copies the real status back.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: LoginItemStatus
    private(set) var errorMessage: String? = nil

    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let model: AppModel

    init(service: any LoginItemService = MainAppLoginItem(), model: AppModel) {
        self.service = service
        self.model = model
        status = service.status
        syncSettings()
    }

    var isOn: Bool { status.isRegistered }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        let status = service.status
        if status != self.status { self.status = status }
        syncSettings()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private func syncSettings() {
        let isOn = status.isRegistered
        model.updateSettings { $0.launchAtLogin = isOn }
    }
}
