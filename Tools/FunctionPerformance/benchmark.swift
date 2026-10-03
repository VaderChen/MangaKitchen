import CoreGraphics
import CoreML
import Foundation
import MangaKitchenCore

@main
struct FunctionBenchmark {
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url)
    }

    static func raster(width: Int, height: Int, mask: Bool, glyphScale: Int = 1) throws -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.setFillColor(gray: mask ? 0 : 0.88, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: mask ? 1 : 0, alpha: 1)
        for y in stride(from: 24, to: height - 24, by: 48) {
            for x in stride(from: 24, to: width - 24, by: 40) {
                context.fill(CGRect(x: x, y: y, width: 12 * glyphScale, height: 16 * glyphScale))
            }
        }
        return context.makeImage()!
    }

    static func main() async throws {
        let mode = CommandLine.arguments[1]
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: CommandLine.arguments[3])
        let start: Date
        var seconds: Double

        switch mode {
        case "clean-auto", "clean-fixed", "refine":
            let width = 2048, height = 3072
            let source = output.deletingPathExtension().appendingPathExtension("source.png")
            let mask = output.deletingPathExtension().appendingPathExtension("mask.png")
            let glyphScale = mode == "refine" ? 2 : 1
            try CGImageIO.writePNG(raster(width: width, height: height, mask: false, glyphScale: glyphScale), to: source)
            try CGImageIO.writePNG(raster(width: width, height: height, mask: true, glyphScale: glyphScale), to: mask)
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: mask)
            }
            let region = DialogueRegion(id: id(1),
                bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                sourceText: String(repeating: "字", count: 1024), confidence: 1)
            start = Date()
            if mode == "refine" {
                let regions = try await MangaTextMaskRefiner(maximumComponentsPerRegion: 4_000)
                    .refineMasks(sourceURL: source, regions: [region])
                seconds = Date().timeIntervalSince(start)
                precondition(regions[0].maskRefinementApplied && regions[0].maskPolygons.count > 100)
                try save(regions, to: output)
            } else {
                try await CPUBubbleCleaner().clean(sourceURL: source, maskURL: mask,
                    regions: [region], fillColorHex: mode == "clean-fixed" ? "#FFFFFF" : nil,
                    outputURL: output, progress: { _ in })
                seconds = Date().timeIntervalSince(start)
            }
        case "bubbles":
            let image = try CGImageIO.load(from: root.appendingPathComponent("Samples/Gemini_Image_001.jpeg"))
            let runtime = try MangaBubbleSegmentationCoreMLRuntime(modelURL: root.appendingPathComponent(
                "Sources/MangaKitchenApp/Resources/Models/MangaBubbleSegmentation.mlpackage"))
            _ = try runtime.detectBubbles(in: image) // Exclude model compilation/load and first prediction.
            var results: [BubbleResult] = []
            start = Date()
            for _ in 0..<5 {
                results = try runtime.detectBubbles(in: image).map(BubbleResult.init)
            }
            seconds = Date().timeIntervalSince(start) / 5
            precondition(!results.isEmpty && results.contains { !$0.polygons.isEmpty })
            try save(results, to: output)
        case "jobs":
            let pages = (0..<5_000).map {
                ComicPage(id: id($0 + 1), index: $0 + 1, title: "頁 \($0)",
                          sourceURL: URL(fileURLWithPath: "/sample/\($0).png"), pixelWidth: 100, pixelHeight: 200)
            }
            let jobs = (0..<200).map { index in
                BatchJob(id: id(index + 10_000), projectID: id(20_000), projectName: "測試",
                         operation: .translate, pageIDs: pages.prefix(100).map(\.id), status: .running,
                         currentPageID: pages[index].id,
                         failures: [BatchPageFailure(pageID: pages[index + 1].id, message: "測試失敗")])
            }
            var snapshots: [WebBatchJob] = []
            start = Date()
            for _ in 0..<10 {
                #if OPTIMIZED_FUNCTIONS
                snapshots = WebBatchJob.snapshots(jobs: jobs, pages: pages)
                #else
                snapshots = jobs.map { WebBatchJob(job: $0, pages: pages) }
                #endif
                precondition(snapshots.count == jobs.count)
            }
            seconds = Date().timeIntervalSince(start) / 10
            try save(snapshots, to: output)
        default:
            fatalError("Unknown benchmark mode: \(mode)")
        }
        print("mode=\(mode) seconds=\(seconds)")
    }

    struct BubbleResult: Codable {
        let bounds: NormalizedRect
        let polygons: [[NormalizedPoint]]
        let layout: NormalizedRect?
        init(_ value: BubbleDetection) {
            bounds = value.bounds
            polygons = value.maskPolygons
            layout = value.layoutBounds
        }
    }
}
