import AppKit
import PomodoroCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case timer, presets, sounds, menuBar, shortcuts, general

    static let width: CGFloat = 460
    /// Extra height while the save-error banner shows, so it never pushes a pane's content out.
    static let bannerHeight: CGFloat = 80

    var id: Self { self }

    var title: String {
        switch self {
        case .timer: "Timer"
        case .presets: "Presets"
        case .sounds: "Sounds"
        case .menuBar: "Menu Bar"
        case .shortcuts: "Shortcuts"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .timer: "timer"
        case .presets: "square.stack"
        case .sounds: "speaker.wave.2"
        case .menuBar: "menubar.rectangle"
        case .shortcuts: "command"
        case .general: "gearshape"
        }
    }

    var size: CGSize {
        let height: CGFloat =
            switch self {
            case .timer: 550
            case .presets: 330
            case .sounds: 300
            case .menuBar: 170
            case .shortcuts: 240
            case .general: 210
            }
        return CGSize(width: Self.width, height: height)
    }
}

/// One tab's content at its fixed size, with the save-error banner above it.
struct SettingsPaneView: View {
    var pane: SettingsPane
    var model: AppModel
    var launchAtLogin: LaunchAtLogin

    var body: some View {
        VStack(spacing: 0) {
            SettingsBanner(model: model)
            content
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: pane.size.width, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var height: CGFloat {
        pane.size.height + (model.settingsSaveError == nil ? 0 : SettingsPane.bannerHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .timer: TimerSettingsView(model: model)
        case .presets: PresetsSettingsView(model: model)
        case .sounds: SoundSettingsView(model: model)
        case .menuBar: MenuBarSettingsView(model: model)
        case .shortcuts: ShortcutsSettingsView()
        case .general: GeneralSettingsView(model: model, launchAtLogin: launchAtLogin)
        }
    }
}

/// Non-modal: edits still apply for this run, so the user can keep working and just be told.
struct SettingsBanner: View {
    var model: AppModel

    var body: some View {
        if let error = model.settingsSaveError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.localizedDescription)
                    Text("Changes you make here apply until you quit but won't be saved.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    model.dismissSettingsSaveError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .font(.callout)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .systemOrange).opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .systemOrange).opacity(0.3)))
            .padding([.horizontal, .top], 16)
        }
    }
}

@MainActor
enum SettingsWindow {
    /// A toolbar-style tab controller: the native preferences look, resizing to each tab.
    static func make(model: AppModel, launchAtLogin: LaunchAtLogin) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane, model: model, launchAtLogin: launchAtLogin))
            host.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        return window
    }
}
