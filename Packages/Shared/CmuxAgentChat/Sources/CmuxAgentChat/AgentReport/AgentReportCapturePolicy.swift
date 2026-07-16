/// Process-local enablement policy for private exact-report capture.
///
/// Production composition uses the default-disabled value. The policy is
/// injected into ``AgentReportCaptureStore`` so tests can opt in without a
/// persistent preference or environment-variable override.
public struct AgentReportCapturePolicy: Sendable, Equatable {
    /// Whether capture work and retention are permitted.
    public let isEnabled: Bool

    /// Creates a policy whose default deliberately prevents all capture work.
    ///
    /// - Parameter isEnabled: Whether private capture and retention are permitted.
    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    /// The production-safe disabled policy.
    public static let disabled = AgentReportCapturePolicy()

    /// An enabled policy intended for dependency injection and tests until a
    /// later slice wires the app's existing settings system.
    public static let enabled = AgentReportCapturePolicy(isEnabled: true)
}
