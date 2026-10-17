import Foundation

public struct QuickAddResult: Sendable, Equatable {
    public var title: String
    public var estimate: Int?
    public var tag: String?
    /// The scheduled day in the parser's calendar. Set whenever `blockStart` is.
    public var day: CivilDay?
    public var blockStart: Date?
    public var blockDuration: TimeInterval?

    public init(
        title: String,
        estimate: Int? = nil,
        tag: String? = nil,
        day: CivilDay? = nil,
        blockStart: Date? = nil,
        blockDuration: TimeInterval? = nil
    ) {
        self.title = title
        self.estimate = estimate
        self.tag = tag
        self.day = day
        self.blockStart = blockStart
        self.blockDuration = blockDuration
    }
}
