import Foundation
import XCTest
import MangaKitchenCore
@testable import MangaKitchenApp

final class WebBatchSnapshotTests: XCTestCase {
    func testSharedIndexPreservesOrderMissingPagesFailuresAndRenames() throws {
        var pages = (0..<25).map {
            ComicPage(index: $0 + 1, title: "頁 \($0)", sourceURL: URL(fileURLWithPath: "/sample/\($0).png"),
                      pixelWidth: 100, pixelHeight: 200)
        }
        let missing = UUID()
        var job = BatchJob(projectID: UUID(), projectName: "測試", operation: .translate,
                           pageIDs: [pages[4].id, missing, pages[0].id])
        job.currentPageID = pages[4].id
        job.completedPageIDs = [pages[0].id]
        job.failures = [BatchPageFailure(pageID: missing, message: "已移除")]
        let jobs = [job, job]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for title in ["頁 4", "更新名稱"] {
            pages[4].title = title
            let snapshots = WebBatchJob.snapshots(jobs: jobs, pages: pages)
            XCTAssertEqual(try encoder.encode(snapshots),
                           try encoder.encode(jobs.map { WebBatchJob(job: $0, pages: pages) }))
            XCTAssertEqual(snapshots.map(\.currentPageTitle), [title, title])
            XCTAssertEqual(snapshots[0].failures.first?.pageTitle, missing.uuidString)
            XCTAssertEqual(snapshots[0].pageIDs, job.pageIDs)
        }
        XCTAssertTrue(WebBatchJob.snapshots(jobs: [], pages: pages).isEmpty)
    }
}
