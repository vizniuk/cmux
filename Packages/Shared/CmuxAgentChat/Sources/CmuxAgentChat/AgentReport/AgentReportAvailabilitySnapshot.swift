import Foundation

/// Content-free UI availability for the latest authorized report per surface.
///
/// The snapshot intentionally carries only runtime topology identities. Report
/// bodies, provider/session/turn metadata, timestamps, and capture diagnostics
/// remain actor-owned and never enter observation payloads.
public struct AgentReportAvailabilitySnapshot: Sendable, Equatable {
    /// Whether the process-local capture policy is currently enabled.
    public let isCaptureEnabled: Bool

    /// Exact workspace owner for each surface whose latest report remains in
    /// the same live lifecycle generation in which it was captured.
    public let workspaceIDByRuntimeSurfaceID: [UUID: UUID]

    /// Creates a content-free availability snapshot.
    ///
    /// - Parameters:
    ///   - isCaptureEnabled: Current process-local capture policy.
    ///   - workspaceIDByRuntimeSurfaceID: Exact available surface ownership.
    public init(
        isCaptureEnabled: Bool,
        workspaceIDByRuntimeSurfaceID: [UUID: UUID]
    ) {
        self.isCaptureEnabled = isCaptureEnabled
        self.workspaceIDByRuntimeSurfaceID = workspaceIDByRuntimeSurfaceID
    }

    /// Returns whether one exact represented surface currently has a report.
    ///
    /// - Parameters:
    ///   - runtimeSurfaceID: Exact process-local surface identity.
    ///   - workspaceID: Exact current workspace representing that surface.
    /// - Returns: `true` only for a matching available topology tuple.
    public func hasReport(runtimeSurfaceID: UUID, workspaceID: UUID) -> Bool {
        isCaptureEnabled
            && workspaceIDByRuntimeSurfaceID[runtimeSurfaceID] == workspaceID
    }
}
