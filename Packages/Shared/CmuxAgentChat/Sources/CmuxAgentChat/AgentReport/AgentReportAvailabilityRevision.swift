/// Monotonic ordering authority for content-free availability snapshots.
public struct AgentReportAvailabilityRevision: Sendable, Equatable, Hashable, Comparable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let rawValue: UInt64

    /// A diagnostic description that omits the ordering value.
    public var description: String { "AgentReportAvailabilityRevision" }

    /// A diagnostic description that omits the ordering value.
    public var debugDescription: String { description }

    public static func < (
        lhs: AgentReportAvailabilityRevision,
        rhs: AgentReportAvailabilityRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
