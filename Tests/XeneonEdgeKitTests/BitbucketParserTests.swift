// XeneonEdge for macOS
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import XeneonEdgeKit

@Suite struct BitbucketParserTests {
    /// Seite mit drei Pull Requests, wie sie
    /// `GET /rest/api/1.0/dashboard/pull-requests` liefern wuerde.
    private static let threePullRequestsJSON = """
    {
        "values": [
            {
                "id": 1,
                "title": "Fix login bug",
                "toRef": {
                    "displayId": "refs/heads/develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "alice" } },
                "reviewers": [
                    { "user": { "name": "bob" }, "status": "APPROVED" },
                    { "user": { "name": "carol" }, "status": "UNAPPROVED" }
                ],
                "properties": { "openTaskCount": 3 },
                "links": {
                    "self": [
                        { "href": "https://bitbucket.example.com/projects/REFI/repos/app/pull-requests/1" }
                    ]
                },
                "updatedDate": 1700000000000
            },
            {
                "id": 2,
                "title": "Add feature",
                "toRef": {
                    "displayId": "refs/heads/main",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "dave" } },
                "reviewers": [],
                "links": {
                    "self": [
                        { "href": "https://bitbucket.example.com/projects/REFI/repos/app/pull-requests/2" }
                    ]
                },
                "updatedDate": 1700000001000
            },
            {
                "id": 3,
                "title": "Release prep",
                "toRef": {
                    "displayId": "refs/heads/release/1.2",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "erin" } },
                "reviewers": [
                    { "user": { "name": "frank" }, "status": "NEEDS_WORK" }
                ],
                "links": {
                    "self": [
                        { "href": "https://bitbucket.example.com/projects/REFI/repos/app/pull-requests/3" }
                    ]
                },
                "updatedDate": 1700000002000
            }
        ],
        "isLastPage": false,
        "nextPageStart": 50
    }
    """

    /// Kleine Seite ohne weitere Seiten und ohne `nextPageStart`.
    private static let lastPageJSON = """
    {
        "values": [
            {
                "id": 9,
                "title": "Last page entry",
                "toRef": {
                    "displayId": "refs/heads/develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "alice" } },
                "reviewers": []
            }
        ],
        "isLastPage": true
    }
    """

    /// Ein Eintrag ohne `author` neben einem gueltigen Eintrag.
    private static let missingAuthorJSON = """
    {
        "values": [
            {
                "id": 10,
                "title": "No author",
                "toRef": {
                    "displayId": "refs/heads/develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "reviewers": []
            },
            {
                "id": 11,
                "title": "Valid entry",
                "toRef": {
                    "displayId": "refs/heads/develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "alice" } },
                "reviewers": []
            }
        ],
        "isLastPage": true
    }
    """

    /// Ein Reviewer ohne `status`, aber mit `approved: true`.
    private static let approvedFallbackJSON = """
    {
        "values": [
            {
                "id": 12,
                "title": "Approved fallback",
                "toRef": {
                    "displayId": "refs/heads/develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "alice" } },
                "reviewers": [
                    { "user": { "name": "bob" }, "approved": true }
                ]
            }
        ],
        "isLastPage": true
    }
    """

    /// Ein Nicht-Objekt in `values` neben einem gueltigen Eintrag.
    private static let nullEntryJSON = """
    {
        "values": [
            null,
            {
                "id": 20,
                "title": "Valid after null",
                "toRef": {
                    "displayId": "refs/heads/develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "alice" } },
                "reviewers": []
            }
        ],
        "isLastPage": true
    }
    """

    /// Ein Reviewer-Eintrag, der ein Nicht-Objekt ist, neben einem
    /// gueltigen Reviewer.
    private static let nullReviewerJSON = """
    {
        "values": [
            {
                "id": 21,
                "title": "Reviewer with null sibling",
                "toRef": {
                    "displayId": "refs/heads/develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "alice" } },
                "reviewers": [
                    null,
                    { "user": { "name": "bob" }, "status": "APPROVED" }
                ]
            }
        ],
        "isLastPage": true
    }
    """

    /// `displayId` ohne `refs/heads/`-Praefix, wie es das
    /// Dashboard-Endpoint als Normalfall liefert.
    private static let plainDisplayIdJSON = """
    {
        "values": [
            {
                "id": 22,
                "title": "Plain display id",
                "toRef": {
                    "displayId": "develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "alice" } },
                "reviewers": []
            }
        ],
        "isLastPage": true
    }
    """

    /// Ein gueltiger Eintrag, dessen `links.self` zuerst ein Nicht-Objekt
    /// und danach einen gueltigen Link enthaelt.
    private static let garbageSelfLinkJSON = """
    {
        "values": [
            {
                "id": 23,
                "title": "Garbage before valid self link",
                "toRef": {
                    "displayId": "refs/heads/develop",
                    "repository": {
                        "slug": "app",
                        "project": { "key": "REFI" }
                    }
                },
                "author": { "user": { "name": "alice" } },
                "reviewers": [],
                "links": {
                    "self": [
                        null,
                        { "href": "https://bitbucket.example.com/pr/23" }
                    ]
                }
            }
        ],
        "isLastPage": true
    }
    """

    @Test func parsesAllThreePullRequests() {
        let page = BitbucketResponseParser.parsePage(Data(Self.threePullRequestsJSON.utf8))
        #expect(page.values.count == 3)
    }

