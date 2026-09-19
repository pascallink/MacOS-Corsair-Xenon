// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import XeneonEdgeKit

@Suite struct BitbucketTargetPatternTests {
    private func makePullRequest(projectKey: String = "REFI",
                                 repoSlug: String = "app",
                                 targetBranch: String = "develop-2026") -> BitbucketPullRequest {
        BitbucketPullRequest(id: 1, title: "Titel", projectKey: projectKey,
                             repoSlug: repoSlug, targetBranch: targetBranch,
                             authorName: "Autor", reviewers: [], openTaskCount: nil,
                             url: "https://bitbucket.example.com/pr/1", updatedAt: nil)
    }

    @Test func twoSegmentPatternMatchesAnyRepo() {
        let pattern = BitbucketTargetPattern.parse("refi/develop*")
        #expect(pattern != nil)
        let pr = makePullRequest(repoSlug: "app", targetBranch: "develop-2026")
        #expect(pattern?.matches(pr) == true)
    }

    @Test func twoSegmentPatternDoesNotMatchDifferentBranch() {
        let pattern = BitbucketTargetPattern.parse("refi/develop*")
        let pr = makePullRequest(targetBranch: "main")
        #expect(pattern?.matches(pr) == false)
    }

    @Test func threeSegmentPatternRestrictsRepo() {
        let pattern = BitbucketTargetPattern.parse("refi/app/develop")
        #expect(pattern != nil)
        let matchingRepo = makePullRequest(repoSlug: "app", targetBranch: "develop")
        let otherRepo = makePullRequest(repoSlug: "web", targetBranch: "develop")
        #expect(pattern?.matches(matchingRepo) == true)
        #expect(pattern?.matches(otherRepo) == false)
    }

    @Test func starDoesNotMatchSlash() {
        let pattern = BitbucketTargetPattern.parse("refi/develop*")
        let pr = makePullRequest(targetBranch: "develop/alt")
        #expect(pattern?.matches(pr) == false)
    }

    @Test func projectAndRepoAreCaseInsensitive() {
        let pattern = BitbucketTargetPattern.parse("REFI/APP/develop")
        #expect(pattern != nil)
        let pr = makePullRequest(projectKey: "refi", repoSlug: "app", targetBranch: "develop")
        #expect(pattern?.matches(pr) == true)
    }

    @Test func targetBranchIsCaseSensitive() {
        let pattern = BitbucketTargetPattern.parse("refi/develop")
        let pr = makePullRequest(targetBranch: "Develop")
        #expect(pattern?.matches(pr) == false)
    }

    @Test func emptyPatternIsInvalid() {
        #expect(BitbucketTargetPattern.parse("") == nil)
    }

    @Test func singleSegmentPatternIsInvalid() {
        #expect(BitbucketTargetPattern.parse("refi") == nil)
    }

    @Test func fourSegmentPatternIsInvalid() {
        #expect(BitbucketTargetPattern.parse("a/b/c/d") == nil)
    }

    @Test func emptySegmentIsInvalid() {
        #expect(BitbucketTargetPattern.parse("refi//x") == nil)
    }

    @Test func leadingSlashDoesNotChangeTheResult() {
        let withSlash = BitbucketTargetPattern.parse("/refi/develop*")
        let withoutSlash = BitbucketTargetPattern.parse("refi/develop*")
        let pr = makePullRequest(targetBranch: "develop-2026")
        #expect(withSlash?.matches(pr) == withoutSlash?.matches(pr))
        #expect(withSlash?.matches(pr) == true)
    }

    @Test func patternWithoutStarMatchesOnlyExactly() {
        let pattern = BitbucketTargetPattern.parse("refi/develop")
        let exact = makePullRequest(targetBranch: "develop")
        let notExact = makePullRequest(targetBranch: "develop-2026")
        #expect(pattern?.matches(exact) == true)
        #expect(pattern?.matches(notExact) == false)
    }
}
