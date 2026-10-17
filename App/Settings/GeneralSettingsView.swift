import AppKit
import PomodoroCore
import SwiftUI

struct GeneralSettingsView: View {
    var model: AppModel
    var launchAtLogin: LaunchAtLogin
    var calendar = Calendar.current

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.setEnabled($0) }))
                loginStatus
            }
            Section {
                Picker("First day of week", selection: model.binding(\.firstWeekday)) {
                    Text("System (\(weekdayName(calendar.firstWeekday)))").tag(Int?.none)
                    Divider()
                    ForEach(1...7, id: \.self) { day in
                        Text(weekdayName(day)).tag(Int?.some(day))
                    }
                }
            }
            Section {
                LabeledContent("About", value: "Pomodoro \(Version.current.description)")
            }
        }
        .formStyle(.grouped)
        // The user can change the login item in System Settings while this window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
        .onAppear { launchAtLogin.refresh() }
    }

    @ViewBuilder
    private var loginStatus: some View {
        switch launchAtLogin.status {
        case .requiresApproval:
            HStack(alignment: .firstTextBaseline) {
                Label("Allow Pomodoro in Login Items to finish turning this on.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings…", action: launchAtLogin.openSystemSettings)
            }
            .font(.callout)
        case .notFound:
            Text("macOS can't find Pomodoro as a login item. Move it to Applications and try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .enabled, .disabled:
            EmptyView()
        }
        if let message = launchAtLogin.errorMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(Color(nsColor: .systemRed))
        }
    }

    private func weekdayName(_ day: Int) -> String {
        let symbols = calendar.weekdaySymbols
        return symbols.indices.contains(day - 1) ? symbols[day - 1] : "\(day)"
    }
}
