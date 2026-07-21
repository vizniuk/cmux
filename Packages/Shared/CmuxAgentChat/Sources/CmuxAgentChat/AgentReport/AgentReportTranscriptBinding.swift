import CryptoKit
import Foundation

/// Opaque immutable identity for one descriptor-pinned transcript.
///
/// The full SHA-256 digest is retained only as private authorization metadata.
/// Neither the canonical path, file identity, nor digest bytes appear in
/// diagnostic output.
public struct AgentReportTranscriptBinding: Sendable, Equatable, Hashable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let digest: SHA256.Digest

    /// A diagnostic description containing no path or digest material.
    public var description: String { "AgentReportTranscriptBinding" }

    /// A diagnostic description containing no path or digest material.
    public var debugDescription: String { description }

    /// Derives an opaque binding from resolver-proven transcript identity.
    ///
    /// The caller must use the canonical path and file identity obtained from
    /// the exact descriptor that passed trusted-open validation. This
    /// initializer performs no filesystem access of its own.
    ///
    /// - Parameters:
    ///   - descriptorPinnedCanonicalPath: Canonical path selected by the
    ///     trusted descriptor resolver.
    ///   - fileSystemDevice: Device identifier proven by `fstat`.
    ///   - fileSystemInode: File identifier proven by `fstat`.
    @_spi(AgentReportTranscript)
    public init(
        descriptorPinnedCanonicalPath: String,
        fileSystemDevice: UInt64,
        fileSystemInode: UInt64
    ) {
        var identity = Data("cmux.agent-report.transcript-authority.v1".utf8)
        identity.append(0)
        identity.append(contentsOf: descriptorPinnedCanonicalPath.utf8)
        identity.append(0)
        identity.append(contentsOf: String(fileSystemDevice).utf8)
        identity.append(0)
        identity.append(contentsOf: String(fileSystemInode).utf8)
        digest = SHA256.hash(data: identity)
    }

    /// Creates deterministic opaque authority for package behavior tests.
    init(testIdentity: String) {
        var identity = Data("cmux.agent-report.test-transcript-authority.v1".utf8)
        identity.append(0)
        identity.append(contentsOf: testIdentity.utf8)
        digest = SHA256.hash(data: identity)
    }
}
