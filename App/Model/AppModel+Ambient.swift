import Foundation
import PomodoroCore

/// The ambient mix, for the Sounds tab (#44) to bind to. Edits go through `updateSettings`, or
/// `adjustAmbient` for the volume, which hand the new mix to the player; the timer decides when
/// it's heard.
extension AppModel {
    var ambientMix: AmbientMix { settings.ambient }

    var ambientPolicy: AmbientPolicy { settings.ambientPolicy }

    /// Every bundled sound, in library order, with its title, SF Symbol and credit.
    var availableAmbientSounds: [AmbientSound] { ambient.library.sounds }

    /// The sound a preview is playing, if any.
    var previewingAmbient: AmbientSound.ID? { ambient.previewing }

    /// Whether ambient sound is heard now, from the mix during focus or from a preview.
    var isAmbientPlaying: Bool { ambient.isPlaying }

    /// A tile tapped in the Sounds tab. When the timer isn't playing the mix, a sound switched on
    /// plays a preview so it can be heard at once, and one switched off stops its own preview.
    func tapAmbient(_ id: AmbientSound.ID) {
        guard ambient.library.sound(id: id) != nil else { return }
        let switchingOn = !ambientMix.contains(id)
        toggleAmbient(id)
        if !switchingOn {
            // Even with focus now playing the mix, a preview from before it started would keep the sound on.
            if previewingAmbient == id { stopAmbientPreview() }
        } else if !ambient.timerPlaysMix {
            previewAmbient(id)
        }
    }

    /// Switches every sound off; their levels stay for next time.
    func stopAllAmbient() {
        stopAmbientPreview()
        updateSettings { $0.ambient.removeAll() }
    }

    /// Adds or removes a layer. Past `AmbientMix.maxLayers` the oldest one goes.
    func toggleAmbient(_ id: AmbientSound.ID) {
        guard ambient.library.sound(id: id) != nil else { return }
        updateSettings { $0.ambient.toggle(id) }
    }

    /// The master volume, 0…1. Saved once it stops moving.
    func setAmbientVolume(_ volume: Double) {
        adjustAmbient { $0.volume = volume }
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
