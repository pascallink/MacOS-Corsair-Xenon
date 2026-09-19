// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import XeneonEdgeKit

@Suite struct BitbucketOverviewTests {
    private func makePullRequest(id: Int = 1, authorName: String = "autor",
                                 reviewers: [BitbucketReviewer] = [],
                                 openTaskCount: Int? = 0) -> BitbucketPullRequest {
        BitbucketPullRequest(id: id, title: "Titel", projectKey: "REFI", repoSlug: "app",
                             targetBranch: "develop", authorName: authorName, reviewers: reviewers,
                             openTaskCount: openTaskCount,
                             url: "https://bitbucket.example.com/pr/\(id)", updatedAt: nil)
    }

    private func makeReviewer(name: String = "reviewer",
                              status: BitbucketReviewerStatus = .unapproved) -> BitbucketReviewer {
        BitbucketReviewer(name: name, status: status)
    }

    private func makePattern(_ raw: String = "refi/*") -> BitbucketTargetPattern {
        BitbucketTargetPattern.parse(raw)!
    }

    @Test func needsWorkBlocksReadyToMergeEvenWithEnoughApprovals() {
        let pr = makePullRequest(reviewers: [makeReviewer(name: "r1", status: .approved),
                                             makeReviewer(name: "r2", status: .needsWork)],
                                 openTaskCount: 0)
        let overview = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].readyToMerge == 0)
    }

    @Test func requiredApprovalsShiftsApprovedCounting() {
        let pr = makePullRequest(reviewers: [makeReviewer(status: .approved)], openTaskCount: 0)
        let withOneRequired = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                                       patternLabels: ["refi/*"], currentUser: "",
                                                       requiredApprovals: 1)
        let withTwoRequired = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                                       patternLabels: ["refi/*"], currentUser: "",
                                                       requiredApprovals: 2)
        #expect(withOneRequired.groups[0].readyToMerge == 1)
        #expect(withTwoRequired.groups[0].readyToMerge == 0)
    }

    @Test func nilOpenTaskCountOnOneContributingPullRequestMakesAggregateNil() {
        let withCount = makePullRequest(id: 1, authorName: "pascal", openTaskCount: 2)
        let withoutCount = makePullRequest(id: 2, authorName: "pascal", openTaskCount: nil)
        let overview = BitbucketOverview.build(author: [withCount, withoutCount], reviewer: [],
                                               patterns: [makePattern()], patternLabels: ["refi/*"],
                                               currentUser: "pascal", requiredApprovals: 1)
        #expect(overview.groups[0].mine.count == 2)
        #expect(overview.groups[0].mine.openTasks == nil)
    }

    @Test func openTasksIsZeroNotNilWhenAllContributingPullRequestsHaveZeroOpenTasks() {
        let first = makePullRequest(id: 1, authorName: "pascal", openTaskCount: 0)
        let second = makePullRequest(id: 2, authorName: "pascal", openTaskCount: 0)
        let overview = BitbucketOverview.build(author: [first, second], reviewer: [],
                                               patterns: [makePattern()], patternLabels: ["refi/*"],
                                               currentUser: "pascal", requiredApprovals: 1)
        #expect(overview.groups[0].mine.openTasks == 0)
    }

    @Test func openTasksIsNilWhenNoPullRequestContributes() {
        let overview = BitbucketOverview.build(author: [], reviewer: [], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].mine == BitbucketCount(count: 0, openTasks: nil))
    }

    @Test func nilOpenTaskCountBlocksReadyToMergeEvenWhenApproved() {
        let pr = makePullRequest(reviewers: [makeReviewer(status: .approved)], openTaskCount: nil)
        let overview = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].readyToMerge == 0)
    }

    @Test func pullRequestWithoutMatchingPatternIsDropped() {
        let pr = makePullRequest(authorName: "pascal", openTaskCount: 0)
        let overview = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern("other/x")],
                                               patternLabels: ["other/x"], currentUser: "pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].mine.count == 0)
        #expect(overview.groups[0].toReview.count == 0)
        #expect(overview.groups[0].readyToMerge == 0)
    }

    @Test func overlappingPatternsCountPullRequestOnceInFirstMatch() {
        let pr = makePullRequest(authorName: "pascal", openTaskCount: 0)
        let overview = BitbucketOverview.build(author: [pr], reviewer: [],
                                               patterns: [makePattern("refi/*"), makePattern("refi/app/*")],
                                               patternLabels: ["broad", "narrow"], currentUser: "pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].mine.count == 1)
        #expect(overview.groups[1].mine.count == 0)
    }

    @Test func sameIdInAuthorAndReviewerCountsOnce() {
        let pr = makePullRequest(reviewers: [makeReviewer(status: .approved)], openTaskCount: 0)
        let overview = BitbucketOverview.build(author: [pr], reviewer: [pr], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].readyToMerge == 1)
    }

    @Test func approvedOwnPullRequestIsNotMineButIsReadyToMerge() {
        let pr = makePullRequest(authorName: "pascal", reviewers: [makeReviewer(status: .approved)],
                                 openTaskCount: 0)
        let overview = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].mine.count == 0)
        #expect(overview.groups[0].readyToMerge == 1)
    }

    @Test func emptyCurrentUserResultsInZeroCountsEverywhere() {
        let pr = makePullRequest(authorName: "pascal",
                                 reviewers: [makeReviewer(name: "pascal", status: .unapproved)],
                                 openTaskCount: 0)
        let overview = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "   ",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].mine == BitbucketCount(count: 0, openTasks: nil))
        #expect(overview.groups[0].toReview == BitbucketCount(count: 0, openTasks: nil))
    }

    @Test func currentUserComparisonIsCaseInsensitive() {
        let pr = makePullRequest(authorName: "pascal", openTaskCount: 0)
        let overview = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "Pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].mine.count == 1)
    }

    @Test func toReviewExcludesApprovedReviewerStatus() {
        let pr = makePullRequest(authorName: "jemand",
                                 reviewers: [makeReviewer(name: "pascal", status: .approved)])
        let overview = BitbucketOverview.build(author: [pr], reviewer: [pr], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].toReview.count == 0)
    }

    @Test func toReviewExcludesPullRequestsAuthoredByCurrentUserEvenAsReviewer() {
        let pr = makePullRequest(authorName: "pascal",
                                 reviewers: [makeReviewer(name: "pascal", status: .unapproved)])
        let overview = BitbucketOverview.build(author: [pr], reviewer: [pr], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].toReview.count == 0)
    }

    @Test func toReviewExcludesNeedsWorkReviewerStatus() {
        let pr = makePullRequest(authorName: "jemand",
                                 reviewers: [makeReviewer(name: "pascal", status: .needsWork)])
        let overview = BitbucketOverview.build(author: [pr], reviewer: [pr], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].toReview.count == 0)
    }

    @Test func toReviewIncludesUnapprovedReviewerStatus() {
        let pr = makePullRequest(authorName: "jemand",
                                 reviewers: [makeReviewer(name: "pascal", status: .unapproved)])
        let overview = BitbucketOverview.build(author: [pr], reviewer: [pr], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "pascal",
                                               requiredApprovals: 1)
        #expect(overview.groups[0].toReview.count == 1)
    }

    @Test func requiredApprovalsIsClampedToAtLeastOne() {
        let pr = makePullRequest(reviewers: [makeReviewer(status: .approved)], openTaskCount: 0)
        let withZero = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                               patternLabels: ["refi/*"], currentUser: "",
                                               requiredApprovals: 0)
        let withNegative = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                                    patternLabels: ["refi/*"], currentUser: "",
                                                    requiredApprovals: -1)
        let withOne = BitbucketOverview.build(author: [pr], reviewer: [], patterns: [makePattern()],
                                              patternLabels: ["refi/*"], currentUser: "",
                                              requiredApprovals: 1)
        #expect(withZero.groups[0].readyToMerge == 1)
        #expect(withNegative.groups[0].readyToMerge == 1)
        #expect(withOne.groups[0].readyToMerge == 1)
    }
}
