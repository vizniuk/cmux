import Foundation

/// Content-free UI availability for the latest authorized report per surface.
///
/// The snapshot intentionally carries only runtime topology identities. Report
/// bodies, provider/session/turn metadata, timestamps, and capture diagnostics
/// remain actor-owned and never enter observation payloads.
public struct AgentReportAvailabilitySnapshot: Sendable, Equatable {
    /// Whether the process-local capture policy is currently enabled.
    public let isCaptureEnabled: Bool

    /// Exact runtime surfaces whose latest report remains in the same live
    /// lifecycle generation in which it was captured.
    ///
    /// Workspace ownership is deliberately excluded. A live surface can move
    /// between workspaces without changing its report identity; callers must
    /// revalidate the represented workspace against current app topology.
    public let availableRuntimeSurfaceIDs: Set<UUID>

    /// Creates a content-free availability snapshot.
    ///
    /// - Parameters:
    ///   - isCaptureEnabled: Current process-local capture policy.
    ///   - availableRuntimeSurfaceIDs: Exact surfaces with available reports.
    public init(
        isCaptureEnabled: Bool,
        availableRuntimeSurfaceIDs: Set<UUID>
    ) {
        self.isCaptureEnabled = isCaptureEnabled
        self.availableRuntimeSurfaceIDs = availableRuntimeSurfaceIDs
    }

    /// Returns whether one exact represented surface currently has a report.
    ///
    /// - Parameters:
    ///   - runtimeSurfaceID: Exact process-local surface identity.
    /// - Returns: `true` only when that surface has a lifecycle-valid report.
    public func hasReport(runtimeSurfaceID: UUID) -> Bool {
        isCaptureEnabled
            && availableRuntimeSurfaceIDs.contains(runtimeSurfaceID)
    }
}
