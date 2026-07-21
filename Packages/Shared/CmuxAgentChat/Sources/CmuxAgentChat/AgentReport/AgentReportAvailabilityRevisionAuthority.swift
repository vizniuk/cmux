import os

/// Generates ordered availability revisions across actor and main-actor domains.
///
/// A single injected instance is shared by the report actor and its host. The
/// host can therefore synchronously advance a barrier before replacement
/// exposure without waiting for the actor. At the practically unreachable
/// `UInt64.max`, the authority saturates and future acceptance fails closed.
public final class AgentReportAvailabilityRevisionAuthority: Sendable {
    // A synchronous counter is required because lifecycle revocation cannot suspend.
    private let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// Creates an independent process-local revision authority.
    public init() {}

    /// Advances and returns the next monotonic revision.
    ///
    /// - Returns: A revision newer than every value previously returned, or
    ///   the saturated maximum after practical exhaustion.
    public func advance() -> AgentReportAvailabilityRevision {
        counter.withLock { value in
            if value < UInt64.max {
                value += 1
            }
            return AgentReportAvailabilityRevision(rawValue: value)
        }
    }
}
