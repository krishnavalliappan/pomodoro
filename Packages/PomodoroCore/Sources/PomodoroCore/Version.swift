import Foundation

public struct Version: Sendable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static let current = Version(major: 0, minor: 1, patch: 0)

    public var description: String { "\(major).\(minor).\(patch)" }
}
