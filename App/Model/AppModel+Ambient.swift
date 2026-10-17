import Foundation
import PomodoroCore

/// The ambient mix, for the Sounds tab (#44) to bind to. Edits save through `updateSettings`,
/// which hands the new mix to the player; the timer decides when it's heard.
extension AppModel {
    var ambientMix: AmbientMix { settings.ambient }

    var ambientPolicy: AmbientPolicy { settings.ambientPolicy }

    /// Every bundled sound, in library order, with its title, SF Symbol and credit.
    var availableAmbientSounds: [AmbientSound] { ambient.library.sounds }

    /// The sound a preview is playing, if any.
    var previewingAmbient: AmbientSound.ID? { ambient.previewing }

    /// Adds or removes a layer. Past `AmbientMix.maxLayers` the oldest one goes.
    func toggleAmbient(_ id: AmbientSound.ID) {
        guard ambient.library.sound(id: id) != nil else { return }
        updateSettings { $0.ambient.toggle(id) }
    }

    /// The master volume, 0…1.
    func setAmbientVolume(_ volume: Double) {
        updateSettings { $0.ambient.volume = volume }
    }

    /// One layer's level under the master volume, 0…1.
    func setAmbientLevel(_ level: Double, for id: AmbientSound.ID) {
        guard ambient.library.sound(id: id) != nil else { return }
        updateSettings { $0.ambient.setLevel(level, for: id) }
    }

    func setAmbientBreakBehavior(_ behavior: AmbientBreakBehavior) {
        updateSettings { $0.ambientPolicy.duringBreaks = behavior }
    }

    /// Plays a sound for a few seconds, even with the timer idle.
    func previewAmbient(_ id: AmbientSound.ID) {
        ambient.preview(id)
    }

    func stopAmbientPreview() {
        ambient.stopPreview()
    }
}
