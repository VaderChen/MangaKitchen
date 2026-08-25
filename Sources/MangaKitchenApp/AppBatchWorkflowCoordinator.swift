import Foundation
import MangaKitchenCore

/// 單一序列批次佇列。此協調器只管理工作生命週期；實際頁面業務由呼叫端注入。
@MainActor
final class AppBatchWorkflowCoordinator {
    enum EnqueueResult {
        case added(BatchJob)
        case existing(BatchJob)
    }

    struct CancellationResult {
        var hadActiveTask: Bool
        var activePages: [(pageID: UUID, operation: BatchOperation)]
    }

    typealias StateDidChange = (_ jobs: [BatchJob], _ isRunning: Bool) -> Void
    typealias ExecutePage = (
        _ operation: BatchOperation,
        _ pageID: UUID,
        _ forceRecalculation: Bool
    ) async throws -> Void

    private(set) var jobs: [BatchJob] = []
    private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private let stateDidChange: StateDidChange

    init(stateDidChange: @escaping StateDidChange) {
        self.stateDidChange = stateDidChange
    }

    func replaceJobs(_ jobs: [BatchJob]) {
        self.jobs = jobs
        publish()
    }

    func removeJobs(projectID: UUID) {
        jobs.removeAll { $0.projectID == projectID }
        publish()
    }

    func job(id: UUID) -> BatchJob? {
        jobs.first { $0.id == id }
    }

    func enqueue(_ job: BatchJob) -> EnqueueResult {
        let pageIDs = Set(job.pageIDs)
        if let existing = jobs.last(where: { candidate in
            candidate.projectID == job.projectID
                && [.queued, .running].contains(candidate.status)
                && candidate.operation == job.operation
                && Set(candidate.pageIDs) == pageIDs
        }) {
            return .existing(existing)
        }
        jobs.append(job)
        publish()
        return .added(job)
    }

    func clearFinishedJobs() {
        jobs.removeAll { ![.queued, .running].contains($0.status) }
        publish()
    }

    func containsRunning(pageID: UUID, operation: BatchOperation? = nil) -> Bool {
        jobs.contains { job in
            job.status == .running
                && job.currentPageID == pageID
                && operation.map { $0 == job.operation } != false
        }
    }

    func cancel() -> CancellationResult {
        let result = CancellationResult(
            hadActiveTask: task != nil,
            activePages: jobs.compactMap { job in
                guard job.status == .running, let pageID = job.currentPageID else { return nil }
                return (pageID, job.operation)
            }
        )
        let now = Date()
        for index in jobs.indices where [.queued, .running].contains(jobs[index].status) {
            jobs[index].status = .cancelled
            jobs[index].currentPageID = nil
            jobs[index].finishedAt = now
        }
        task?.cancel()
        publish()
        return result
    }

    func startIfNeeded(
        activeProjectID: UUID?,
        executePage: @escaping ExecutePage,
        jobDidStart: @escaping (BatchJob) -> Void,
        pageDidStart: @escaping (UUID) -> Void,
        pageDidCancel: @escaping (UUID, BatchOperation) -> Void,
        pageDidFail: @escaping (UUID, BatchOperation, Error) -> Void,
        pageDidFinish: @escaping (UUID) -> Void,
        queueDidFinish: @escaping (_ cancelled: Bool) -> Void
    ) {
        guard task == nil, jobs.contains(where: { $0.status == .queued }) else { return }
        isRunning = true
        publish()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var wasCancelled = false
            defer {
                self.isRunning = false
                self.task = nil
                self.publish()
                queueDidFinish(wasCancelled)
            }

            while let jobID = self.jobs.first(where: { $0.status == .queued })?.id {
                guard !Task.isCancelled else {
                    wasCancelled = true
                    break
                }
                guard let jobIndex = self.jobs.firstIndex(where: { $0.id == jobID }) else {
                    continue
                }
                guard self.jobs[jobIndex].projectID == activeProjectID else {
                    self.jobs[jobIndex].status = .cancelled
                    self.jobs[jobIndex].finishedAt = Date()
                    self.publish()
                    continue
                }

                self.jobs[jobIndex].status = .running
                self.jobs[jobIndex].startedAt = Date()
                self.publish()
                let job = self.jobs[jobIndex]
                jobDidStart(job)

                for pageID in job.pageIDs {
                    guard !Task.isCancelled,
                          let currentIndex = self.jobs.firstIndex(where: { $0.id == jobID }),
                          self.jobs[currentIndex].status == .running else {
                        wasCancelled = Task.isCancelled
                        break
                    }
                    self.jobs[currentIndex].currentPageID = pageID
                    self.publish()
                    pageDidStart(pageID)
                    do {
                        try await executePage(
                            job.operation,
                            pageID,
                            job.forceRecalculation
                        )
                        try Task.checkCancellation()
                        guard let resultIndex = self.jobs.firstIndex(where: { $0.id == jobID }),
                              self.jobs[resultIndex].status == .running else {
                            pageDidFinish(pageID)
                            break
                        }
                        self.jobs[resultIndex].completedPageIDs.append(pageID)
                        self.publish()
                    } catch is CancellationError {
                        wasCancelled = true
                        pageDidCancel(pageID, job.operation)
                        pageDidFinish(pageID)
                        break
                    } catch {
                        guard let resultIndex = self.jobs.firstIndex(where: { $0.id == jobID }),
                              self.jobs[resultIndex].status == .running else {
                            pageDidFinish(pageID)
                            break
                        }
                        self.jobs[resultIndex].failures.append(
                            BatchPageFailure(pageID: pageID, message: error.localizedDescription)
                        )
                        self.publish()
                        pageDidFail(pageID, job.operation, error)
                    }
                    pageDidFinish(pageID)
                }

                guard let finalIndex = self.jobs.firstIndex(where: { $0.id == jobID }),
                      self.jobs[finalIndex].status == .running else {
                    if Task.isCancelled { wasCancelled = true; break }
                    continue
                }
                self.jobs[finalIndex].currentPageID = nil
                self.jobs[finalIndex].finishedAt = Date()
                if Task.isCancelled {
                    self.jobs[finalIndex].status = .cancelled
                    wasCancelled = true
                } else {
                    self.jobs[finalIndex].status = self.jobs[finalIndex].failures.isEmpty
                        ? .completed
                        : .completedWithErrors
                }
                self.publish()
                if wasCancelled { break }
            }

            if wasCancelled || Task.isCancelled {
                wasCancelled = true
                let now = Date()
                for index in self.jobs.indices where self.jobs[index].status == .queued {
                    self.jobs[index].status = .cancelled
                    self.jobs[index].finishedAt = now
                }
                self.publish()
            }
        }
    }

    private func publish() {
        stateDidChange(jobs, isRunning)
    }
}
