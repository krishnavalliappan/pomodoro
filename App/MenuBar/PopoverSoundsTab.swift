import PomodoroCore
import SwiftUI

/// The ambient mix: a grid of sounds to layer, a master volume, and a way to stop them all.
///
/// Reads the settings' mix and the player's state, neither of which the 1 Hz tick touches.
struct PopoverSoundsTab: View {
    static let columns = 3
    /// Offered on right-click; levels are coarse on purpose, the master volume does the rest.
    static let levels: [Double] = [0.25, 0.5, 0.75, 1]

    var model: AppModel

    private var mix: AmbientMix { model.ambientMix }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ambient sounds")
                    .font(.title3.weight(.semibold))
                Text(Self.caption(mix: mix, sounds: model.availableAmbientSounds, isPlaying: model.isAmbientPlaying))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: Self.columns), spacing: 10) {
                ForEach(model.availableAmbientSounds) { sound in
                    SoundTile(
                        sound: sound,
                        isOn: mix.contains(sound.id),
                        isPreviewing: model.previewingAmbient == sound.id,
                        level: mix.level(for: sound.id),
                        tap: { model.tapAmbient(sound.id) },
                        setLevel: { model.setAmbientLevel($0, for: sound.id) }
                    )
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { mix.volume }, set: { model.setAmbientVolume($0) }), in: AmbientMix.volumeRange)
                    .controlSize(.small)
                    .tint(PopoverStyle.accent)
                    .accessibilityLabel("Ambient volume")
                Button(action: model.stopAllAmbient) {
                    Text("Stop all").padding(.horizontal, 12)
                }
                .buttonStyle(SoftButtonStyle(height: 26))
                .fixedSize()
                .disabled(mix.isEmpty && model.previewingAmbient == nil)
            }
        }
    }

    /// "Rain + Forest · playing", or a hint while nothing is picked.
    static func caption(mix: AmbientMix, sounds: [AmbientSound], isPlaying: Bool) -> String {
        guard !mix.isEmpty else { return "Tap sounds to mix them. They play during focus." }
        let titles = Dictionary(uniqueKeysWithValues: sounds.map { ($0.id, $0.title) })
        let names = mix.sounds.compactMap { titles[$0] }.joined(separator: " + ")
        return "\(names) · \(isPlaying ? "playing" : "plays during focus")"
    }
}

private struct SoundTile: View {
    static let diameter: CGFloat = 48

    var sound: AmbientSound
    var isOn: Bool
    var isPreviewing: Bool
    var level: Double
    var tap: @MainActor () -> Void
    var setLevel: @MainActor (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(PopoverStyle.accent) : AnyShapeStyle(PopoverStyle.surface))
                    Circle()
                        .strokeBorder(PopoverStyle.accent.opacity(isOn || isPreviewing ? 0.35 : 0), lineWidth: 2)
                        .padding(-4)
                    Image(systemName: sound.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                .frame(width: Self.diameter, height: Self.diameter)
                .padding(4)
                Text(sound.title)
                    .font(.caption)
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOn)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isPreviewing)
        .contextMenu {
            Picker("Level", selection: Binding(get: { level }, set: { setLevel($0) })) {
                ForEach(PopoverSoundsTab.levels, id: \.self) { level in
                    Text(level.formatted(.percent)).tag(level)
                }
            }
            .pickerStyle(.inline)
        }
        .help(isOn ? "Turn off \(sound.title). Right-click to set its level." : "Turn on \(sound.title)")
        .accessibilityLabel(sound.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
