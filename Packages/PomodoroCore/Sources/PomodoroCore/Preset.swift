import Foundation

public struct Preset: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var profile: TimerProfile

    public init(id: UUID = UUID(), name: String, profile: TimerProfile) {
        self.id = id
        self.name = name
        self.profile = profile
    }

    /// "Classic 25/5/15".
    public var displayName: String { "\(name) \(profile.summary)" }

    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    // Fixed IDs keep the default selection stable across launches and reinstalls.
    public static let classic = Preset(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Classic", profile: .classic)
    public static let deep = Preset(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Deep", profile: .deep)
    public static let quick = Preset(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Quick", profile: .quick)

    public static let builtIns: [Preset] = [classic, deep, quick]

    public static let untitledName = "Untitled"

    static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledName : trimmed
    }
}