    @Test func firstPullRequestFieldsAreMappedCompletely() {
        let page = BitbucketResponseParser.parsePage(Data(Self.threePullRequestsJSON.utf8))
        let pr = page.values[0]
        #expect(pr.id == 1)
        #expect(pr.title == "Fix login bug")
        #expect(pr.projectKey == "REFI")
        #expect(pr.repoSlug == "app")
        #expect(pr.targetBranch == "develop")
        #expect(pr.authorName == "alice")
        #expect(pr.url == "https://bitbucket.example.com/projects/REFI/repos/app/pull-requests/1")
        #expect(pr.updatedAt?.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test func firstPullRequestReviewerStatusesAreTranslated() {
        let page = BitbucketResponseParser.parsePage(Data(Self.threePullRequestsJSON.utf8))
        let pr = page.values[0]
        #expect(pr.reviewers.count == 2)
        #expect(pr.reviewers[0].name == "bob")
        #expect(pr.reviewers[0].status == .approved)
        #expect(pr.reviewers[1].name == "carol")
        #expect(pr.reviewers[1].status == .unapproved)
    }

    @Test func secondPullRequestHasNoOpenTaskCountRatherThanZero() {
        let page = BitbucketResponseParser.parsePage(Data(Self.threePullRequestsJSON.utf8))
        let pr = page.values[1]
        #expect(pr.openTaskCount == nil)
    }

    @Test func firstPullRequestOpenTaskCountIsRead() {
        let page = BitbucketResponseParser.parsePage(Data(Self.threePullRequestsJSON.utf8))
        let pr = page.values[0]
        #expect(pr.openTaskCount == 3)
    }

    @Test func thirdPullRequestStripsRefsHeadsPrefix() {
        let page = BitbucketResponseParser.parsePage(Data(Self.threePullRequestsJSON.utf8))
        let pr = page.values[2]
        #expect(pr.targetBranch == "release/1.2")
    }

    @Test func thirdPullRequestReviewerStatusNeedsWorkIsTranslated() {
        let page = BitbucketResponseParser.parsePage(Data(Self.threePullRequestsJSON.utf8))
        let pr = page.values[2]
        #expect(pr.reviewers.count == 1)
        #expect(pr.reviewers[0].name == "frank")
        #expect(pr.reviewers[0].status == .needsWork)
    }

    @Test func paginationFieldsAreRead() {
        let page = BitbucketResponseParser.parsePage(Data(Self.threePullRequestsJSON.utf8))
        #expect(page.isLastPage == false)
        #expect(page.nextPageStart == 50)
    }

    @Test func lastPageWithoutNextPageStartYieldsNil() {
        let page = BitbucketResponseParser.parsePage(Data(Self.lastPageJSON.utf8))
        #expect(page.isLastPage == true)
        #expect(page.nextPageStart == nil)
    }

    @Test func brokenJSONYieldsEmptyLastPage() {
        let page = BitbucketResponseParser.parsePage(Data("nicht json".utf8))
        #expect(page.values.isEmpty)
        #expect(page.isLastPage == true)
        #expect(page.nextPageStart == nil)
    }

    @Test func entryWithoutAuthorIsSkippedRestSurvives() {
        let page = BitbucketResponseParser.parsePage(Data(Self.missingAuthorJSON.utf8))
        #expect(page.values.count == 1)
        #expect(page.values[0].id == 11)
    }

    @Test func reviewerWithoutStatusFallsBackToApprovedBool() {
        let page = BitbucketResponseParser.parsePage(Data(Self.approvedFallbackJSON.utf8))
        #expect(page.values.count == 1)
        let reviewers = page.values[0].reviewers
        #expect(reviewers.count == 1)
        #expect(reviewers[0].name == "bob")
        #expect(reviewers[0].status == .approved)
    }

    @Test func nullEntryIsSkippedRestSurvives() {
        let page = BitbucketResponseParser.parsePage(Data(Self.nullEntryJSON.utf8))
        #expect(page.values.count == 1)
        #expect(page.values[0].id == 20)
        #expect(page.isLastPage == true)
    }

    @Test func nullReviewerIsSkippedRestSurvives() {
        let page = BitbucketResponseParser.parsePage(Data(Self.nullReviewerJSON.utf8))
        #expect(page.values.count == 1)
        let reviewers = page.values[0].reviewers
        #expect(reviewers.count == 1)
        #expect(reviewers[0].name == "bob")
        #expect(reviewers[0].status == .approved)
    }

    @Test func displayIdWithoutPrefixIsUsedAsIs() {
        let page = BitbucketResponseParser.parsePage(Data(Self.plainDisplayIdJSON.utf8))
        #expect(page.values.count == 1)
        #expect(page.values[0].targetBranch == "develop")
    }

    @Test func lastPageEntryWithoutLinksOrUpdatedDateHasDefaults() {
        let page = BitbucketResponseParser.parsePage(Data(Self.lastPageJSON.utf8))
        let pr = page.values[0]
        #expect(pr.url == "")
        #expect(pr.updatedAt == nil)
    }

    @Test func garbageBeforeValidSelfLinkIsSkipped() {
        let page = BitbucketResponseParser.parsePage(Data(Self.garbageSelfLinkJSON.utf8))
        #expect(page.values.count == 1)
        #expect(page.values[0].url == "https://bitbucket.example.com/pr/23")
    }
}
