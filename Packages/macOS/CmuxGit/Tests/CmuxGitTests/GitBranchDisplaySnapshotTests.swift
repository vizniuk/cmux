import Foundation
import Testing
@testable import CmuxGit

@Suite("Terminal Git branch display")
struct GitBranchDisplaySnapshotTests {
    @Test("normal branch resolves from a nested directory without normalization")
    func normalNestedBranch() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("feature/agent-report-b2")
        let nested = fixture.root.appendingPathComponent("nested/dir", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let snapshot = try #require(await GitMetadataService().branchDisplaySnapshot(
            forDirectory: nested.path
        ))

        #expect(snapshot.displayName == "feature/agent-report-b2")
        #expect(String(describing: snapshot) == "GitBranchDisplaySnapshot")
        #expect(!String(describing: snapshot).contains(fixture.root.path))

        try fixture.writeBranch("feature/renamed-without-cwd-change")
        let refreshed = try #require(await GitMetadataService().branchDisplaySnapshot(
            forDirectory: nested.path
        ))
        #expect(refreshed.displayName == "feature/renamed-without-cwd-change")
        #expect(refreshed.revision != snapshot.revision)
    }

    @Test("detached SHA-1 and SHA-256 heads use a concise seven-character form")
    func detachedHeads() async throws {
        for commit in [
            "abcdef1234567890abcdef1234567890abcdef12",
            "1234567" + String(repeating: "a", count: 57),
        ] {
            let fixture = try GitRepositoryFixture()
            try fixture.writeDetachedHead(commit: commit)

            let snapshot = try #require(await GitMetadataService().branchDisplaySnapshot(
                forDirectory: fixture.root.path
            ))

            #expect(snapshot.displayName == "detached@\(commit.prefix(7))")
        }
    }

    @Test("non-repository directories remain hidden")
    func nonRepositoryIsNil() async {
        #expect(await GitMetadataService().branchDisplaySnapshot(
            forDirectory: "/definitely/not/a/repository/\(UUID().uuidString)"
        ) == nil)
    }

    @Test("worktree git files and submodule-style nested repositories resolve independently")
    func worktreeAndSubmodule() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-branch-display-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let common = base.appendingPathComponent("common", isDirectory: true)
        let worktree = base.appendingPathComponent("worktree", isDirectory: true)
        let submodule = worktree.appendingPathComponent("vendor/submodule", isDirectory: true)
        try FileManager.default.createDirectory(
            at: common.appendingPathComponent("refs/heads", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(common.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/worktree-branch\n".write(
            to: common.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try String(repeating: "b", count: 40).write(
            to: common.appendingPathComponent("refs/heads/worktree-branch"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: submodule.appendingPathComponent(".git/refs/heads", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/submodule-branch\n".write(
            to: submodule.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try String(repeating: "c", count: 40).write(
            to: submodule.appendingPathComponent(".git/refs/heads/submodule-branch"),
            atomically: true,
            encoding: .utf8
        )

        let service = GitMetadataService()
        #expect(await service.branchDisplaySnapshot(forDirectory: worktree.path)?.displayName == "worktree-branch")
        #expect(await service.branchDisplaySnapshot(forDirectory: submodule.path)?.displayName == "submodule-branch")
    }

    @Test("unusual path characters are treated only as filesystem data")
    func unusualPathHasNoShellSemantics() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("safe")
        let unusual = fixture.root.appendingPathComponent("name; $(touch never)", isDirectory: true)
        try FileManager.default.createDirectory(at: unusual, withIntermediateDirectories: true)

        let snapshot = await GitMetadataService().branchDisplaySnapshot(forDirectory: unusual.path)

        #expect(snapshot?.displayName == "safe")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("never").path))
    }
}
