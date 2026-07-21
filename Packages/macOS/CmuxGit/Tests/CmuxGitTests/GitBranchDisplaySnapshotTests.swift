import Foundation
import Testing
@testable import CmuxGit

@Suite("Terminal Git branch display")
struct GitBranchDisplaySnapshotTests {
    @Test("metadata reader accepts exactly 1 MiB and rejects one byte above")
    func metadataFileBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-metadata-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("metadata")

        try Data(repeating: 0x61, count: GitMetadataReadPolicy.maximumFileBytes).write(to: file)
        #expect(GitMetadataReadPolicy.readFile(at: file)?.count == GitMetadataReadPolicy.maximumFileBytes)

        try Data(repeating: 0x61, count: GitMetadataReadPolicy.maximumFileBytes + 1).write(to: file)
        #expect(GitMetadataReadPolicy.readFile(at: file) == nil)
    }

    @Test("symbolic refs and display branches enforce their exact UTF-8 boundaries")
    func refAndDisplayBoundaries() async throws {
        let refPrefix = "refs/heads/"
        let exactRef = refPrefix + String(
            repeating: "r",
            count: GitMetadataReadPolicy.maximumSymbolicRefBytes - refPrefix.utf8.count
        )
        #expect(GitMetadataReadPolicy.symbolicRef(exactRef) == exactRef)
        #expect(GitMetadataReadPolicy.symbolicRef(exactRef + "r") == nil)

        let exactBranch = String(repeating: "b", count: GitMetadataReadPolicy.maximumDisplayBranchBytes)
        #expect(GitMetadataReadPolicy.displayBranch(exactBranch) == exactBranch)
        #expect(GitMetadataReadPolicy.displayBranch(exactBranch + "b") == nil)

        let fixture = try GitRepositoryFixture()
        try "ref: refs/heads/\(exactBranch)\n".write(
            to: fixture.gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        #expect(await GitMetadataService().branchDisplaySnapshot(
            forDirectory: fixture.root.path
        )?.displayName == exactBranch)
        try "ref: refs/heads/\(exactBranch)b\n".write(
            to: fixture.gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        #expect(await GitMetadataService().branchDisplaySnapshot(forDirectory: fixture.root.path) == nil)
    }

    @Test("control characters invalid UTF-8 and malformed branch refs remain hidden")
    func malformedBranchValues() async throws {
        let malformedBranches = [
            "safe\ninjected",
            "safe\rinjected",
            "safe\tinjected",
            "safe\u{0000}injected",
            "safe\u{001F}injected",
            "../outside",
            "topic//double",
            ".hidden",
            "topic.lock",
        ]
        for branch in malformedBranches {
            let fixture = try GitRepositoryFixture()
            try Data("ref: refs/heads/\(branch)\n".utf8).write(
                to: fixture.gitDirectory.appendingPathComponent("HEAD")
            )
            #expect(await GitMetadataService().branchDisplaySnapshot(
                forDirectory: fixture.root.path
            ) == nil)
        }

        let invalidUTF8 = try GitRepositoryFixture()
        try Data([0x72, 0x65, 0x66, 0x3A, 0x20, 0xFF]).write(
            to: invalidUTF8.gitDirectory.appendingPathComponent("HEAD")
        )
        #expect(await GitMetadataService().branchDisplaySnapshot(
            forDirectory: invalidUTF8.root.path
        ) == nil)
    }

    @Test("malformed git indirection and oversized commondir fail closed")
    func malformedRepositoryIndirection() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-indirection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "gitdir: /private/tmp/repository\ninjected".write(
            to: base.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        #expect(await GitMetadataService().branchDisplaySnapshot(forDirectory: base.path) == nil)

        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("safe")
        try Data(
            repeating: 0x61,
            count: GitMetadataReadPolicy.maximumFileBytes + 1
        ).write(to: fixture.gitDirectory.appendingPathComponent("commondir"))
        #expect(await GitMetadataService().branchDisplaySnapshot(forDirectory: fixture.root.path) == nil)
    }

    @Test("oversized and malformed packed refs cannot produce detached display")
    func malformedPackedRefs() async throws {
        let oversized = try GitRepositoryFixture()
        try "ref: refs/tags/release\n".write(
            to: oversized.gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try Data(
            repeating: 0x61,
            count: GitMetadataReadPolicy.maximumFileBytes + 1
        ).write(to: oversized.gitDirectory.appendingPathComponent("packed-refs"))
        #expect(await GitMetadataService().branchDisplaySnapshot(forDirectory: oversized.root.path) == nil)

        let malformed = try GitRepositoryFixture()
        try "ref: refs/tags/release\n".write(
            to: malformed.gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "not-an-object refs/tags/release\n".write(
            to: malformed.gitDirectory.appendingPathComponent("packed-refs"),
            atomically: true,
            encoding: .utf8
        )
        #expect(await GitMetadataService().branchDisplaySnapshot(forDirectory: malformed.root.path) == nil)

        let valid = try GitRepositoryFixture()
        try "ref: refs/tags/release\n".write(
            to: valid.gitDirectory.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "\(String(repeating: "d", count: 40)) refs/tags/release\n".write(
            to: valid.gitDirectory.appendingPathComponent("packed-refs"),
            atomically: true,
            encoding: .utf8
        )
        #expect(await GitMetadataService().branchDisplaySnapshot(
            forDirectory: valid.root.path
        )?.displayName == "detached@ddddddd")
    }

    @Test("detached heads reject malformed object IDs")
    func malformedDetachedHeads() async throws {
        for commit in [
            String(repeating: "a", count: 39),
            String(repeating: "a", count: 41),
            String(repeating: "g", count: 40),
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
        ] {
            let fixture = try GitRepositoryFixture()
            try fixture.writeDetachedHead(commit: commit)
            #expect(await GitMetadataService().branchDisplaySnapshot(
                forDirectory: fixture.root.path
            ) == nil)
        }
    }

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
