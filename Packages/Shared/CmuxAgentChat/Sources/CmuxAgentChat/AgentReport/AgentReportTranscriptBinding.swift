import CryptoKit
import Foundation

/// Opaque immutable identity for a validated transcript path.
///
/// The full SHA-256 digest is retained only as private authorization metadata.
/// Neither the normalized path nor digest bytes appear in diagnostic output.
public struct AgentReportTranscriptBinding: Sendable, Equatable, Hashable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let digest: SHA256.Digest

    /// A diagnostic description containing no path or digest material.
    public var description: String { "AgentReportTranscriptBinding" }

    /// A diagnostic description containing no path or digest material.
    public var debugDescription: String { description }

    /// Derives an opaque binding from an already validated transcript path.
    ///
    /// This uses the same tilde expansion and standardized-file-URL spelling
    /// contract as the app's hook-store routing equality. It grants no file
    /// access and performs no filesystem read.
    ///
    /// - Parameter validatedTranscriptPath: Validated recorded transcript path.
    public init(validatedTranscriptPath: String) {
        let normalizedPath = URL(
            fileURLWithPath: (validatedTranscriptPath as NSString).expandingTildeInPath
        ).standardizedFileURL.path
        digest = SHA256.hash(data: Data(normalizedPath.utf8))
    }
}
