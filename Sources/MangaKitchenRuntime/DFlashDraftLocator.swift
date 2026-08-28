import Foundation
import MLXLLM
import MLXLMCommon
import MangaKitchenCore

enum DFlashDraftLocator {
    static func candidateDirectories(for targetDirectory: URL) -> [URL] {
        let targetDirectory = targetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        var candidates = [URL]()
        var seenPaths = Set<String>()

        func appendIfDraft(_ directoryURL: URL) {
            let directoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
            guard directoryURL != targetDirectory,
                  !seenPaths.contains(directoryURL.path) else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: directoryURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue,
                  isDraftDirectory(directoryURL) else { return }
            seenPaths.insert(directoryURL.path)
            candidates.append(directoryURL)
        }

        let conventionalNames = [
            "DFlashDraftModel",
            "DFlash2DraftModel",
            "dflash-draft",
            "dflash2-draft",
            "draft"
        ]
        for name in conventionalNames {
            appendIfDraft(targetDirectory.appendingPathComponent(name, isDirectory: true))
        }

        let roots = [targetDirectory, targetDirectory.deletingLastPathComponent()]
        for root in roots {
            let entries = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries.sorted(by: { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }) {
                appendIfDraft(entry)
            }
        }
        return candidates
    }

    static func isDraftDirectory(_ directoryURL: URL) -> Bool {
        guard let data = try? Data(
            contentsOf: directoryURL.appendingPathComponent("config.json")
        ),
              let object = try? JSONSerialization.jsonObject(with: data),
              let configuration = object as? [String: Any],
              let architectures = configuration["architectures"] as? [Any] else {
            return false
        }
        return architectures.contains { value in
            guard let architecture = value as? String else { return false }
            let normalized = architecture
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized == "dflashdraftmodel"
                || normalized == "dflash2draftmodel"
        }
    }
}

enum DFlashDraftRuntimeLoader {
    static func loadIfEnabled(
        enabled: Bool,
        targetDirectory: URL,
        targetDisplayName: String,
        container: ModelContainer,
        log: @escaping RuntimeLogHandler
    ) async -> (any DFlashDrafterModel)? {
        guard enabled else { return nil }
        let candidates = DFlashDraftLocator.candidateDirectories(for: targetDirectory)
        guard !candidates.isEmpty else {
            log(
                .warning,
                "DFlash",
                "DFlash is enabled, but no paired Draft directory was found for \(targetDisplayName)."
            )
            return nil
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                let draft = try DFlashModelFactory.load(from: candidate)
                _ = try await container.perform(nonSendable: draft) { context, draft in
                    try draft.validate(target: context.model)
                    return true
                }
                log(
                    .info,
                    "DFlash",
                    "Loaded \(draft.dflashDescriptor.variant.rawValue) Draft \(candidate.lastPathComponent) for \(targetDisplayName), blockSize=\(draft.dflashDescriptor.blockSize)."
                )
                return draft
            } catch {
                lastError = error
            }
        }

        log(
            .warning,
            "DFlash",
            "No compatible paired Draft was found for \(targetDisplayName): \(lastError?.localizedDescription ?? "unknown error")."
        )
        return nil
    }
}
