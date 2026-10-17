import PomodoroCore
import SwiftUI

struct SoundSettingsView: View {
    static let choices: [SoundID] = SoundID.allCases.filter { $0 != .none }

    var model: AppModel

    @State private var showsCredits = false

    var body: some View {
        Form {
            Section {
                ForEach(SoundEvent.allCases, id: \.self) { event in
                    row(for: event)
                }
            }
            Section {
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                        Slider(value: model.binding(\.sounds.volume), in: SoundSettings.volumeRange)
                            .labelsHidden()
                            .accessibilityLabel("Volume")
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 220)
                }
            }
            Section("Ambient") {
                Picker("During breaks", selection: Binding(
                    get: { model.ambientPolicy.duringBreaks },
                    set: { model.setAmbientBreakBehavior($0) }
                )) {
                    ForEach(AmbientBreakBehavior.allCases, id: \.self) { behavior in
                        Text(Self.title(behavior)).tag(behavior)
                    }
                }
                LabeledContent("Sound credits") {
                    Button("Show…") { showsCredits = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsCredits) {
            SoundCreditsView(sounds: model.availableAmbientSounds) { showsCredits = false }
        }
    }

    static func title(_ behavior: AmbientBreakBehavior) -> String {
        switch behavior {
        case .off: "Pause"
        case .lower: "Play quieter"
        case .keep: "Keep playing"
        }
    }

    private func row(for event: SoundEvent) -> some View {
        let selection = model.binding(event.settingsPath)
        return LabeledContent(event.title) {
            HStack(spacing: 6) {
                Picker(event.title, selection: selection) {
                    ForEach(Self.choices, id: \.self) { sound in
                        Text(sound.title).tag(sound)
                    }
                    Divider()
                    Text(SoundID.none.title).tag(SoundID.none)
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    model.sound.play(selection.wrappedValue)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(selection.wrappedValue == .none || model.settings.sounds.volume == 0)
                .help("Preview")
                .accessibilityLabel("Preview \(event.title)")
            }
        }
    }
}
