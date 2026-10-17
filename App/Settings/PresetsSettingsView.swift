import PomodoroCore
import SwiftUI

struct PresetsSettingsView: View {
    var model: AppModel

    @State private var selection: Preset.ID?
    @State private var editing: PresetDraft?

    private var presets: [Preset] { model.settings.presets }
    private var selected: Preset? { selection.flatMap(model.settings.preset(id:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(presets) { preset in
                        PresetListRow(
                            preset: preset,
                            isDefault: preset.id == model.settings.defaultPresetID,
                            makeDefault: { makeDefault(preset.id) }
                        )
                        .tag(preset.id)
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        model.updateSettings { $0.movePreset(fromOffset: from, toOffset: destination) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: Preset.ID.self) { ids in
                    if let id = ids.first {
                        Button("Edit…") { edit(id) }
                        Button("Make Default") { makeDefault(id) }
                            .disabled(id == model.settings.defaultPresetID)
                        Divider()
                        Button("Delete") { delete(id) }
                            .disabled(presets.count <= 1)
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .onDeleteCommand {
                    if let selection { delete(selection) }
                }
                listControls
            }
            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Text("The starred preset is your default. Popover chips only change the next session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Restore Built-ins") {
                    model.updateSettings { $0.restoreBuiltInPresets() }
                }
                .disabled(Preset.builtIns.allSatisfy { builtIn in presets.contains { $0.id == builtIn.id } })
                .help("Add back Classic, Deep and Quick if you deleted them")
            }
        }
        .padding(20)
        .sheet(item: $editing) { draft in
            PresetEditor(draft: draft, onCancel: { editing = nil }, onSave: save)
        }
    }

    private var listControls: some View {
        HStack(spacing: 0) {
            Button {
                editing = PresetDraft(name: "New Preset", profile: model.settings.defaultProfile)
            } label: {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .help("Add a preset")
            .accessibilityLabel("Add preset")
            Divider().frame(height: 16)
            Button {
                if let selection { delete(selection) }
            } label: {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .disabled(selected == nil || presets.count <= 1)
            .help(presets.count <= 1 ? "You need at least one preset" : "Delete the selected preset")
            .accessibilityLabel("Delete preset")
            Spacer()
            HStack(spacing: 14) {
                Button("Make Default") {
                    if let selection { makeDefault(selection) }
                }
                .disabled(selected == nil || selection == model.settings.defaultPresetID)
                Button("Edit…") {
                    if let selection { edit(selection) }
                }
                .disabled(selected == nil)
            }
            .padding(.trailing, 8)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private func makeDefault(_ id: Preset.ID) {
        model.updateSettings { try? $0.setDefaultPreset(id: id) }
    }

    private func edit(_ id: Preset.ID) {
        guard let preset = model.settings.preset(id: id) else { return }
        editing = PresetDraft(preset)
    }

    private func delete(_ id: Preset.ID) {
        model.updateSettings { try? $0.deletePreset(id: id) }
        if selection == id { selection = nil }
    }

    private func save(_ draft: PresetDraft) {
        editing = nil
        if let id = draft.presetID {
            model.updateSettings { try? $0.updatePreset(Preset(id: id, name: draft.name, profile: draft.profile)) }
        } else {
            var added: Preset?
            model.updateSettings { added = $0.addPreset(name: draft.name, profile: draft.profile) }
            selection = added?.id
        }
    }
}

struct PresetListRow: View {
    var preset: Preset
    var isDefault: Bool
    var makeDefault: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: makeDefault) {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .foregroundStyle(isDefault ? AnyShapeStyle(Color(nsColor: .systemYellow)) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.borderless)
            .disabled(isDefault)
            .help(isDefault ? "Default preset" : "Make default")
            .accessibilityLabel(isDefault ? "Default preset" : "Make \(preset.name) the default")
            Text(preset.name)
                .lineLimit(1)
            if isDefault {
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(preset.profile.summary)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A preset being added (`presetID == nil`) or edited.
struct PresetDraft: Identifiable, Equatable {
    var id = UUID()
    var presetID: Preset.ID?
    var name: String
    var profile: TimerProfile

    init(name: String, profile: TimerProfile) {
        self.name = name
        self.profile = profile
    }

    init(_ preset: Preset) {
        presetID = preset.id
        name = preset.name
        profile = preset.profile
    }
}

struct PresetEditor: View {
    static let size = CGSize(width: 340, height: 310)

    @State var draft: PresetDraft
    var onCancel: () -> Void
    var onSave: (PresetDraft) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name)
                MinutesField(title: "Focus", minutes: minutes(\.focusDuration))
                MinutesField(title: "Short break", minutes: minutes(\.shortBreakDuration))
                MinutesField(title: "Long break", minutes: minutes(\.longBreakDuration))
                LabeledContent("Long break after") {
                    HStack(spacing: 6) {
                        Text(draft.profile.longBreakEvery == 1 ? "every focus" : "\(draft.profile.longBreakEvery) focuses")
                            .monospacedDigit()
                        Stepper("Long break after", value: $draft.profile.longBreakEvery, in: TimerProfile.longBreakEveryRange)
                            .labelsHidden()
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(draft.presetID == nil ? "Add" : "Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func minutes(_ keyPath: WritableKeyPath<TimerProfile, TimeInterval>) -> Binding<Int> {
        $draft.profile[dynamicMember: keyPath].minutes
    }
}
