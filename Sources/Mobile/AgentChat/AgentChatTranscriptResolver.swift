@_spi(AgentReportTranscript) import CmuxAgentChat
import Darwin
import Foundation

/// App-target mirror of the fixed private Slice A resource contract.
///
/// `CmuxAgentChat`, the standalone CLI, and the lower control-socket package
/// cannot share internal declarations across their target boundaries. Focused
/// invariant tests pin every mirror to these byte counts.
struct AgentReportResourceLimits: Sendable, Equatable {
    static let maximumFullRunExportBytes = 8 * 1024 * 1024

    static let sliceA = AgentReportResourceLimits(
        maximumReportBodyBytes: 2 * 1024 * 1024,
        maximumJSONLRecordBytes: 8 * 1024 * 1024,
        maximumTranscriptBytes: 128 * 1024 * 1024,
        maximumAuthorizedSocketFrameBytes: 16 * 1024 * 1024
    )

    let maximumReportBodyBytes: Int
    let maximumJSONLRecordBytes: Int
    let maximumTranscriptBytes: Int
    let maximumAuthorizedSocketFrameBytes: Int

    func permitsReportBody(_ value: String) -> Bool {
        value.utf8.count <= maximumReportBodyBytes
    }
}

/// Resolves the transcript JSONL path for an agent session.
///
/// Preference order for ordinary chat history is the hook store's recorded
/// `transcriptPath`, then the agent-specific conventional location. Private
/// Codex report reads apply a stricter root-contained resolver below.
struct AgentChatTranscriptResolver: Sendable {
    /// Internal deterministic seam for trusted-open replacement regressions.
    enum TrustedOpenCheckpoint: Sendable, Equatable {
        case afterOpeningRoot
        case beforeOpeningIntermediate(Int)
        case afterOpeningIntermediate(Int)
        case beforeOpeningLeaf
        case afterOpeningLeaf
        case beforeReadingFirstChunk
        case didCloseDescriptor
    }

    private let homeDirectory: URL
    /// Config-dir root for Claude (`$CLAUDE_CONFIG_DIR` or `~/.claude`).
    private let claudeConfigRoot: URL
    /// Config-dir root for Codex (`$CODEX_HOME` or `~/.codex`).
    private let codexConfigRoot: URL
    private let reportResourceLimits: AgentReportResourceLimits
    private let trustedOpenCheckpoint: (@Sendable (TrustedOpenCheckpoint) -> Void)?

