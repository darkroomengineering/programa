import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class ReviewMergeReadinessTests: XCTestCase {
    private let noThreads = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#

    func testGreenOpenPullRequestIsReadyToMerge() throws {
        let pullRequestJSON = """
        {"isDraft":false,"state":"OPEN","statusCheckRollup":[
          {"__typename":"CheckRun","conclusion":"SUCCESS","name":"change-detection","status":"COMPLETED","workflowName":"CI"},
          {"__typename":"CheckRun","conclusion":"SKIPPED","name":"windows-build","status":"COMPLETED","workflowName":"CI"},
          {"__typename":"StatusContext","context":"vercel","state":"SUCCESS"}
        ]}
        """
        let readiness = try XCTUnwrap(ReviewMergeReadinessProber.parse(pullRequestJSON: pullRequestJSON, reviewThreadsJSON: noThreads))
        XCTAssertEqual(readiness.state, .open)
        XCTAssertEqual(readiness.failingCheckNames, [])
        XCTAssertEqual(readiness.pendingCheckCount, 0)
        XCTAssertEqual(readiness.passingCheckCount, 3)
        XCTAssertEqual(readiness.unresolvedThreadCount, 0)
        XCTAssertTrue(readiness.isReadyToMerge)
    }

    func testFailingAndPendingChecksAreCountedAndNamedOnce() throws {
        let pullRequestJSON = """
        {"isDraft":false,"state":"OPEN","statusCheckRollup":[
          {"__typename":"CheckRun","conclusion":"FAILURE","name":"unit-tests","status":"COMPLETED"},
          {"__typename":"CheckRun","conclusion":"FAILURE","name":"unit-tests","status":"COMPLETED"},
          {"__typename":"CheckRun","conclusion":"TIMED_OUT","name":"e2e","status":"COMPLETED"},
          {"__typename":"CheckRun","conclusion":"","name":"build","status":"IN_PROGRESS"},
          {"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"},
          {"__typename":"StatusContext","context":"deploy","state":"PENDING"},
          {"__typename":"CheckRun","conclusion":"SUCCESS","name":"lint","status":"COMPLETED"}
        ]}
        """
        let readiness = try XCTUnwrap(ReviewMergeReadinessProber.parse(pullRequestJSON: pullRequestJSON, reviewThreadsJSON: noThreads))
        XCTAssertEqual(readiness.failingCheckNames, ["unit-tests", "e2e", "ci/legacy"])
        XCTAssertEqual(readiness.pendingCheckCount, 2)
        XCTAssertEqual(readiness.passingCheckCount, 1)
        XCTAssertFalse(readiness.isReadyToMerge)
    }

    func testUnresolvedThreadsAreCountedAndBlockReadiness() throws {
        let threadsJSON = """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
          {"isResolved":false},{"isResolved":true},{"isResolved":false},null
        ]}}}}}
        """
        let readiness = try XCTUnwrap(ReviewMergeReadinessProber.parse(
            pullRequestJSON: #"{"isDraft":false,"state":"OPEN","statusCheckRollup":[]}"#,
            reviewThreadsJSON: threadsJSON
        ))
        XCTAssertEqual(readiness.unresolvedThreadCount, 2)
        XCTAssertEqual(readiness.passingCheckCount, 0)
        XCTAssertFalse(readiness.isReadyToMerge)
    }

    func testDraftMergedAndClosedStates() throws {
        let draft = try XCTUnwrap(ReviewMergeReadinessProber.parse(
            pullRequestJSON: #"{"isDraft":true,"state":"OPEN","statusCheckRollup":[]}"#,
            reviewThreadsJSON: noThreads
        ))
        XCTAssertEqual(draft.state, .draft)
        XCTAssertFalse(draft.isReadyToMerge, "A draft cannot be merged even when green")

        let merged = try XCTUnwrap(ReviewMergeReadinessProber.parse(
            pullRequestJSON: #"{"isDraft":false,"state":"MERGED","statusCheckRollup":null}"#,
            reviewThreadsJSON: nil
        ))
        XCTAssertEqual(merged.state, .merged)

        let closed = try XCTUnwrap(ReviewMergeReadinessProber.parse(
            pullRequestJSON: #"{"state":"CLOSED"}"#,
            reviewThreadsJSON: nil
        ))
        XCTAssertEqual(closed.state, .closed)
    }

    func testThreadQueryFailureLeavesCountUnknown() throws {
        let pullRequestJSON = #"{"isDraft":false,"state":"OPEN","statusCheckRollup":[]}"#
        let missing = try XCTUnwrap(ReviewMergeReadinessProber.parse(pullRequestJSON: pullRequestJSON, reviewThreadsJSON: nil))
        XCTAssertNil(missing.unresolvedThreadCount)
        XCTAssertFalse(missing.isReadyToMerge)

        let graphQLError = #"{"data":{"repository":null},"errors":[{"message":"Could not resolve to a Repository"}]}"#
        let errored = try XCTUnwrap(ReviewMergeReadinessProber.parse(pullRequestJSON: pullRequestJSON, reviewThreadsJSON: graphQLError))
        XCTAssertNil(errored.unresolvedThreadCount)
    }

    func testUnusablePullRequestJSONReturnsNil() {
        XCTAssertNil(ReviewMergeReadinessProber.parse(pullRequestJSON: "", reviewThreadsJSON: noThreads))
        XCTAssertNil(ReviewMergeReadinessProber.parse(pullRequestJSON: "not json", reviewThreadsJSON: noThreads))
        XCTAssertNil(ReviewMergeReadinessProber.parse(pullRequestJSON: #"{"state":"UNKNOWN"}"#, reviewThreadsJSON: noThreads))
        XCTAssertNil(ReviewMergeReadinessProber.parse(pullRequestJSON: #"[]"#, reviewThreadsJSON: noThreads))
    }

    func testCoordinatesComeOnlyFromGitHubPullRequestURLs() throws {
        let coordinates = try XCTUnwrap(ReviewMergeReadinessProber.coordinates(
            from: try XCTUnwrap(URL(string: "https://github.com/darkroomengineering/programa/pull/469"))
        ))
        XCTAssertEqual(coordinates, .init(owner: "darkroomengineering", name: "programa", number: 469))

        for rawURL in [
            "https://gitlab.com/group/project/-/merge_requests/3",
            "https://github.com/owner/repo/issues/3",
            "https://github.com/owner/repo/pull/abc",
            "https://github.com/owner/pull/3",
            "ftp://github.com/owner/repo/pull/3",
        ] {
            XCTAssertNil(ReviewMergeReadinessProber.coordinates(from: try XCTUnwrap(URL(string: rawURL))), rawURL)
        }
    }
}
