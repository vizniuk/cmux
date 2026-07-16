import CmuxAgentChat
import Foundation

/// Reads the per-agent hook session stores (`~/.cmuxterm/<agent>-hook-sessions.json`)
/// the `cmux hooks` CLI maintains, yielding terminal bindings and transcript
/// paths for agent sessions.
///
/// Mirrors `FeedJumpResolver.lookup`'s tolerant parsing (nested `sessions`
/// dict with a flat-layout fallback) but surfaces the additional fields the
/// chat service needs (`cwd`, `transcriptPath`, `pid`).
struct AgentChatHookSessionStore: Sendable {
    /// One hook-store entry's chat-relevant fields.
    struct Entry: Sendable {
        /// The agent's session identifier (the store key).
        let sessionID: String
        /// Owning cmux workspace UUID string.
        let workspaceID: String?
        /// Hosting cmux terminal surface UUID string.
        let surfaceID: String?
        /// The session's working directory.
        let workingDirectory: String?
        /// Absolute transcript JSONL path, when the hook recorded one.
        let transcriptPath: String?
        /// The agent process id, for liveness checks.
        let pid: Int?
        /// When the hook store last updated the record.
        let updatedAt: Date?
        /// Last provider turn accepted by the hook lifecycle tracker.
        let lastPromptTurnID: String?
    }

    private let homeDirectory: URL

    /// Creates a store reader.
    ///
    /// - Parameter homeDirectory: The home directory containing
    ///   `.cmuxterm/`; injectable for tests.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// Reads one agent's hook session store.
    ///
    /// - Parameter agentSource: The agent's `_source` name (`claude`,
    ///   `codex`, ...), which names the store file.
    /// - Returns: All entries, or empty when the store is absent/malformed.
    func entries(agentSource: String) -> [Entry] {
        guard let root = root(agentSource: agentSource) else { return [] }
        let sessions = (root["sessions"] as? [String: Any]) ?? root
        return sessions.compactMap { key, value in
            Self.entry(sessionID: key, value: value)
        }
    }

    /// Reads one session only when the CLI store's authoritative per-surface
    /// active boundary still names that exact session and turn. The root is
    /// parsed once so historical entries cannot race a separate active lookup.
    /// Report content is never written to or read from this persisted store.
    ///
    /// - Parameters:
    ///   - agentSource: Provider store name; Slice A passes `codex`.
    ///   - sessionID: Exact provider session requested by the Stop event.
    ///   - surfaceID: Exact runtime surface claimed by the accepted route.
    ///   - turnID: Exact provider turn authorized by prompt lifecycle state.
    /// - Returns: The matching current session entry, or `nil` on any mismatch.
    func activeCaptureEntry(
        agentSource: String,
        sessionID: String,
        surfaceID: String,
        turnID: String
    ) -> Entry? {
        guard let root = root(agentSource: agentSource),
              let activeBySurface = root["activeSessionsBySurface"] as? [String: Any],
              let activeValue = activeBySurface.first(where: {
                  Self.sameUUID($0.key, surfaceID)
              })?.value as? [String: Any],
              Self.nonEmpty(activeValue["sessionId"] as? String) == sessionID,
              Self.nonEmpty(activeValue["turnId"] as? String) == turnID,
              let sessions = root["sessions"] as? [String: Any],
              let value = sessions[sessionID] else {
            return nil
        }
        guard let entry = Self.entry(sessionID: sessionID, value: value),
              entry.lastPromptTurnID == turnID else {
            return nil
        }
        return entry
    }

    /// Reads one session's entry from one agent's store.
    ///
    /// - Parameters:
    ///   - agentSource: The agent's `_source` name.
    ///   - sessionID: The session to look up.
    /// - Returns: The entry, or `nil` when absent.
    func entry(agentSource: String, sessionID: String) -> Entry? {
        entries(agentSource: agentSource).first { $0.sessionID == sessionID }
    }

    /// Reads and parses one hook-store snapshot without exposing partial fields.
    private func root(agentSource: String) -> [String: Any]? {
        let file = homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("\(agentSource)-hook-sessions.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }
        return root
    }

    /// Decodes content-free routing metadata for one provider session.
    private static func entry(sessionID: String, value: Any) -> Entry? {
        guard let entry = value as? [String: Any] else { return nil }
        let updatedAt = (entry["updatedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        return Entry(
            sessionID: sessionID,
            workspaceID: nonEmpty(entry["workspaceId"] as? String),
            surfaceID: nonEmpty(entry["surfaceId"] as? String),
            workingDirectory: nonEmpty(entry["cwd"] as? String),
            transcriptPath: nonEmpty(entry["transcriptPath"] as? String),
            pid: entry["pid"] as? Int,
            updatedAt: updatedAt,
            lastPromptTurnID: nonEmpty(entry["lastPromptTurnId"] as? String)
        )
    }

    /// Compares UUID strings canonically so case differences do not misroute.
    private static func sameUUID(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = UUID(uuidString: lhs), let rhs = UUID(uuidString: rhs) else { return false }
        return lhs == rhs
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