    /// Creates a resolver.
    ///
    /// The derived-path fallbacks honor the app process's config-dir env
    /// overrides so a user who relocates their config (e.g. `CLAUDE_CONFIG_DIR`
    /// or `CODEX_HOME`, including via a launcher/subrouter) still has transcripts
    /// resolved. For private report capture, `CODEX_HOME` is app-authoritative;
    /// a hook-recorded path never supplies or expands the allowed root.
    ///
    /// - Parameters:
    ///   - homeDirectory: Injectable home directory for tests.
    ///   - environment: Injectable environment for tests; defaults to the
    ///     process environment. Empty/whitespace override values are ignored.
    ///   - reportResourceLimits: Fixed production policy, injectable only for focused tests.
    ///   - trustedOpenCheckpoint: Internal deterministic replacement seam for tests.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        reportResourceLimits: AgentReportResourceLimits = .sliceA,
        trustedOpenCheckpoint: (@Sendable (TrustedOpenCheckpoint) -> Void)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.claudeConfigRoot = Self.configRoot(
            override: environment["CLAUDE_CONFIG_DIR"],
            default: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        )
        self.codexConfigRoot = Self.configRoot(
            override: environment["CODEX_HOME"],
            default: homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        )
        self.reportResourceLimits = reportResourceLimits
        self.trustedOpenCheckpoint = trustedOpenCheckpoint
    }

    /// Resolves a config-dir root from an env override, expanding a leading `~`,
    /// falling back to `defaultRoot` when the override is absent or blank.
    private static func configRoot(override: String?, default defaultRoot: URL) -> URL {
        guard let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return defaultRoot
        }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Resolves the transcript path for a session.
    ///
    /// - Parameters:
    ///   - record: The session's registry record.
    /// - Returns: An existing transcript path, or `nil` when none is found.
    func transcriptPath(for record: AgentChatSessionRecord) -> String? {
        if let recorded = recordedTranscriptPath(for: record) {
            return recorded
        }
        switch record.agentKind {
        case .claude:
            return claudeFallbackPath(record: record)
        case .codex:
            return codexFallbackPath(sessionID: record.sessionID)
        case .other:
            return nil
        }
    }

    /// Resolves a Codex rollout only inside the app-authoritative sessions root.
    ///
    /// This compatibility lookup proves the candidate through the same
    /// descriptor-pinned trusted-open flow used by report recovery, closes the
    /// descriptor, and returns only the accepted path. Recovery itself never
    /// reopens this returned string.
    ///
    /// - Parameters:
    ///   - recordedPath: Untrusted hook path to validate, when available.
    ///   - sessionID: Exact Codex session used by the fallback filename scan.
    /// - Returns: Existing exact-session rollout path, or `nil`.
    func codexTranscriptPath(recordedPath: String?, sessionID: String) -> String? {
        if let recordedPath,
           let validated = validatedCodexTranscriptPath(recordedPath) {
            return validated
        }
        return codexFallbackPath(sessionID: sessionID)
    }

    /// Resolves only paths that are cheap to check from the main-actor mobile
    /// session list path. Codex's fallback scans the full sessions tree, so it is
    /// intentionally excluded here and remains available only when opening a
    /// transcript.
    func boundedTranscriptPath(for record: AgentChatSessionRecord) -> String? {
        if let recorded = recordedTranscriptPath(for: record) {
            return recorded
        }
        switch record.agentKind {
        case .claude:
            return claudeFallbackPath(record: record)
        case .codex, .other:
            return nil
        }
    }

    private func recordedTranscriptPath(for record: AgentChatSessionRecord) -> String? {
        guard let recorded = record.transcriptPath else { return nil }
        let expanded = (recorded as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
    }

    private func claudeFallbackPath(record: AgentChatSessionRecord) -> String? {
        let fileManager = FileManager.default
        guard let cwd = record.workingDirectory else { return nil }
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        let path = claudeConfigRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDir, isDirectory: true)
            .appendingPathComponent("\(record.hookStoreLookupSessionID).jsonl", isDirectory: false)
            .path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    /// Codex rollout files are named `rollout-<timestamp>-<session-uuid>.jsonl`
    /// under `~/.codex/sessions/YYYY/MM/DD/`; scan for the exact session id.
    private func codexFallbackPath(sessionID: String) -> String? {
        firstCodexFallbackResult(sessionID: sessionID) { candidate in
            validatedCodexTranscriptPath(candidate)
        }
    }

    /// Enumerates only session-specific fallback names and returns the first
    /// result accepted by descriptor-pinned validation without accumulating paths.
    private func firstCodexFallbackResult<Result>(
        sessionID: String,
        transform: (String) -> Result?
    ) -> Result? {
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalCodexSessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let needle = sessionID.lowercased()
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl",
                  url.lastPathComponent.lowercased().contains(needle) else {
                continue
            }
            if let result = transform(url.path) {
                return result
            }
        }
        return nil
    }

    /// Configured root spelling used to derive relative paths without
    /// resolving any untrusted candidate component.
    private var configuredCodexSessionsRoot: URL {
        codexConfigRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
    }

    /// Canonical root authorized by app configuration, never by hook payload.
    private var canonicalCodexSessionsRoot: URL {
        let configuredRoot = codexConfigRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        return URL(
            fileURLWithPath: Self.canonicalFileSystemPath(configuredRoot),
            isDirectory: true
        )
    }

    /// Resolves the app-authoritative root using the filesystem's canonical
    /// spelling. Foundation can preserve `/var` while directory enumeration
    /// returns `/private/var`, so URL-only normalization is not sufficient for
    /// strict containment of descriptor-backed fallback candidates.
    private static func canonicalFileSystemPath(_ url: URL) -> String {
        let standardizedPath = url.standardizedFileURL.path
        guard let resolvedPath = standardizedPath.withCString({ pointer in
            Darwin.realpath(pointer, nil)
        }) else {
            return standardizedPath
        }
        defer { Darwin.free(resolvedPath) }
        return String(cString: resolvedPath)
    }

    /// Validates one untrusted candidate by opening and closing the exact
    /// descriptor that satisfied trusted-root, no-follow, type, and size checks.
    private func validatedCodexTranscriptPath(_ path: String) -> String? {
        guard let transcript = openTrustedCodexTranscript(path) else { return nil }
        transcript.close()
        return path
    }

    /// Opens a recorded path first, then exact-session fallback candidates.
    private func openCodexTranscript(
        recordedPath: String?,
        sessionID: String
    ) -> CompleteJSONLLineSequence? {
        if let recordedPath,
           let transcript = openTrustedCodexTranscript(recordedPath) {
            return transcript
        }
        return firstCodexFallbackResult(sessionID: sessionID) { candidate in
            openTrustedCodexTranscript(candidate)
        }
    }

    /// Traverses a candidate relative to the trusted root using descriptor-
    /// pinned `openat(2)` calls and no-follow semantics for every component.
    private func openTrustedCodexTranscript(_ path: String) -> CompleteJSONLLineSequence? {
        guard let relativeComponents = trustedRelativeComponents(for: path),
              let leaf = relativeComponents.last else {
            return nil
        }

        let rootPath = canonicalCodexSessionsRoot.path
        let rootDescriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { return nil }
        trustedOpenCheckpoint?(.afterOpeningRoot)

        var directoryDescriptor = rootDescriptor
        defer { closeTrustedDescriptor(directoryDescriptor) }

        for (index, component) in relativeComponents.dropLast().enumerated() {
            var expectedStat = stat()
            let statResult = component.withCString { pointer in
                Darwin.fstatat(
                    directoryDescriptor,
                    pointer,
                    &expectedStat,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard statResult == 0,
                  (expectedStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                return nil
            }
            trustedOpenCheckpoint?(.beforeOpeningIntermediate(index))
            let nextDescriptor = component.withCString { pointer in
                Darwin.openat(
                    directoryDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else { return nil }
            var openedStat = stat()
            guard fstat(nextDescriptor, &openedStat) == 0,
                  (openedStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  openedStat.st_dev == expectedStat.st_dev,
                  openedStat.st_ino == expectedStat.st_ino else {
                closeTrustedDescriptor(nextDescriptor)
                return nil
            }
            trustedOpenCheckpoint?(.afterOpeningIntermediate(index))
            closeTrustedDescriptor(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        var expectedLeafStat = stat()
        let leafStatResult = leaf.withCString { pointer in
            Darwin.fstatat(
                directoryDescriptor,
                pointer,
                &expectedLeafStat,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard leafStatResult == 0,
              Self.isAcceptableTranscriptStat(expectedLeafStat, limits: reportResourceLimits) else {
            return nil
        }
        trustedOpenCheckpoint?(.beforeOpeningLeaf)
        let leafDescriptor = leaf.withCString { pointer in
            Darwin.openat(
                directoryDescriptor,
                pointer,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard leafDescriptor >= 0 else { return nil }

        var ownsLeafDescriptor = true
        defer {
            if ownsLeafDescriptor {
                closeTrustedDescriptor(leafDescriptor)
            }
        }

        var openedStat = stat()
        guard fstat(leafDescriptor, &openedStat) == 0,
              Self.isAcceptableTranscriptStat(openedStat, limits: reportResourceLimits),
              openedStat.st_dev == expectedLeafStat.st_dev,
              openedStat.st_ino == expectedLeafStat.st_ino else {
            return nil
        }
        trustedOpenCheckpoint?(.afterOpeningLeaf)

        var verifiedStat = stat()
        guard fstat(leafDescriptor, &verifiedStat) == 0,
              Self.isAcceptableTranscriptStat(verifiedStat, limits: reportResourceLimits),
              verifiedStat.st_dev == openedStat.st_dev,
              verifiedStat.st_ino == openedStat.st_ino else {
            return nil
        }

        ownsLeafDescriptor = false
        let canonicalTranscriptPath = relativeComponents.reduce(
            canonicalCodexSessionsRoot
        ) { partialPath, component in
            partialPath.appendingPathComponent(component, isDirectory: false)
        }.path
        let transcriptBinding = AgentReportTranscriptBinding(
            descriptorPinnedCanonicalPath: canonicalTranscriptPath,
            fileSystemDevice: UInt64(openedStat.st_dev),
            fileSystemInode: UInt64(openedStat.st_ino)
        )
        return CompleteJSONLLineSequence(
            descriptor: leafDescriptor,
            expectedDevice: openedStat.st_dev,
            expectedInode: openedStat.st_ino,
            transcriptBinding: transcriptBinding,
            limits: reportResourceLimits,
            beforeFirstRead: { self.trustedOpenCheckpoint?(.beforeReadingFirstChunk) },
            onClose: { self.trustedOpenCheckpoint?(.didCloseDescriptor) }
        )
    }

    /// Derives a strict relative path without resolving untrusted components.
    private func trustedRelativeComponents(for path: String) -> [String]? {
        guard Self.hasStrictRawPathComponents(path) else { return nil }
        guard let candidateComponents = Self.strictAbsolutePathComponents(path),
              candidateComponents.last?.lowercased().hasSuffix(".jsonl") == true else {
            return nil
        }

        let trustedRoots = [configuredCodexSessionsRoot.path, canonicalCodexSessionsRoot.path]
        for trustedRoot in trustedRoots {
            guard let rootComponents = Self.strictAbsolutePathComponents(trustedRoot),
                  candidateComponents.count > rootComponents.count,
                  candidateComponents.starts(with: rootComponents) else {
                continue
            }
            let relative = Array(candidateComponents.dropFirst(rootComponents.count))
            guard relative.allSatisfy({ component in
                !component.isEmpty
                    && component != "."
                    && component != ".."
                    && !component.hasPrefix("/")
            }) else {
                return nil
            }
            return relative
        }
        return nil
    }

    /// Requires one leading slash and rejects unsafe raw lexical components.
    static func hasStrictRawPathComponents(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\0") else {
            return false
        }
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        let components = rawComponents.dropFirst()
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Splits an absolute path while rejecting empty, dot, and dot-dot parts.
    private static func strictAbsolutePathComponents(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        guard rawComponents.first?.isEmpty == true else { return nil }
        let components = rawComponents.dropFirst().map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components
    }

    /// Checks the final opened object without following or reopening its path.
    private static func isAcceptableTranscriptStat(
        _ value: stat,
        limits: AgentReportResourceLimits
    ) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && value.st_size >= 0
            && UInt64(value.st_size) <= UInt64(limits.maximumTranscriptBytes)
    }

    /// Closes one traversal descriptor and reports only content-free test state.
    private func closeTrustedDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        trustedOpenCheckpoint?(.didCloseDescriptor)
    }
}

extension AgentChatTranscriptResolver: AgentReportTranscriptRecovering {
    /// Renders the exact completed turn from the descriptor-selected transcript.
    ///
    /// The selected descriptor binding must equal the report's committed binding
    /// before any transcript record is exported. No path is reopened and no
    /// terminal, network, or provider fallback exists.
    func exportCodexFullRun(
        recordedPath: String?,
        sessionID: String,
        turnID: String,
        expectedBinding: AgentReportTranscriptBinding
    ) async -> AgentReportFullRunExport? {
        let resolver = self
        return await Task.detached(priority: .utility) {
            guard let lines = resolver.openCodexTranscript(
                recordedPath: recordedPath,
                sessionID: sessionID
            ), lines.transcriptBinding == expectedBinding else {
                return nil
            }
            defer { lines.close() }
            let body = CodexFullRunExporter().export(
                records: lines,
                sessionID: sessionID,
                turnID: turnID
            )
            guard !lines.didFailTrustedRead,
                  !lines.didViolateResourceLimit,
                  let body,
                  body.utf8.count <= AgentReportResourceLimits.maximumFullRunExportBytes else {
                return nil
            }
            return AgentReportFullRunExport(
                body: body,
                transcriptBinding: lines.transcriptBinding
            )
        }.value
    }

    /// Proves primary-session metadata using off-main streaming JSONL I/O.
    ///
    /// - Parameters:
    ///   - recordedPath: Untrusted hook path, accepted only after canonical
    ///     root containment and regular-file validation.
    ///   - sessionID: Exact Codex session expected in rollout metadata.
    /// - Returns: Resolver-proven authority only for a matching primary rollout.
    func validatePrimaryCodexSession(
        recordedPath: String?,
        sessionID: String
    ) async -> ValidatedCodexTranscriptAuthority? {
        let resolver = self
        return await Task.detached(priority: .utility) {
            guard let lines = resolver.openCodexTranscript(
                recordedPath: recordedPath,
                sessionID: sessionID
            ) else {
                return nil
            }
            defer { lines.close() }
            let result = CodexFinalReplyExtractor().isPrimarySession(
                records: lines,
                sessionID: sessionID
            )
            guard !lines.didFailTrustedRead,
                  !lines.didViolateResourceLimit,
                  result else {
                return nil
            }
            return ValidatedCodexTranscriptAuthority(
                transcriptBinding: lines.transcriptBinding
            )
        }.value
    }

    /// Recovers exact final assistant text using off-main streaming JSONL I/O.
    ///
    /// - Parameters:
    ///   - recordedPath: Untrusted hook path, accepted only after canonical
    ///     root containment and regular-file validation.
    ///   - sessionID: Exact Codex session expected in rollout metadata.
    ///   - turnID: Exact terminal turn to extract.
    /// - Returns: Unmodified final assistant text and exact transcript authority,
    ///   or `nil` if unprovable.
    func recoverCodexFinalReply(
        recordedPath: String?,
        sessionID: String,
        turnID: String
    ) async -> AgentReportRecoveryResult? {
        let resolver = self
        return await Task.detached(priority: .utility) {
            guard let lines = resolver.openCodexTranscript(
                recordedPath: recordedPath,
                sessionID: sessionID
            ) else {
                return nil
            }
            defer { lines.close() }
            let result = CodexFinalReplyExtractor().extract(
                records: lines,
                sessionID: sessionID,
                turnID: turnID
            )
            guard !lines.didFailTrustedRead,
                  !lines.didViolateResourceLimit,
                  let result else {
                return nil
            }
            return AgentReportRecoveryResult(
                body: result,
                transcriptBinding: lines.transcriptBinding
            )
        }.value
    }
}

/// Streams complete JSONL records without copying an entire long-lived rollout
/// into memory. The descriptor was opened by trusted `openat(2)` traversal and
/// is never reopened by path. An incomplete trailing fragment is deliberately
/// discarded at EOF.
private final class CompleteJSONLLineSequence: Sequence, IteratorProtocol {
    typealias Element = CodexTranscriptRecord

    private static let chunkSize = 64 * 1024

    private var descriptor: Int32
    private let expectedDevice: dev_t
    private let expectedInode: ino_t
    let transcriptBinding: AgentReportTranscriptBinding
    private let limits: AgentReportResourceLimits
    private let beforeFirstRead: @Sendable () -> Void
    private let onClose: @Sendable () -> Void
    private var buffer = Data()
    private var reachedEOF = false
    private var cumulativeBytesRead = 0
    private var hasStartedReading = false
    private(set) var didViolateResourceLimit = false
    private(set) var didFailTrustedRead = false

    /// Takes ownership of one already-authorized transcript descriptor.
    init(
        descriptor: Int32,
        expectedDevice: dev_t,
        expectedInode: ino_t,
        transcriptBinding: AgentReportTranscriptBinding,
        limits: AgentReportResourceLimits,
        beforeFirstRead: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.descriptor = descriptor
        self.expectedDevice = expectedDevice
        self.expectedInode = expectedInode
        self.transcriptBinding = transcriptBinding
        self.limits = limits
        self.beforeFirstRead = beforeFirstRead
        self.onClose = onClose
    }

    deinit { close() }

    func makeIterator() -> CompleteJSONLLineSequence { self }

    /// Closes the pinned descriptor exactly once.
    func close() {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
        onClose()
    }

    /// Returns the next newline-terminated record, dropping an incomplete tail.
    ///
    /// - Returns: One complete strict UTF-8 line or malformed-record event;
    ///   `nil` at safe EOF.
    func next() -> CodexTranscriptRecord? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                guard newline <= limits.maximumJSONLRecordBytes else {
                    failResourceLimit()
                    return nil
                }
                let line = String(data: Data(buffer[..<newline]), encoding: .utf8)
                buffer.removeSubrange(...newline)
                guard let line else { return .malformedCompleteRecord }
                return .jsonLine(line)
            }
            guard buffer.count <= limits.maximumJSONLRecordBytes else {
                failResourceLimit()
                return nil
            }
            guard !reachedEOF else {
                // Rollouts are append-only. Never parse or guess from a
                // concurrently written, non-newline-terminated JSON fragment.
                return nil
            }

            if !hasStartedReading {
                hasStartedReading = true
                beforeFirstRead()
            }
            guard descriptor >= 0, validateDescriptorForRead() else { return nil }

            let remainingTranscriptBytes = limits.maximumTranscriptBytes - cumulativeBytesRead
            guard remainingTranscriptBytes > 0 else {
                reachedEOF = true
                close()
                continue
            }

            var chunk = [UInt8](
                repeating: 0,
                count: Swift.min(Self.chunkSize, remainingTranscriptBytes)
            )
            let bytesRead = Darwin.read(descriptor, &chunk, chunk.count)
            if bytesRead == 0 {
                reachedEOF = true
                close()
                continue
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                failTrustedRead()
                return nil
            }

            cumulativeBytesRead += bytesRead
            buffer.append(contentsOf: chunk[0..<bytesRead])
        }
    }

    /// Revalidates identity, type, and current size on the same descriptor.
    private func validateDescriptorForRead() -> Bool {
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_dev == expectedDevice,
              value.st_ino == expectedInode,
              (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              value.st_size >= 0 else {
            failTrustedRead()
            return false
        }
        guard UInt64(value.st_size) <= UInt64(limits.maximumTranscriptBytes) else {
            failResourceLimit()
            return false
        }
        return true
    }

    /// Marks a resource violation and drops all partial content.
    private func failResourceLimit() {
        didViolateResourceLimit = true
        buffer.removeAll(keepingCapacity: false)
        reachedEOF = true
        close()
    }

    /// Fails closed on descriptor or I/O errors without exposing file content.
    private func failTrustedRead() {
        didFailTrustedRead = true
        buffer.removeAll(keepingCapacity: false)
        reachedEOF = true
        close()
    }
}
