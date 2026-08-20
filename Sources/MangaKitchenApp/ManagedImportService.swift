import AppKit
import Foundation
import MangaKitchenRuntime
import PDFKit

struct ManagedImportService {
    private let fileManager = FileManager.default

    func materialize(_ inputs: [URL], under root: URL) throws -> URL {
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try append(inputs, to: destination)
        return destination
    }

    func append(_ inputs: [URL], to destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for input in inputs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: input.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try copyImages(from: input, to: destination)
            } else {
                try importFile(input, to: destination)
            }
        }
        guard !(try ComicDirectoryScanner().scan(destination)).isEmpty else {
            throw ManagedImportError.noSupportedPages
        }
    }

    private func importFile(_ input: URL, to destination: URL) throws {
        let ext = input.pathExtension.lowercased()
        if ComicDirectoryScanner.supportedExtensions.contains(ext) {
            try fileManager.copyItem(at: input, to: uniqueDestination(for: input.lastPathComponent, in: destination))
        } else if ext == "pdf" {
            try renderPDF(input, to: destination)
        } else if ["zip", "cbz", "rar", "cbr"].contains(ext) {
            try extractArchive(input, to: destination, useBSDTar: ext == "rar" || ext == "cbr")
        }
    }

    private func copyImages(from source: URL, to destination: URL) throws {
        let urls = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])?.compactMap { $0 as? URL } ?? []
        for url in urls where ComicDirectoryScanner.supportedExtensions.contains(url.pathExtension.lowercased()) {
            let relative = url.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: url, to: uniqueDestination(for: target.lastPathComponent, in: target.deletingLastPathComponent()))
        }
    }

    private func extractArchive(_ input: URL, to destination: URL, useBSDTar: Bool) throws {
        let extraction = uniqueDirectory(
            for: input.deletingPathExtension().lastPathComponent,
            in: destination
        )
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: useBSDTar ? "/usr/bin/bsdtar" : "/usr/bin/ditto")
        process.arguments = useBSDTar
            ? ["-xf", input.path, "-C", extraction.path]
            : ["-x", "-k", input.path, extraction.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ManagedImportError.archiveExtractionFailed(input.lastPathComponent)
        }
    }

    private func renderPDF(_ input: URL, to destination: URL) throws {
        guard let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw ManagedImportError.invalidPDF(input.lastPathComponent)
        }
        let folder = uniqueDirectory(
            for: input.deletingPathExtension().lastPathComponent,
            in: destination
        )
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(2.0, max(1.0, 2400.0 / max(bounds.width, bounds.height)))
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: folder.appendingPathComponent(String(format: "%04d.png", index + 1)), options: .atomic)
        }
    }

    private func uniqueDestination(for name: String, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func uniqueDirectory(for name: String, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: base.path) else { return base }
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(name)-\(index)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

}

enum ManagedImportError: LocalizedError {
    case noSupportedPages
    case archiveExtractionFailed(String)
    case invalidPDF(String)

    var errorDescription: String? {
        switch self {
        case .noSupportedPages: "匯入內容沒有支援的漫畫頁面。"
        case let .archiveExtractionFailed(name): "無法解開壓縮檔：\(name)。"
        case let .invalidPDF(name): "無法讀取 PDF：\(name)。"
        }
    }
}
