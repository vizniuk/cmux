/// Monotonic, content-free ordering identity for one report capture attempt.
///
/// ``AgentReportCaptureStore`` allocates tokens before the first suspension and
/// never reuses an ordinal. The raw ordinal is intentionally not exposed;
/// callers may compare tokens but diagnostics reveal no ordering or identity.
public struct AgentReportCaptureAttemptToken: Sendable, Hashable, Comparable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let ordinal: UInt64

    /// Creates a deterministic ordering value for cross-module authority fixtures.
    ///
    /// Production capture flow obtains tokens only from ``AgentReportCaptureStore``.
    /// - Parameter orderingValue: Nonzero deterministic fixture ordering value.
    @_spi(AgentReportTranscript)
    public init(orderingValue: UInt64) {
        ordinal = orderingValue
    }

    init(ordinal: UInt64) {
        self.ordinal = ordinal
    }

    /// A diagnostic description containing no capture ordering information.
    public var description: String { "AgentReportCaptureAttemptToken" }

    /// A diagnostic description containing no capture ordering information.
    public var debugDescription: String { description }

    /// Compares actor-issued capture order without exposing the underlying value.
    ///
    /// - Parameters:
    ///   - lhs: Earlier candidate token.
    ///   - rhs: Later candidate token.
    /// - Returns: `true` only when `lhs` was allocated before `rhs`.
    public static func < (
        lhs: AgentReportCaptureAttemptToken,
        rhs: AgentReportCaptureAttemptToken
    ) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}
