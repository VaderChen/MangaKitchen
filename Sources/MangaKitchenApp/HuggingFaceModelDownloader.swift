import Foundation
import Hub
import MangaKitchenCore
import MangaKitchenRuntime

struct HuggingFaceModelDownloader: Sendable {
    private static let segmentByteCount: Int64 = 16 * 1_024 * 1_024
    private static let maximumConcurrentSegments = 8
    private static let maximumDownloadAttempts = 3

    func download(
        model: DownloadableModelDescriptor,
        storageDirectoryURL: URL,
        progressHandler: @Sendable @escaping (ModelDownloadProgressUpdate) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let storageDirectoryURL = storageDirectoryURL.standardizedFileURL
        let targetDirectoryURL = DownloadableModelCatalog.modelDirectory(
            storageDirectoryURL: storageDirectoryURL,
            model: model
        )

        try fileManager.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )
        let stagingRootURL = storageDirectoryURL
            .appendingPathComponent(".mangakitchen-downloads", isDirectory: true)
        let hub = HubApi(downloadBase: stagingRootURL)

        if DownloadableModelCatalog.isCompleteModelDirectory(targetDirectoryURL, model: model) {
            let dflashFiles = try await optionalDFlashFiles(model: model, targetDirectoryURL: targetDirectoryURL, hub: hub)
            let progress = try ModelDownloadProgressTracker(
                files: dflashFiles ?? [],
                handler: progressHandler
            )
            await progress.report()
            try await downloadDFlashIfNeeded(
                model: model,
                targetDirectoryURL: targetDirectoryURL,
                stagingRootURL: stagingRootURL,
                files: dflashFiles ?? [],
                progress: progress
            )
            await progress.finish()
            return targetDirectoryURL
        }

        let downloadedDirectoryURL = try repositoryDirectoryURL(
            model: model,
            stagingRootURL: stagingRootURL
        )
        if fileManager.fileExists(atPath: downloadedDirectoryURL.path),
           DownloadableModelCatalog.isCompleteModelDirectory(downloadedDirectoryURL, model: model) {
            try prepareDownloadedModel(downloadedDirectoryURL, model: model)
            let finalizedURL = try finalizeDownloadedModel(
                downloadedDirectoryURL,
                targetDirectoryURL: targetDirectoryURL,
                model: model
            )
            let dflashFiles = try await optionalDFlashFiles(model: model, targetDirectoryURL: finalizedURL, hub: hub)
            let progress = try ModelDownloadProgressTracker(
                files: dflashFiles ?? [],
                handler: progressHandler
            )
            await progress.report()
            try await downloadDFlashIfNeeded(
                model: model,
                targetDirectoryURL: finalizedURL,
                stagingRootURL: stagingRootURL,
                files: dflashFiles ?? [],
                progress: progress
            )
            await progress.finish()
            return finalizedURL
        }

        let repository = Hub.Repo(id: model.repositoryID)
        let filenames = try await hub.getFilenames(from: repository)
        guard !filenames.isEmpty else {
            throw ModelDownloadError.emptyRepository(model.repositoryID)
        }

        let modelFiles = try await repositoryFiles(
            filenames: filenames,
            model: model,
            hub: hub
        ).sorted { $0.byteCount > $1.byteCount }
        let dflashFiles = try await optionalDFlashFiles(model: model, targetDirectoryURL: targetDirectoryURL, hub: hub) ?? []
        let files = (modelFiles + dflashFiles).sorted {
            if $0.byteCount == $1.byteCount {
                return "\($0.repositoryID)/\($0.filename)/\($0.destinationFilename)"
                    < "\($1.repositoryID)/\($1.filename)/\($1.destinationFilename)"
            }
            return $0.byteCount > $1.byteCount
        }
        let progress = try ModelDownloadProgressTracker(
            files: files,
            handler: progressHandler
        )
        await progress.report()

        if fileManager.fileExists(atPath: downloadedDirectoryURL.path) {
            try fileManager.removeItem(at: downloadedDirectoryURL)
        }
        try fileManager.createDirectory(
            at: downloadedDirectoryURL,
            withIntermediateDirectories: true
        )
        do {
            try await downloadFiles(
                modelFiles,
                directoryURL: downloadedDirectoryURL,
                progress: progress
            )
        } catch {
            try? fileManager.removeItem(at: downloadedDirectoryURL)
            throw error
        }
        try Task.checkCancellation()
        try prepareDownloadedModel(downloadedDirectoryURL, model: model)
        guard DownloadableModelCatalog.isCompleteModelDirectory(downloadedDirectoryURL, model: model) else {
            throw ModelDownloadError.incompleteRepository(model.repositoryID)
        }

