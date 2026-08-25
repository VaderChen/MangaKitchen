import AppKit

/// 集中管理 Web Bridge 使用的原生檔案／目錄選擇器。
@MainActor
enum WebBridgePanelService {
    static func chooseEntries(
        title: String,
        prompt: String,
        allowsMultipleSelection: Bool,
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        canCreateDirectories: Bool = false
    ) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.canCreateDirectories = canCreateDirectories
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.map(\.standardizedFileURL)
    }

    static func chooseDirectory(
        title: String,
        prompt: String,
        canCreateDirectories: Bool = true
    ) -> URL? {
        chooseEntries(
            title: title,
            prompt: prompt,
            allowsMultipleSelection: false,
            canChooseFiles: false,
            canChooseDirectories: true,
            canCreateDirectories: canCreateDirectories
        )?.first
    }
}
