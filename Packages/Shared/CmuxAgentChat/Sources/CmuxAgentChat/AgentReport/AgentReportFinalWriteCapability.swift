import os

/// Synchronous, content-free validity bit for one exact retained report.
final class AgentReportFinalWriteCapability: Sendable {
    // The final pasteboard gate cannot suspend to re-enter the report actor.
    private let validity = OSAllocatedUnfairLock(initialState: true)

    /// Whether this exact report remains the actor's copy-authorized latest report.
    var isValid: Bool {
        validity.withLock { $0 }
    }

    /// Permanently revokes this report's final-write authority.
    func invalidate() {
        validity.withLock { $0 = false }
    }
}
