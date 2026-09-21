import Foundation
import XCTest
import MangaKitchenCore
@testable import MangaKitchenApp

final class WorkflowConcurrencySmokeTests: XCTestCase {
    @MainActor
    func testCancellationErrorCannotMarkBatchCompleted() async {
        let coordinator = AppBatchWorkflowCoordinator { _, _ in }
        let projectID = UUID()
        let job = BatchJob(projectID: projectID, projectName: "測試", operation: .translate, pageIDs: [UUID(), UUID()])
        _ = coordinator.enqueue(job)
        let finished = expectation(description: "取消後佇列結束")
        coordinator.startIfNeeded(activeProjectID: projectID,
            executePage: { _, _, _ in throw CancellationError() },
            jobDidStart: { _ in }, pageDidStart: { _ in }, pageDidCancel: { _, _ in },
            pageDidFail: { _, _, _ in XCTFail("取消不可視為失敗") }, pageDidFinish: { _ in },
            queueDidFinish: { cancelled in XCTAssertTrue(cancelled); finished.fulfill() })
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(coordinator.job(id: job.id)?.status, .cancelled)
        XCTAssertFalse(coordinator.isRunning)
    }

    @MainActor
    func testForcedRecalculationIsNotDeduplicatedWithNormalJob() {
        let coordinator = AppBatchWorkflowCoordinator { _, _ in }
        let job = BatchJob(projectID: UUID(), projectName: "測試", operation: .translate, pageIDs: [UUID()])
        _ = coordinator.enqueue(job)
        var forced = job
        forced.id = UUID()
        forced.forceRecalculation = true
        if case .existing = coordinator.enqueue(forced) { XCTFail("重算語意不同") }
        XCTAssertEqual(coordinator.jobs.count, 2)
        if case .added = coordinator.enqueue(forced) { XCTFail("相同工作應去重") }
    }

    func testGateSerializesSuspendingOperationsAndReleasesAfterFailure() async throws {
        let gate = AsyncOperationGate()
        let counter = ConcurrentCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.withPermit {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(2))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 1)
        do {
            try await gate.withPermit { throw CancellationError() }
        } catch {}
        let value = try await gate.withPermit { 42 }
        XCTAssertEqual(value, 42)
    }

    func testWaitingOperationCancelsBeforeCurrentOperationEnds() async throws {
        let gate = AsyncOperationGate()
        let entered = expectation(description: "第一筆已進入")
        let release = AsyncSignal()
        let first = Task {
            try await gate.withPermit { entered.fulfill(); await release.wait() }
        }
        await fulfillment(of: [entered], timeout: 3)
        let cancelled = expectation(description: "等待者立即取消")
        let second = Task {
            do {
                try await gate.withPermit { XCTFail("取消的等待者不可執行") }
            } catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail(error.localizedDescription) }
        }
        try await Task.sleep(for: .milliseconds(30))
        second.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        await release.send()
        try await first.value
        await second.value
        let value = try await gate.withPermit { true }
        XCTAssertTrue(value)
    }
}

private actor ConcurrentCounter {
    private var active = 0
    private(set) var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

private actor AsyncSignal {
    private var sent = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !sent else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func send() { sent = true; continuation?.resume(); continuation = nil }
}
