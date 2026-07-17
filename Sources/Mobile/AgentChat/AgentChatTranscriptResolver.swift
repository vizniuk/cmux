import CmuxAgentChat
import Foundation

/// Resolves the transcript JSONL path for an agent session.
///
/// Preference order for ordinary chat history is the hook store's recorded
/// `transcriptPath`, then the agent-specific conventional location. Private
/// Codex report reads apply a stricter root-contained resolver below.
struct AgentChatTranscriptResolver: Sendable {
    private let homeDirectory: URL
    /// Config-dir root for Claude (`$CLAUDE_CONFIG_DIR` or `~/.claude`).
    private let claudeConfigRoot: URL
    /// Config-dir root for Codex (`$CODEX_HOME` or `~/.codex`).
    private let codexConfigRoot: URL

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
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
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
    /// This method performs file I/O and must be called off the main actor,
    /// immediately before opening the returned path.
    ///
    /// Candidate and root symlinks are resolved before component-wise
    /// containment is checked. The resolved candidate must be a regular JSONL
    /// file. The conventional fallback remains session-specific; it never
    /// selects an arbitrary newest transcript.
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
    /// under `~/.codex/sessions/YYYY/MM/DD/`; scan recent day directories for
    /// the session id.
    private func codexFallbackPath(sessionID: String) -> String? {
        let fileManager = FileManager.default
        let root = canonicalCodexSessionsRoot
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let needle = sessionID.lowercased()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if url.lastPathComponent.lowercased().contains(needle),
               let validated = validatedCodexTranscriptPath(url.path) {
                return validated
            }
        }
        return nil
    }

    /// Canonical root authorized by app configuration, never by hook payload.
    private var canonicalCodexSessionsRoot: URL {
        codexConfigRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// Canonicalizes and validates one untrusted transcript candidate.
    ///
    /// Symlinks that resolve inside the configured sessions root are accepted;
    /// escapes, missing targets, directories, devices, and FIFOs fail closed.
    private func validatedCodexTranscriptPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }

        let unresolved = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL
        let candidate = unresolved.resolvingSymlinksInPath()
        let root = canonicalCodexSessionsRoot
        guard unresolved.pathExtension.lowercased() == "jsonl",
              candidate.pathExtension.lowercased() == "jsonl" else {
            return nil
        }

        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              candidateComponents.starts(with: rootComponents) else {
            return nil
        }

        guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        return candidate.path
    }
}

extension AgentChatTranscriptResolver: AgentReportTranscriptRecovering {
    /// Proves primary-session metadata using off-main streaming JSONL I/O.
    ///
    /// - Parameters:
    ///   - recordedPath: Untrusted hook path, accepted only after canonical
    ///     root containment and regular-file validation.
    ///   - sessionID: Exact Codex session expected in rollout metadata.
    /// - Returns: `true` only for a matching primary rollout.
    func isPrimaryCodexSession(
        recordedPath: String?,
        sessionID: String
    ) async -> Bool {
        let resolver = self
        return await Task.detached(priority: .utility) {
            guard let path = resolver.codexTranscriptPath(
                recordedPath: recordedPath,
                sessionID: sessionID
            ), let lines = CompleteJSONLLineSequence(path: path) else {
                return false
            }
            return CodexFinalReplyExtractor().isPrimarySession(
                lines: lines,
                sessionID: sessionID
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
    /// - Returns: Unmodified final assistant text, or `nil` if unprovable.
    func recoverCodexFinalReply(
        recordedPath: String?,
        sessionID: String,
        turnID: String
    ) async -> String? {
        let resolver = self
        return await Task.detached(priority: .utility) {
            guard let path = resolver.codexTranscriptPath(
                recordedPath: recordedPath,
                sessionID: sessionID
            ), let lines = CompleteJSONLLineSequence(path: path) else {
                return nil
            }
            return CodexFinalReplyExtractor().extract(
                lines: lines,
                sessionID: sessionID,
                turnID: turnID
            )
        }.value
    }
}

/// Streams complete JSONL records without copying an entire long-lived rollout
/// into memory. The largest retained buffer is one record plus one read chunk;
/// an incomplete trailing fragment is deliberately discarded at EOF.
private struct CompleteJSONLLineSequence: Sequence, IteratorProtocol {
    private static let chunkSize = 64 * 1024

    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEOF = false

    /// Opens a rollout for bounded streaming reads.
    ///
    /// - Parameter path: Exact session-validated rollout path.
    init?(path: String) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        self.handle = handle
    }

    /// Returns the next newline-terminated record, dropping an incomplete tail.
    ///
    /// - Returns: One complete UTF-8-decoded line, or `nil` at safe EOF.
    mutating func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            guard !reachedEOF else {
                // Rollouts are append-only. Never parse or guess from a
                // concurrently written, non-newline-terminated JSON fragment.
                return nil
            }
            guard let chunk = try? handle.read(upToCount: Self.chunkSize),
                  !chunk.isEmpty else {
                reachedEOF = true
                try? handle.close()
                continue
            }
            buffer.append(chunk)
        }
    }
}
