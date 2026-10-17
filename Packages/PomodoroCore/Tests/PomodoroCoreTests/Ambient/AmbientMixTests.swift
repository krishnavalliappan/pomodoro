import Foundation
import Testing
@testable import PomodoroCore

struct AmbientMixTests {
    @Test func defaultsToSilence() {
        let mix = AmbientMix()
        #expect(mix.isEmpty)
        #expect(mix.volume == AmbientMix.defaultVolume)
        #expect(mix.volume(for: "rain") == 0)
        #expect(mix.level(for: "rain") == AmbientMix.defaultLevel)
    }

    @Test func togglesInActivationOrder() {
        var mix = AmbientMix()
        mix.toggle("rain")
        mix.toggle("forest")
        #expect(mix.sounds == ["rain", "forest"])
        mix.toggle("rain")
        #expect(mix.sounds == ["forest"])
        mix.setActive("forest", true)
        #expect(mix.sounds == ["forest"], "switching on an active sound changes nothing")
        mix.setActive("waves", false)
        #expect(mix.sounds == ["forest"])
    }

    @Test func removeAllKeepsLevelsAndVolume() {
        var mix = AmbientMix(sounds: ["rain", "forest"], levels: ["rain": 0.5], volume: 0.4)
        mix.removeAll()
        #expect(mix.isEmpty)
        #expect(mix.level(for: "rain") == 0.5)
        #expect(mix.volume == 0.4)
        mix.toggle("rain")
        #expect(mix.volume(for: "rain") == 0.2, "a sound coming back plays at its old level")
    }

    @Test func layersPastTheLimitDropTheOldest() {
        var mix = AmbientMix()
        for id in ["a", "b", "c", "d", "e"] { mix.toggle(id) }
        #expect(mix.sounds.count == AmbientMix.maxLayers)
        #expect(mix.sounds == ["b", "c", "d", "e"])
    }

    @Test func volumeIsLevelUnderMaster() {
        var mix = AmbientMix(sounds: ["rain", "forest"], volume: 0.5)
        mix.setLevel(0.4, for: "rain")
        #expect(mix.volume(for: "rain") == 0.2)
        #expect(mix.volume(for: "forest") == 0.5)
        mix.toggle("rain")
        #expect(mix.volume(for: "rain") == 0)
        #expect(mix.level(for: "rain") == 0.4, "a level outlives switching the sound off")
    }

    @Test func clampsVolumesAndLevels() {
        var mix = AmbientMix(volume: 3)
        #expect(mix.volume == 1)
        mix.volume = -1
        #expect(mix.volume == 0)
        mix.volume = .nan
        #expect(mix.volume == AmbientMix.defaultVolume)
        mix.setLevel(2, for: "rain")
        #expect(mix.level(for: "rain") == 1)
        mix.setLevel(.infinity, for: "rain")
        #expect(mix.level(for: "rain") == AmbientMix.defaultLevel)
        #expect(mix.levels.isEmpty, "a default level isn't stored")
    }

    @Test func initDropsDuplicatesAndKeepsTheNewestLayers() {
        let mix = AmbientMix(sounds: ["a", "a", "b", "c", "d", "e"], levels: ["a": .nan, "b": 0.5, "c": 1])
        #expect(mix.sounds == ["b", "c", "d", "e"])
        #expect(mix.levels == ["b": 0.5])
    }

    @Test func restrictsToAKnownLibrary() {
        var mix = AmbientMix(sounds: ["rain", "gone"], volume: 0.3)
        mix.setLevel(0.5, for: "gone")
        let restricted = mix.restricted(to: ["rain", "forest"])
        #expect(restricted.sounds == ["rain"])
        #expect(restricted.levels.isEmpty)
        #expect(restricted.volume == 0.3)
    }

    @Test func codableRoundTrip() throws {
        var mix = AmbientMix(sounds: ["rain", "cafe"], volume: 0.45)
        mix.setLevel(0.7, for: "cafe")
        let decoded = try JSONDecoder().decode(AmbientMix.self, from: try JSONEncoder().encode(mix))
        #expect(decoded == mix)
    }

    @Test func decodingIsLenientPerField() throws {
        let data = Data(#"{"sounds": "rain", "levels": {"rain": 0.5}, "volume": 9}"#.utf8)
        let mix = try JSONDecoder().decode(AmbientMix.self, from: data)
        #expect(mix.sounds.isEmpty)
        #expect(mix.levels == ["rain": 0.5])
        #expect(mix.volume == 1)
    }
}
