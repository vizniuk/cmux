public import Foundation

/// User-visible checked-out branch text plus an opaque refresh revision.
///
/// Diagnostics deliberately omit the branch and repository path.
public struct GitBranchDisplaySnapshot: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// Normal branch name, or `detached@abcdef1` for detached HEAD.
    public let displayName: String

    /// Content-free identity for this resolver result.
    public let revision: UUID

    /// Content-free diagnostic description.
    public var description: String { "GitBranchDisplaySnapshot" }

    /// Content-free diagnostic description.
    public var debugDescription: String { description }

    /// Creates one transient branch-display snapshot.
    public init(displayName: String, revision: UUID = UUID()) {
        self.displayName = displayName
        self.revision = revision
    }
}
