import PomodoroCore
import SwiftUI

struct MenuBarSettingsView: View {
    var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: model.binding(\.menuBarDisplay)) {
                    ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                MenuBarPreview(mode: model.settings.menuBarDisplay)
                    .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
    }
}

/// A mock menu bar strip showing what the title looks like mid-focus.
struct MenuBarPreview: View {
    static let sampleTask = "Write the spec"

    /// Focus with 18:42 left.
    static let sample: TimerSnapshot = {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let engine = TimerEngine(clock: TestClock(now: start))
        _ = engine.start(phase: .focus)
        return engine.snapshot(at: start + 6 * 60 + 18)
    }()

    var mode: MenuBarDisplayMode

    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Group {
                if let title = MenuBarTitle.text(for: Self.sample, mode: mode, taskTitle: Self.sampleTask) {
                    Text(title)
                        .font(Font(MenuBarController.titleFont as CTFont))
                } else {
                    Image(systemName: MenuBarController.symbol(for: Self.sample))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.primary.opacity(0.12)))
            Image(systemName: "wifi")
                .foregroundStyle(.secondary)
            Text("Sat 9:41")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview")
    }
}
