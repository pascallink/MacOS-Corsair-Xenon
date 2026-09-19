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

    @Test func fourSegmentPatternJoinsTailIntoSlashTargetBranch() {
        let pattern = BitbucketTargetPattern.parse("a/b/c/d")
        #expect(pattern != nil)
        let matching = makePullRequest(projectKey: "a", repoSlug: "b", targetBranch: "c/d")
        let notMatching = makePullRequest(projectKey: "a", repoSlug: "b", targetBranch: "c/e")
        #expect(pattern?.matches(matching) == true)
        #expect(pattern?.matches(notMatching) == false)
    }

    @Test func starInSegmentMiddleMatchesWithinSameSegment() {
        let pattern = BitbucketTargetPattern.parse("refi/dev*op")
        #expect(pattern != nil)
        let exact = makePullRequest(targetBranch: "develop")
        let zeroWidth = makePullRequest(targetBranch: "devop")
        let wrongTail = makePullRequest(targetBranch: "develop-2026")
        #expect(pattern?.matches(exact) == true)
        #expect(pattern?.matches(zeroWidth) == true)
        #expect(pattern?.matches(wrongTail) == false)
    }

    @Test func multipleStarsInOneSegmentMatchInOrderWithoutSlash() {
        let pattern = BitbucketTargetPattern.parse("refi/*dev*op*")
        #expect(pattern != nil)
        let matching = makePullRequest(targetBranch: "xdevelopy")
        let withSlashBetween = makePullRequest(targetBranch: "xdev/elopy")
        #expect(pattern?.matches(matching) == true)
        #expect(pattern?.matches(withSlashBetween) == false)
    }

    @Test func leadingStarMatchesAnyPrefixWithoutSlash() {
        let pattern = BitbucketTargetPattern.parse("refi/*develop")
        #expect(pattern != nil)
        let matching = makePullRequest(targetBranch: "release-develop")
        let wrongTail = makePullRequest(targetBranch: "develop-2026")
        #expect(pattern?.matches(matching) == true)
        #expect(pattern?.matches(wrongTail) == false)
    }

    @Test func standaloneStarMatchesAnyValueWithoutSlash() {
        let pattern = BitbucketTargetPattern.parse("refi/*")
        #expect(pattern != nil)
        let matching = makePullRequest(targetBranch: "develop")
        let withSlash = makePullRequest(targetBranch: "release/1.2")
        #expect(pattern?.matches(matching) == true)
        #expect(pattern?.matches(withSlash) == false)
    }

    @Test func projectAndRepoSegmentsSupportGlobs() {
        let pattern = BitbucketTargetPattern.parse("re*i/ap*/develop")
        #expect(pattern != nil)
        let matching = makePullRequest(projectKey: "REFI", repoSlug: "APPS", targetBranch: "develop")
        let wrongRepo = makePullRequest(projectKey: "REFI", repoSlug: "web", targetBranch: "develop")
        #expect(pattern?.matches(matching) == true)
        #expect(pattern?.matches(wrongRepo) == false)
    }

    @Test func whitespaceAroundSegmentsIsTrimmedBeforeParsing() {
        let spaced = BitbucketTargetPattern.parse("refi / develop*")
        let unspaced = BitbucketTargetPattern.parse("refi/develop*")
        #expect(spaced != nil)
        #expect(unspaced != nil)
        let pr = makePullRequest(targetBranch: "develop-2026")
        #expect(spaced?.matches(pr) == true)
        #expect(unspaced?.matches(pr) == true)
        #expect(spaced?.matches(pr) == unspaced?.matches(pr))
    }

    @Test func segmentThatIsOnlyWhitespaceIsInvalid() {
        #expect(BitbucketTargetPattern.parse("refi/ ") == nil)
    }

    @Test func threeSegmentPatternAllowsSlashInTargetBranch() {
        let pattern = BitbucketTargetPattern.parse("refi/app/release/1.2")
        #expect(pattern != nil)
        let pr = makePullRequest(repoSlug: "app", targetBranch: "release/1.2")
        #expect(pattern?.matches(pr) == true)
    }

    @Test func starInTargetBranchSegmentNeverConsumesSlash() {
        let pattern = BitbucketTargetPattern.parse("refi/*/release/1.*")
        #expect(pattern != nil)
        let anyRepo = makePullRequest(repoSlug: "beliebig", targetBranch: "release/1.2")
        let extraSlashSegment = makePullRequest(repoSlug: "beliebig", targetBranch: "release/1.2/hotfix")
        #expect(pattern?.matches(anyRepo) == true)
        #expect(pattern?.matches(extraSlashSegment) == false)
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
