import XCTest
import SarangiKit
@testable import TarabdaarCore

final class EngineBuildCoordinatorTests: XCTestCase {
    private final class Scheduler {
        var jobs: [() -> Void] = []
        func enqueue(_ job: @escaping () -> Void) { jobs.append(job) }
        func runNext() { jobs.removeFirst()() }
    }

    /// Failed replacements preserve publication and permit retry; pending and ready enables reuse work.
    func testFailurePreservesEngineAndAllowsRetry() {
        let builds = EngineBuildCoordinator<Int>()
        let worker = Scheduler(), publication = Scheduler()
        var mounted: Int?, published: [Int?] = [], failures = 0
        func enable(_ result: EngineBuildResult<Int>) {
            guard builds.needsBuild else { return }
            request(result)
        }
        func request(_ result: EngineBuildResult<Int>) {
            builds.request(scheduleBuild: worker.enqueue, schedulePublication: publication.enqueue,
                build: { result }, publish: { mounted = $0; published.append($0) },
                failed: { failures += 1 })
        }

        enable(.failed)
        enable(.ready(99))
        XCTAssertEqual(worker.jobs.count, 1)
        worker.runNext(); publication.runNext()
        XCTAssertTrue(builds.needsBuild)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(failures, 1)

        enable(.ready(1))
        worker.runNext(); publication.runNext()
        builds.invalidate()
        enable(.ready(99))
        XCTAssertTrue(worker.jobs.isEmpty)
        XCTAssertEqual(mounted, 1)

        request(.failed)
        worker.runNext(); publication.runNext()
        XCTAssertEqual(mounted, 1)
        XCTAssertEqual(published, [1])
        builds.invalidate()
        XCTAssertTrue(builds.needsBuild)
        enable(.ready(2))
        worker.runNext(); publication.runNext()
        XCTAssertEqual(published, [1, 2])
        XCTAssertEqual(failures, 2)
    }

    /// Superseded queued work never constructs, and stale or disabled in-flight results never publish.
    func testSupersededAndInvalidatedBuildsCannotPublish() {
        let builds = EngineBuildCoordinator<Int>()
        let worker = Scheduler(), publication = Scheduler()
        var constructed: [Int] = [], published: [Int?] = []
        func request(_ value: Int, duringBuild: (() -> Void)? = nil) {
            builds.request(scheduleBuild: worker.enqueue, schedulePublication: publication.enqueue,
                build: { constructed.append(value); duringBuild?(); return .ready(value) },
                publish: { published.append($0) }, failed: { XCTFail("Unexpected failure") })
        }

        request(1)
        worker.runNext()
        XCTAssertTrue(builds.isPending, "An unpublished result must still defer in-place edits")
        request(2)
        request(3)
        worker.runNext()
        worker.runNext()
        publication.runNext()
        XCTAssertTrue(published.isEmpty)
        XCTAssertFalse(builds.needsBuild)
        publication.runNext()
        XCTAssertEqual(constructed, [1, 3])
        XCTAssertEqual(published, [3])
        XCTAssertFalse(builds.isPending)

        request(4, duringBuild: { request(5) })
        worker.runNext()
        XCTAssertTrue(publication.jobs.isEmpty)
        builds.invalidate()
        worker.runNext()
        request(6)
        worker.runNext()
        builds.invalidate()
        publication.runNext()
        XCTAssertEqual(constructed, [1, 3, 4, 6])
        XCTAssertEqual(published, [3])
        XCTAssertTrue(builds.needsBuild)
        XCTAssertTrue(publication.jobs.isEmpty)
    }

    /// Empty scales and an entirely capped Sitar grid deliberately clear the source without retrying.
    func testEmptyPluckedBanksAreSuccessfulClears() {
        for (tonic, ratios, artifact) in [
            (220.0, [Double](), TanpuraVoiceSource.Artifact.tanpura),
            (8000.0, [1.0], TanpuraVoiceSource.Artifact.sitar)
        ] {
            let result = TanpuraVoiceSource.buildResult(tonicHz: tonic,
                                                       scaleRatios: ratios, artifact: artifact)
            guard case .empty = result else { XCTFail("Expected an empty grid"); continue }
            let builds = EngineBuildCoordinator<TanpuraEngine>()
            let worker = Scheduler(), publication = Scheduler()
            var clears = 0
            builds.request(scheduleBuild: worker.enqueue, schedulePublication: publication.enqueue,
                build: { result }, publish: { XCTAssertNil($0); clears += 1 },
                failed: { XCTFail("Empty grids are not failures") })
            worker.runNext(); publication.runNext()
            XCTAssertEqual(clears, 1)
            XCTAssertFalse(builds.needsBuild)
        }
    }
}