        let finalizedURL = try finalizeDownloadedModel(
            downloadedDirectoryURL,
            targetDirectoryURL: targetDirectoryURL,
            model: model
        )
        try await downloadDFlashIfNeeded(
            model: model,
            targetDirectoryURL: finalizedURL,
            stagingRootURL: stagingRootURL,
            files: dflashFiles,
            progress: progress
        )
        await progress.finish()
        return finalizedURL
    }

    private func optionalDFlashFiles(
        model: DownloadableModelDescriptor,
        targetDirectoryURL: URL,
        hub: HubApi
    ) async throws -> [RepositoryFile]? {
        guard let dflash = model.dflashDraft else { return nil }
        try Task.checkCancellation()
        if isCompleteDFlashDirectory(
            targetDirectoryURL.appendingPathComponent(dflash.directoryName), descriptor: dflash
        ) { return [] }

        let filenames: [String]
        do {
            filenames = try await hub.getFilenames(from: Hub.Repo(id: dflash.repositoryID))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
        guard !filenames.isEmpty,
              dflash.fileNames.allSatisfy({ filenames.contains($0) }) else {
            return nil
        }

        var files: [RepositoryFile] = []
        files.reserveCapacity(dflash.fileNames.count)
        var revision: String?
        for filename in dflash.fileNames {
            try Task.checkCancellation()
            do {
                let metadata = try await hub.getFileMetadata(
                    url: sourceURL(repositoryID: dflash.repositoryID, filename: filename, revision: revision ?? "main")
                )
                let pinnedRevision = try ModelDownloadValidation.pinnedRevision(metadata.commitHash, previous: revision)
                revision = pinnedRevision
                guard let size = metadata.size, size > 0 else { return nil }
                files.append(
                    RepositoryFile(
                        repositoryID: dflash.repositoryID,
                        filename: filename,
                        destinationFilename: filename,
                        byteCount: Int64(size),
                        revision: pinnedRevision
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return nil
            }
        }
        return files
    }

    private func downloadDFlashIfNeeded(
        model: DownloadableModelDescriptor,
        targetDirectoryURL: URL,
        stagingRootURL: URL,
        files: [RepositoryFile],
        progress: ModelDownloadProgressTracker
    ) async throws {
        guard let dflash = model.dflashDraft,
              !isCompleteDFlashDirectory(
                  targetDirectoryURL.appendingPathComponent(dflash.directoryName),
                  descriptor: dflash
              ) else { return }

        let fileManager = FileManager.default
        var cleanupURL: URL?
        do {
            try Task.checkCancellation()
            let stagedDirectoryURL = try repositoryDirectoryURL(
                repositoryID: dflash.repositoryID,
                stagingRootURL: stagingRootURL
            )
            if isCompleteDFlashDirectory(stagedDirectoryURL, descriptor: dflash) {
                try installDFlashDirectory(
                    stagedDirectoryURL,
                    targetDirectoryURL: targetDirectoryURL,
                    descriptor: dflash
                )
                return
            }

            guard !files.isEmpty else { return }
            cleanupURL = stagedDirectoryURL

            if fileManager.fileExists(atPath: stagedDirectoryURL.path) {
                try fileManager.removeItem(at: stagedDirectoryURL)
            }
            try fileManager.createDirectory(
                at: stagedDirectoryURL,
                withIntermediateDirectories: true
            )
            try await downloadFiles(
                files,
                directoryURL: stagedDirectoryURL,
                progress: progress
            )
            guard isCompleteDFlashDirectory(stagedDirectoryURL, descriptor: dflash) else {
                try? fileManager.removeItem(at: stagedDirectoryURL)
                return
            }
            try installDFlashDirectory(
                stagedDirectoryURL,
                targetDirectoryURL: targetDirectoryURL,
                descriptor: dflash
            )
        } catch is CancellationError {
            if let cleanupURL { try? fileManager.removeItem(at: cleanupURL) }
            throw CancellationError()
        } catch {
            if let cleanupURL { try? fileManager.removeItem(at: cleanupURL) }
            try Task.checkCancellation()
        }
    }

    private func installDFlashDirectory(
        _ stagedDirectoryURL: URL,
        targetDirectoryURL: URL,
        descriptor: DownloadableModelDescriptor.DFlashDraft
    ) throws {
        let destinationURL = try destinationURL(
            for: descriptor.directoryName,
            in: targetDirectoryURL
        )
        try RecoverableDirectoryInstaller.install(from: stagedDirectoryURL, to: destinationURL) { directory in
            guard isCompleteDFlashDirectory(directory, descriptor: descriptor) else {
                throw ModelDownloadError.incompleteRepository(descriptor.repositoryID)
            }
        }
    }

    private func isCompleteDFlashDirectory(
        _ directoryURL: URL,
        descriptor: DownloadableModelDescriptor.DFlashDraft
    ) -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directoryURL.appendingPathComponent(Self.inProgressMarker).path),
              DownloadableModelCatalog.isNonemptyRegularFile(directoryURL.appendingPathComponent("config.json")),
              descriptor.fileNames.allSatisfy({
                  DownloadableModelCatalog.isNonemptyRegularFile(directoryURL.appendingPathComponent($0))
              }),
              let data = try? Data(contentsOf: directoryURL.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let architectures = object["architectures"] as? [Any] else {
            return false
        }
        return architectures.contains { value in
            guard let architecture = value as? String else { return false }
            let normalized = architecture
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized == "dflashdraftmodel" || normalized == "dflash2draftmodel"
        }
    }

    private func finalizeDownloadedModel(
        _ downloadedDirectoryURL: URL,
        targetDirectoryURL: URL,
        model: DownloadableModelDescriptor
    ) throws -> URL {
        try RecoverableDirectoryInstaller.install(from: downloadedDirectoryURL, to: targetDirectoryURL) { directory in
            guard DownloadableModelCatalog.isCompleteModelDirectory(directory, model: model) else {
                throw ModelDownloadError.incompleteRepository(model.repositoryID)
            }
        }
        return targetDirectoryURL
    }

    func removeTemporaryFiles(
        model: DownloadableModelDescriptor,
        storageDirectoryURL: URL
    ) throws {
        let fileManager = FileManager.default
        let stagingRootURL = storageDirectoryURL
            .standardizedFileURL
            .appendingPathComponent(".mangakitchen-downloads", isDirectory: true)
        let modelRepositoryDirectoryURL = try repositoryDirectoryURL(
            model: model,
            stagingRootURL: stagingRootURL
        )
        var repositoryDirectoryURLs = [modelRepositoryDirectoryURL]
        if let dflashRepositoryID = model.dflashDraft?.repositoryID {
            let dflashRepositoryDirectoryURL = try repositoryDirectoryURL(
                repositoryID: dflashRepositoryID,
                stagingRootURL: stagingRootURL
            )
            if dflashRepositoryDirectoryURL.path != modelRepositoryDirectoryURL.path {
                repositoryDirectoryURLs.append(dflashRepositoryDirectoryURL)
            }
        }

        for repositoryDirectoryURL in repositoryDirectoryURLs {
            if fileManager.fileExists(atPath: repositoryDirectoryURL.path) {
                try fileManager.removeItem(at: repositoryDirectoryURL)
            }
        }
        try removeEmptyDirectories(
            startingAt: modelRepositoryDirectoryURL.deletingLastPathComponent(),
            through: stagingRootURL,
            fileManager: fileManager
        )
    }

    func removeInstalledModel(
        model: DownloadableModelDescriptor,
        storageDirectoryURL: URL
    ) throws {
        let fileManager = FileManager.default
        let storageDirectoryURL = storageDirectoryURL.standardizedFileURL
        let modelDirectoryURL = DownloadableModelCatalog.modelDirectory(
            storageDirectoryURL: storageDirectoryURL,
            model: model
        )
        guard modelDirectoryURL.path.hasPrefix(storageDirectoryURL.path + "/") else {
            throw ModelDownloadError.invalidRepositoryID(model.repositoryID)
        }
        if fileManager.fileExists(atPath: modelDirectoryURL.path) {
            try fileManager.removeItem(at: modelDirectoryURL)
        }
    }

    private func removeEmptyDirectories(
        startingAt directoryURL: URL,
        through rootURL: URL,
        fileManager: FileManager
    ) throws {
        let rootURL = rootURL.standardizedFileURL
        var directoryURL = directoryURL.standardizedFileURL
        while directoryURL.path == rootURL.path
                || directoryURL.path.hasPrefix(rootURL.path + "/") {
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                if directoryURL.path == rootURL.path { break }
                directoryURL = directoryURL.deletingLastPathComponent()
                continue
            }
            let contents = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
            guard contents.isEmpty else { break }
            try fileManager.removeItem(at: directoryURL)
            if directoryURL.path == rootURL.path { break }
            directoryURL = directoryURL.deletingLastPathComponent()
        }
    }

    private func repositoryFiles(
        filenames: [String],
        model: DownloadableModelDescriptor,
        hub: HubApi
    ) async throws -> [RepositoryFile] {
        let requests: [RepositoryFileRequest]
        if model.format == .ggufDirectory {
            guard let weightsFileName = model.weightsFileName,
                  filenames.contains(weightsFileName) else {
                throw ModelDownloadError.incompleteRepository(model.repositoryID)
            }
            var selected = [RepositoryFileRequest(
                repositoryID: model.repositoryID,
                sourceFilename: weightsFileName,
                destinationFilename: weightsFileName
            )]
            if let mmprojFileName = model.mmprojFileName {
                guard filenames.contains(mmprojFileName) else {
                    throw ModelDownloadError.incompleteRepository(model.repositoryID)
                }
                selected.append(RepositoryFileRequest(
                    repositoryID: model.repositoryID,
                    sourceFilename: mmprojFileName,
                    destinationFilename: mmprojFileName
                ))
            }

            if let auxiliaryRepositoryID = model.auxiliaryRepositoryID {
                let auxiliaryRepository = Hub.Repo(id: auxiliaryRepositoryID)
                let auxiliaryFilenames = try await hub.getFilenames(from: auxiliaryRepository)
                for filename in model.auxiliaryFileNames {
                    guard auxiliaryFilenames.contains(filename) else {
                        throw ModelDownloadError.incompleteRepository(auxiliaryRepositoryID)
                    }
                    selected.append(RepositoryFileRequest(
                        repositoryID: auxiliaryRepositoryID,
                        sourceFilename: filename,
                        destinationFilename: filename
                    ))
                }
            } else {
                selected.append(contentsOf: model.auxiliaryFileNames.map {
                    RepositoryFileRequest(
                        repositoryID: model.repositoryID,
                        sourceFilename: $0,
                        destinationFilename: $0
                    )
                })
            }
            requests = selected
        } else {
            requests = filenames.map {
                RepositoryFileRequest(
                    repositoryID: model.repositoryID,
                    sourceFilename: $0,
                    destinationFilename: $0
                )
            }
        }

        var files: [RepositoryFile] = []
        files.reserveCapacity(requests.count)
        var revisions: [String: String] = [:]
        for request in requests {
            try Task.checkCancellation()
            let metadata = try await hub.getFileMetadata(
                url: sourceURL(
                    repositoryID: request.repositoryID,
                    filename: request.sourceFilename,
                    revision: revisions[request.repositoryID] ?? "main"
                )
            )
            let revision = try ModelDownloadValidation.pinnedRevision(metadata.commitHash, previous: revisions[request.repositoryID])
            revisions[request.repositoryID] = revision
            guard let size = metadata.size, size >= 0 else {
                throw ModelDownloadError.incompleteRepository(request.repositoryID)
            }
            files.append(
                RepositoryFile(
                    repositoryID: request.repositoryID,
                    filename: request.sourceFilename,
                    destinationFilename: request.destinationFilename,
                    byteCount: Int64(size),
                    revision: revision
                )
            )
        }
        return files
    }

    private func prepareDownloadedModel(
        _ directoryURL: URL,
        model: DownloadableModelDescriptor
    ) throws {
        if model.format == .ggufDirectory {
            guard let weightsFileName = model.weightsFileName,
                  FileManager.default.fileExists(
                    atPath: directoryURL.appendingPathComponent(weightsFileName).path
                  ) else {
                throw ModelDownloadError.incompleteRepository(model.repositoryID)
            }
            let manifest = ModelManifest(
                id: model.id,
                displayName: model.displayName,
                capability: model.capability,
                backend: .mlxSwift,
                weightsFile: weightsFileName,
                weightsFormat: .gguf,
                mmprojFile: model.mmprojFileName,
                generation: ModelManifest.Generation()
            )
            let manifestURL = directoryURL.appendingPathComponent("mangakitchen-model.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            _ = try ModelManifest.load(from: directoryURL)
            return
        }
        if model.format == .mlxDirectory, model.capability == .superResolution {
            let modelFile = "model.safetensors"
            guard FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent(modelFile).path
            ) else {
                throw ModelDownloadError.incompleteRepository(model.repositoryID)
            }
            let manifest = ModelManifest(
                id: model.id,
                displayName: model.displayName,
                capability: .superResolution,
                backend: .mlxSwift,
                modelFile: modelFile,
                superResolutionScale: model.outputScale
            )
            let manifestURL = directoryURL.appendingPathComponent("mangakitchen-model.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            return
        }
        guard model.format == .coreMLZip || model.format == .coreMLPackage,
              let contract = model.coreMLContract else { return }
        let fileManager = FileManager.default
        var archiveURL: URL?
        var extractionURL: URL?
        let searchRootURL: URL
        if model.format == .coreMLZip {
            let zipFiles = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "zip" }
            guard let selectedArchiveURL = zipFiles.first else {
                throw ModelDownloadError.incompleteRepository(model.repositoryID)
            }
            let selectedExtractionURL = directoryURL
                .appendingPathComponent(".coreml-extracted", isDirectory: true)
            if fileManager.fileExists(atPath: selectedExtractionURL.path) {
                try fileManager.removeItem(at: selectedExtractionURL)
            }
            try fileManager.createDirectory(
                at: selectedExtractionURL,
                withIntermediateDirectories: true
            )
            let result = try ArchiveProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", selectedArchiveURL.path, selectedExtractionURL.path]
            )
            guard result.terminationStatus == 0 else {
                throw ModelDownloadError.archiveExtractionFailed(
                    result.diagnostic.isEmpty ? "無法解壓 Core ML 模型。" : result.diagnostic
                )
            }
            archiveURL = selectedArchiveURL
            extractionURL = selectedExtractionURL
            searchRootURL = selectedExtractionURL
        } else {
            searchRootURL = directoryURL
        }

        let modelFileURL = fileManager.enumerator(
            at: searchRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL }.first {
            $0.lastPathComponent == contract.modelFileName
        }
        guard let modelFileURL else {
            throw ModelDownloadError.incompleteRepository(model.repositoryID)
        }
        let destinationURL: URL
        if model.format == .coreMLZip {
            destinationURL = directoryURL.appendingPathComponent(modelFileURL.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: modelFileURL, to: destinationURL)
        } else {
            destinationURL = modelFileURL
        }
        let modelRelativePath = destinationURL.path == directoryURL.path
            ? destinationURL.lastPathComponent
            : String(destinationURL.path.dropFirst(directoryURL.path.count + 1))
        let manifest: ModelManifest
        switch model.capability {
        case .superResolution:
            manifest = ModelManifest(
                id: model.id,
                displayName: model.displayName,
                capability: .superResolution,
                backend: .coreML,
                modelFile: modelRelativePath,
                inputs: ModelManifest.Inputs(image: contract.inputName),
                outputs: ModelManifest.Outputs(image: contract.outputName),
                superResolutionScale: model.outputScale
            )
        case .imageColorization:
            manifest = ModelManifest(
                id: model.id,
                displayName: model.displayName,
                capability: .imageColorization,
                backend: .coreML,
                modelFile: modelRelativePath,
                inputs: ModelManifest.Inputs(image: contract.inputName),
                outputs: ModelManifest.Outputs(chroma: contract.outputName),
                colorization: ModelManifest.Colorization(
                    kind: .ddcolor,
                    inputSize: model.colorizationInputSize ?? 512
                )
            )
        case .textToText, .imageToText, .imageToImage:
            throw ModelDownloadError.incompleteRepository(model.repositoryID)
        }
        let manifestURL = directoryURL.appendingPathComponent("mangakitchen-model.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        if let archiveURL { try? fileManager.removeItem(at: archiveURL) }
        if let extractionURL { try? fileManager.removeItem(at: extractionURL) }
    }

    private func sourceURL(repositoryID: String, filename: String, revision: String = "main") -> URL {
        let components = repositoryID.split(separator: "/").map(String.init)
            + ["resolve", revision]
            + filename.split(separator: "/").map(String.init)
        return components.reduce(URL(string: "https://huggingface.co")!) { url, component in
            url.appendingPathComponent(component)
        }
    }

    private func repositoryDirectoryURL(
        model: DownloadableModelDescriptor,
        stagingRootURL: URL
    ) throws -> URL {
        try repositoryDirectoryURL(
            repositoryID: model.repositoryID,
            stagingRootURL: stagingRootURL
        )
    }

    private func repositoryDirectoryURL(
        repositoryID: String,
        stagingRootURL: URL
    ) throws -> URL {
        let repositoryComponents = repositoryID
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !repositoryComponents.isEmpty,
              repositoryComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ModelDownloadError.invalidRepositoryID(repositoryID)
        }
        let modelsRootURL = stagingRootURL.appendingPathComponent("models", isDirectory: true)
        let directoryURL = repositoryComponents.reduce(modelsRootURL) { url, component in
            url.appendingPathComponent(component, isDirectory: true)
        }.standardizedFileURL
        guard directoryURL.path.hasPrefix(stagingRootURL.standardizedFileURL.path + "/") else {
            throw ModelDownloadError.invalidRepositoryID(repositoryID)
        }
        return directoryURL
    }

    private func downloadFiles(
        _ files: [RepositoryFile],
        directoryURL: URL,
        progress: ModelDownloadProgressTracker
    ) async throws {
        let fileManager = FileManager.default
        guard Set(files.map(\.destinationFilename)).count == files.count else {
            throw ModelDownloadError.invalidFilename("重複的下載目標")
        }
        // 預先配置的權重檔即使尚未下載，也已具有最終檔案大小。
        // 以標記區分未完成交易，避免 App 中斷後誤認為完整模型。
        let markerURL = directoryURL.appendingPathComponent(Self.inProgressMarker)
        try Data().write(to: markerURL, options: .atomic)
        let partDirectoryURL = directoryURL.appendingPathComponent(".parts", isDirectory: true)
        try fileManager.createDirectory(at: partDirectoryURL, withIntermediateDirectories: true)

        var fileHandles: [String: FileHandle] = [:]
        defer {
            for handle in fileHandles.values { try? handle.close() }
            try? fileManager.removeItem(at: partDirectoryURL)
        }
        for file in files {
            guard file.byteCount >= 0,
                  ![".parts", Self.inProgressMarker].contains(String(file.destinationFilename.split(separator: "/").first ?? "")) else {
                throw ModelDownloadError.invalidFilename(file.destinationFilename)
            }
            let destinationURL = try destinationURL(for: file.destinationFilename, in: directoryURL)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
                throw ModelDownloadError.cannotCreateFile(file.destinationFilename)
            }
            let handle = try FileHandle(forWritingTo: destinationURL)
            try handle.truncate(atOffset: UInt64(file.byteCount))
            fileHandles[file.destinationFilename] = handle
        }

        let segments = files.flatMap(Self.segments(for:))
        try await withThrowingTaskGroup(of: DownloadedSegment.self) { group in
            var iterator = segments.makeIterator()
            let initialTaskCount = min(Self.maximumConcurrentSegments, segments.count)
            for _ in 0..<initialTaskCount {
                guard let segment = iterator.next() else { break }
                addDownloadTask(
                    to: &group,
                    segment: segment,
                    sourceURL: sourceURL(
                        repositoryID: segment.repositoryID,
                        filename: segment.filename,
                        revision: segment.revision
                    ),
                    partDirectoryURL: partDirectoryURL
                )
            }

            while let downloaded = try await group.next() {
                try Task.checkCancellation()
                let data = try Data(contentsOf: downloaded.partURL, options: .mappedIfSafe)
                guard Int64(data.count) == downloaded.segment.byteCount else {
                    throw ModelDownloadError.invalidSegment(
                        downloaded.segment.filename,
                        downloaded.segment.byteCount,
                        Int64(data.count)
                    )
                }
                guard let handle = fileHandles[downloaded.segment.destinationFilename] else {
                    throw ModelDownloadError.cannotCreateFile(downloaded.segment.destinationFilename)
                }
                try handle.seek(toOffset: UInt64(downloaded.segment.startOffset))
                try handle.write(contentsOf: data)
                try fileManager.removeItem(at: downloaded.partURL)
                await progress.advance(
                    fileKey: downloaded.segment.progressKey,
                    byteCount: downloaded.segment.byteCount
                )
                if let segment = iterator.next() {
                    addDownloadTask(
                        to: &group,
                        segment: segment,
                        sourceURL: sourceURL(
                            repositoryID: segment.repositoryID,
                            filename: segment.filename,
                            revision: segment.revision
                        ),
                        partDirectoryURL: partDirectoryURL
                    )
                }
            }
        }

        for handle in fileHandles.values {
            try handle.synchronize()
            try handle.close()
        }
        fileHandles.removeAll()
        try fileManager.removeItem(at: partDirectoryURL)

        for file in files {
            let fileURL = try destinationURL(for: file.destinationFilename, in: directoryURL)
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? -1) == file.byteCount else {
                throw ModelDownloadError.invalidSegment(
                    file.destinationFilename,
                    file.byteCount,
                    Int64(values.fileSize ?? -1)
                )
            }
        }
        try Task.checkCancellation()
        try fileManager.removeItem(at: markerURL)
    }

    static let inProgressMarker = ".mangakitchen-download-in-progress"

    private func destinationURL(for filename: String, in directoryURL: URL) throws -> URL {
        let components = filename.split(separator: "/", omittingEmptySubsequences: true)
        guard !filename.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ModelDownloadError.invalidFilename(filename)
        }
        let fileURL = components.reduce(directoryURL) { url, component in
            url.appendingPathComponent(String(component))
        }.standardizedFileURL
        guard FilePathBoundary.contains(fileURL, in: directoryURL) else {
            throw ModelDownloadError.invalidFilename(filename)
        }
        return fileURL
    }

    private static func segments(for file: RepositoryFile) -> [DownloadSegment] {
        guard file.byteCount > 0 else { return [] }
        guard file.byteCount > segmentByteCount else {
            return [DownloadSegment(
                repositoryID: file.repositoryID,
                filename: file.filename,
                destinationFilename: file.destinationFilename,
                startOffset: 0,
                endOffset: file.byteCount - 1,
                usesRange: false,
                totalByteCount: file.byteCount,
                revision: file.revision
            )]
        }
        var result: [DownloadSegment] = []
        var startOffset: Int64 = 0
        while startOffset < file.byteCount {
            result.append(DownloadSegment(
                repositoryID: file.repositoryID,
                filename: file.filename,
                destinationFilename: file.destinationFilename,
                startOffset: startOffset,
                endOffset: startOffset + min(segmentByteCount, file.byteCount - startOffset) - 1,
                usesRange: true,
                totalByteCount: file.byteCount,
                revision: file.revision
            ))
            startOffset += min(segmentByteCount, file.byteCount - startOffset)
        }
        return result
    }

    private func addDownloadTask(
        to group: inout ThrowingTaskGroup<DownloadedSegment, any Error>,
        segment: DownloadSegment,
        sourceURL: URL,
        partDirectoryURL: URL
    ) {
        group.addTask {
            try await downloadSegment(
                segment,
                sourceURL: sourceURL,
                partDirectoryURL: partDirectoryURL
            )
        }
    }

    private func downloadSegment(
        _ segment: DownloadSegment,
        sourceURL: URL,
        partDirectoryURL: URL
    ) async throws -> DownloadedSegment {
        var latestError: Error?
        for attempt in 1...Self.maximumDownloadAttempts {
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: sourceURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 300
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if segment.usesRange {
                    request.setValue(
                        "bytes=\(segment.startOffset)-\(segment.endOffset)",
                        forHTTPHeaderField: "Range"
                    )
                }
                let (temporaryURL, response) = try await URLSession.shared.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      segment.usesRange ? response.statusCode == 206 : (200...299).contains(response.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw ModelDownloadError.unexpectedHTTPStatus(segment.filename, statusCode)
                }
                guard ModelDownloadValidation.acceptsResponse(
                    statusCode: response.statusCode,
                    contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                    start: segment.startOffset, end: segment.endOffset,
                    total: segment.totalByteCount, usesRange: segment.usesRange
                ) else {
                    throw ModelDownloadError.invalidContentRange(segment.filename)
                }
                let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
                let actualByteCount = Int64(values.fileSize ?? -1)
                guard actualByteCount == segment.byteCount else {
                    throw ModelDownloadError.invalidSegment(
                        segment.filename,
                        segment.byteCount,
                        actualByteCount
                    )
                }
                let partURL = partDirectoryURL
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("part")
                try FileManager.default.moveItem(at: temporaryURL, to: partURL)
                return DownloadedSegment(segment: segment, partURL: partURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                latestError = error
                guard attempt < Self.maximumDownloadAttempts else { break }
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
        throw ModelDownloadError.fileDownloadFailed(
            segment.filename,
            latestError?.localizedDescription ?? "未知錯誤"
        )
    }
}

struct ModelDownloadProgressUpdate: Sendable {
    var fraction: Double
    var downloadedByteCount: Int64
    var totalByteCount: Int64
    var bytesPerSecond: Double?

    static let completed = ModelDownloadProgressUpdate(
        fraction: 1,
        downloadedByteCount: 0,
        totalByteCount: 0,
        bytesPerSecond: nil
    )
}

private struct RepositoryFile: Sendable {
    var repositoryID: String
    var filename: String
    var destinationFilename: String
    var byteCount: Int64
    var revision: String

    var progressKey: String {
        repositoryID + "/" + destinationFilename
    }
}

private struct RepositoryFileRequest: Sendable {
    var repositoryID: String
    var sourceFilename: String
    var destinationFilename: String
}

private struct DownloadSegment: Sendable {
    var repositoryID: String
    var filename: String
    var destinationFilename: String
    var startOffset: Int64
    var endOffset: Int64
    var usesRange: Bool
    var totalByteCount: Int64
    var revision: String

    var byteCount: Int64 { endOffset - startOffset + 1 }

    var progressKey: String {
        repositoryID + "/" + destinationFilename
    }
}

private struct DownloadedSegment: Sendable {
    var segment: DownloadSegment
    var partURL: URL
}

private actor ModelDownloadProgressTracker {
    private struct TransferSample {
        var timestamp: TimeInterval
        var byteCount: Int64
    }

    private let fileByteCounts: [String: Int64]
    private let totalByteCount: Int64
    private let handler: @Sendable (ModelDownloadProgressUpdate) -> Void
    private let startedAt = Date.timeIntervalSinceReferenceDate
    private var downloadedByteCounts: [String: Int64] = [:]
    private var transferSamples: [TransferSample] = []
    private var finished = false

    init(
        files: [RepositoryFile],
        handler: @Sendable @escaping (ModelDownloadProgressUpdate) -> Void
    ) throws {
        let counts = try ModelDownloadValidation.totalByteCount(files.map(\.byteCount))
        // metadata 可能列出重複路徑；不可讓 Dictionary 的 precondition 令 App 崩潰。
        guard Set(files.map(\.progressKey)).count == files.count else {
            throw ModelDownloadError.invalidFilename("重複的下載目標")
        }
        fileByteCounts = Dictionary(uniqueKeysWithValues: files.map {
            ($0.progressKey, $0.byteCount)
        })
        totalByteCount = max(1, counts)
        self.handler = handler
    }

    func report() {
        sendProgress()
    }

    func advance(fileKey: String, byteCount: Int64) {
        let maximum = fileByteCounts[fileKey] ?? byteCount
        downloadedByteCounts[fileKey] = min(
            maximum,
            (downloadedByteCounts[fileKey] ?? 0) + max(byteCount, 0)
        )
        transferSamples.append(TransferSample(
            timestamp: Date.timeIntervalSinceReferenceDate,
            byteCount: max(byteCount, 0)
        ))
        sendProgress()
    }

    func finish() {
        downloadedByteCounts = fileByteCounts
        transferSamples = []
        finished = true
        sendProgress()
    }

    private func sendProgress() {
        let downloadedByteCount = downloadedByteCounts.values.reduce(0, +)
        let now = Date.timeIntervalSinceReferenceDate
        let sampleWindowStart = max(startedAt, now - 2.5)
        transferSamples.removeAll { $0.timestamp < sampleWindowStart }
        let recentByteCount = transferSamples.reduce(Int64(0)) { $0 + $1.byteCount }
        let elapsed = max(now - sampleWindowStart, 0.5)
        let speed = finished || recentByteCount <= 0
            ? nil
            : Double(recentByteCount) / elapsed
        handler(
            ModelDownloadProgressUpdate(
                fraction: finished ? 1 : min(max(Double(downloadedByteCount) / Double(totalByteCount), 0), 1),
                downloadedByteCount: min(downloadedByteCount, totalByteCount),
                totalByteCount: totalByteCount,
                bytesPerSecond: speed
            )
        )
    }
}

private enum ModelDownloadError: LocalizedError, Sendable {
    case emptyRepository(String)
    case incompleteRepository(String)
    case fileDownloadFailed(String, String)
    case invalidRepositoryID(String)
    case invalidFilename(String)
    case cannotCreateFile(String)
    case unexpectedHTTPStatus(String, Int)
    case invalidContentRange(String)
    case invalidSegment(String, Int64, Int64)
    case archiveExtractionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .emptyRepository(repositoryID):
            "模型儲存庫沒有可下載的檔案：\(repositoryID)"
        case let .incompleteRepository(repositoryID):
            "下載的模型資料不完整：\(repositoryID)"
        case let .fileDownloadFailed(filename, reason):
            "模型檔案下載失敗：\(filename)（\(reason)）"
        case let .invalidRepositoryID(repositoryID):
            "不安全的模型儲存庫識別碼：\(repositoryID)"
        case let .invalidFilename(filename):
            "模型儲存庫包含不安全的檔案路徑：\(filename)"
        case let .cannotCreateFile(filename):
            "無法建立模型檔案：\(filename)"
        case let .unexpectedHTTPStatus(filename, statusCode):
            "模型分段下載失敗：\(filename)（HTTP \(statusCode)）"
        case let .invalidContentRange(filename):
            "模型伺服器回傳了錯誤的分段範圍：\(filename)"
        case let .invalidSegment(filename, expected, actual):
            "模型分段大小不符：\(filename)（預期 \(expected) bytes，實際 \(actual) bytes）"
        case let .archiveExtractionFailed(message):
            "Core ML 模型解壓失敗：\(message)"
        }
    }
}
