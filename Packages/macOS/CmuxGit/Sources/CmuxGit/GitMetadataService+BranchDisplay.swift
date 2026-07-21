import Foundation

extension GitMetadataService {
    /// Resolves compact branch UI for the repository containing `directory`.
    ///
    /// Resolution uses direct Git metadata reads only: no shell, subprocess,
    /// hooks, credential prompts, network access, persistence, or logging.
    public nonisolated func branchDisplaySnapshot(
        forDirectory directory: String
    ) async -> GitBranchDisplaySnapshot? {
        guard let repository = Self.resolveGitRepository(containing: directory) else {
            return nil
        }
        switch Self.gitCheckedOutBranch(repository: repository) {
        case .branch(let branch):
            guard let branch = GitMetadataReadPolicy.displayBranch(branch) else { return nil }
            return GitBranchDisplaySnapshot(displayName: branch)
        case .detached:
            guard let commit = Self.gitCurrentCommit(repository: repository) else { return nil }
            return GitBranchDisplaySnapshot(
                displayName: "detached@\(commit.prefix(7))"
            )
        case .notARepository, .unreadable:
            return nil
        }
    }
}
