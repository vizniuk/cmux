import Foundation

extension GitMetadataService {
    /// Normalizes a branch name for keying: trims whitespace and maps empty to
    /// `nil`. Public because both this package's PR matching and app-side
    /// branch bookkeeping key state by the same normalization.
    public nonisolated static func normalizedBranchName(_ branch: String?) -> String? {
        let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The current branch name from `HEAD` (`ref: refs/heads/<name>`), or `nil`
    /// for a detached HEAD or unreadable `HEAD`.
    nonisolated static func gitBranchName(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = GitMetadataReadPolicy.readString(at: headURL),
              let line = GitMetadataReadPolicy.metadataLine(contents) else { return nil }
        let branchPrefix = "ref: refs/heads/"
        guard line.hasPrefix(branchPrefix),
              GitMetadataReadPolicy.symbolicRef(String(line.dropFirst("ref: ".count))) != nil else {
            return nil
        }
        return GitMetadataReadPolicy.displayBranch(String(line.dropFirst(branchPrefix.count)))
    }

    /// Classifies the repository's `HEAD` into a ``GitCheckedOutBranch``,
    /// keeping a legitimate non-branch checkout (detached commit, non-branch
    /// symbolic ref) distinct from a missing/unreadable/malformed `HEAD`.
    nonisolated static func gitCheckedOutBranch(repository: ResolvedGitRepository) -> GitCheckedOutBranch {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = GitMetadataReadPolicy.readString(at: headURL),
              let line = GitMetadataReadPolicy.metadataLine(contents) else { return .unreadable }
        let branchPrefix = "ref: refs/heads/"
        if line.hasPrefix(branchPrefix) {
            guard GitMetadataReadPolicy.symbolicRef(String(line.dropFirst("ref: ".count))) != nil,
                  let branch = GitMetadataReadPolicy.displayBranch(
                      String(line.dropFirst(branchPrefix.count))
                  ) else {
                return .unreadable
            }
            return .branch(branch)
        }
        if line.hasPrefix("ref: ") {
            return GitMetadataReadPolicy.symbolicRef(String(line.dropFirst("ref: ".count))) == nil
                ? .unreadable
                : .detached
        }
        if GitMetadataReadPolicy.objectID(line) != nil {
            return .detached
        }
        return .unreadable
    }

    /// A signature of `HEAD` plus the commit it resolves to: the symbolic ref
    /// text and the resolved ref value joined, or the detached SHA directly.
    nonisolated static func gitHeadSignature(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = GitMetadataReadPolicy.readString(at: headURL),
              let line = GitMetadataReadPolicy.metadataLine(contents) else { return nil }
        let refPrefix = "ref: "
        guard line.hasPrefix(refPrefix) else {
            return GitMetadataReadPolicy.objectID(line)
        }

        let refName = String(line.dropFirst(refPrefix.count))
        guard GitMetadataReadPolicy.symbolicRef(refName) != nil else { return nil }
        let refValue = gitRefValue(repository: repository, refName: refName) ?? ""
        return "\(line)\n\(refValue)"
    }

    /// Resolves a ref name to its value, checking the loose ref under the git
    /// and common directories, then `packed-refs`. A ref name is repo-controlled
    /// input from `HEAD`; names whose standardized path escapes the directory
    /// they are joined to (e.g. `../../outside`) are ignored rather than read.
    nonisolated static func gitRefValue(repository: ResolvedGitRepository, refName: String) -> String? {
        guard GitMetadataReadPolicy.symbolicRef(refName) != nil else { return nil }
        let lookups = [
            (base: repository.gitDirectory, refURL: URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent(refName)),
            (base: repository.commonDirectory, refURL: URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent(refName)),
        ]
        var seenPaths: Set<String> = []
        for (base, refURL) in lookups {
            let basePath = URL(fileURLWithPath: base).standardizedFileURL.path
            let path = refURL.standardizedFileURL.path
            guard path.hasPrefix(basePath + "/"),
                  seenPaths.insert(path).inserted else {
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let contents = GitMetadataReadPolicy.readString(at: refURL),
                  let line = GitMetadataReadPolicy.metadataLine(contents) else { return nil }
            if let value = GitMetadataReadPolicy.objectID(line) {
                return value
            }
            return nil
        }

        let packedRefsURL = URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("packed-refs")
        guard let packedRefs = GitMetadataReadPolicy.readString(at: packedRefsURL) else { return nil }
        return GitMetadataReadPolicy.packedRefValue(in: packedRefs, matching: refName)
    }

    /// The current commit SHA the repository's `HEAD` resolves to (40- or
    /// 64-character lowercase hex), or `nil` if it cannot be resolved.
    nonisolated static func gitCurrentCommit(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = GitMetadataReadPolicy.readString(at: headURL),
              let line = GitMetadataReadPolicy.metadataLine(contents) else { return nil }
        let refPrefix = "ref: "
        let value: String
        if line.hasPrefix(refPrefix) {
            let refName = String(line.dropFirst(refPrefix.count))
            guard GitMetadataReadPolicy.symbolicRef(refName) != nil,
                  let refValue = gitRefValue(repository: repository, refName: refName) else {
                return nil
            }
            value = refValue
        } else {
            value = line
        }
        return GitMetadataReadPolicy.objectID(value)
    }
}
