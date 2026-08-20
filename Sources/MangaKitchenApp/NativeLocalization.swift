import Foundation

enum NativeLocalization {
    static let supportedLanguageCodes: Set<String> = ["zh-Hant", "en", "ja", "ko"]

    static var automaticLanguageCode: String {
        for candidate in Locale.preferredLanguages {
            let language = candidate.lowercased()
            if language == "zh" || language.hasPrefix("zh-") { return "zh-Hant" }
            if language == "ja" || language.hasPrefix("ja-") { return "ja" }
            if language == "ko" || language.hasPrefix("ko-") { return "ko" }
            if language == "en" || language.hasPrefix("en-") { return "en" }
        }
        return "en"
    }

    static func normalizedLanguageCode(_ value: String?) -> String? {
        guard let value else { return nil }
        return supportedLanguageCodes.first {
            $0.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    static func text(_ key: String, languageCode: String) -> String {
        let language = normalizedLanguageCode(languageCode) ?? automaticLanguageCode
        return translations[language]?[key]
            ?? translations["zh-Hant"]?[key]
            ?? key
    }

    private static let translations: [String: [String: String]] = [
        "zh-Hant": [
            "sourcePanelTitle": "以漫畫來源目錄建立或開啟專案",
            "createProject": "建立專案",
            "additionalPagesPanelTitle": "加入圖片、資料夾、壓縮檔或 PDF",
            "addPages": "加入頁面",
            "outputPanelTitle": "選取翻譯結果輸出目錄",
            "choose": "選取",
            "modelPanelTitle": "選取包含 mangakitchen-model.json 的模型資料夾",
            "dataDirectoryPanelTitle": "選取漫畫廚房資料儲存位置",
            "imageToTextModelPanelTitle": "選取圖生文模型資料夾",
            "imageToTextModelDownloadDirectoryPanelTitle": "選取圖生文模型儲存目錄",
            "superResolutionModelPanelTitle": "選取超解析模型資料夾",
            "superResolutionModelDownloadDirectoryPanelTitle": "選取超解析模型儲存目錄",
            "imageToImageModelPanelTitle": "選取圖生圖模型資料夾",
            "dataDirectoryRestartRequired": "資料儲存位置已更新，重新啟動漫畫廚房後生效。",
            "loadModel": "載入模型",
            "copyEndpoint": "複製 MCP Endpoint",
            "mcpMenuTitle": "漫畫廚房 MCP",
            "openApp": "開啟漫畫廚房",
            "quitApp": "結束漫畫廚房",
            "mcpDisabled": "MCP 未啟用",
            "mcpStarting": "MCP 啟動中…",
            "mcpRunning": "MCP 運作中",
            "mcpStopping": "MCP 正在停止…",
            "mcpFailed": "MCP 啟動失敗：",
            "launchArgumentError": "漫畫廚房啟動參數錯誤",
            "stateSyncFailed": "無法同步應用程式狀態：",
        ],
        "en": [
            "sourcePanelTitle": "Create or open a project from a comic source folder",
            "createProject": "Create Project",
            "additionalPagesPanelTitle": "Add images, folders, archives, or PDFs",
            "addPages": "Add Pages",
            "outputPanelTitle": "Choose a translation output folder",
            "choose": "Choose",
            "modelPanelTitle": "Choose a model folder containing mangakitchen-model.json",
            "dataDirectoryPanelTitle": "Choose the MangaKitchen data folder",
            "imageToTextModelPanelTitle": "Choose an image-to-text model folder",
            "imageToTextModelDownloadDirectoryPanelTitle": "Choose an image-to-text model storage folder",
            "superResolutionModelPanelTitle": "Choose a super-resolution model folder",
            "superResolutionModelDownloadDirectoryPanelTitle": "Choose a super-resolution model storage folder",
            "imageToImageModelPanelTitle": "Choose an image-to-image model folder",
            "dataDirectoryRestartRequired": "The data folder was updated. Restart MangaKitchen to apply it.",
            "loadModel": "Load Model",
            "copyEndpoint": "Copy MCP Endpoint",
            "mcpMenuTitle": "MangaKitchen MCP",
            "openApp": "Open MangaKitchen",
            "quitApp": "Quit MangaKitchen",
            "mcpDisabled": "MCP is disabled",
            "mcpStarting": "Starting MCP…",
            "mcpRunning": "MCP is running",
            "mcpStopping": "Stopping MCP…",
            "mcpFailed": "MCP failed to start: ",
            "launchArgumentError": "Invalid MangaKitchen launch arguments",
            "stateSyncFailed": "Unable to synchronize application state: ",
        ],
        "ja": [
            "sourcePanelTitle": "漫画ソースフォルダからプロジェクトを作成または開く",
            "createProject": "プロジェクトを作成",
            "additionalPagesPanelTitle": "画像、フォルダ、アーカイブ、PDFを追加",
            "addPages": "ページを追加",
            "outputPanelTitle": "翻訳結果の出力フォルダを選択",
            "choose": "選択",
            "modelPanelTitle": "mangakitchen-model.jsonを含むモデルフォルダを選択",
            "dataDirectoryPanelTitle": "漫画キッチンのデータ保存先を選択",
            "imageToTextModelPanelTitle": "画像テキスト化モデルのフォルダを選択",
            "imageToTextModelDownloadDirectoryPanelTitle": "画像テキスト化モデルの保存先を選択",
            "superResolutionModelPanelTitle": "超解像モデルフォルダを選択",
            "superResolutionModelDownloadDirectoryPanelTitle": "超解像モデルの保存先を選択",
            "imageToImageModelPanelTitle": "画像変換モデルのフォルダを選択",
            "dataDirectoryRestartRequired": "データ保存先を更新しました。漫画キッチンを再起動すると反映されます。",
            "loadModel": "モデルを読み込む",
            "copyEndpoint": "MCP Endpointをコピー",
            "mcpMenuTitle": "漫画キッチン MCP",
            "openApp": "漫画キッチンを開く",
            "quitApp": "漫画キッチンを終了",
            "mcpDisabled": "MCPは無効です",
            "mcpStarting": "MCPを起動中…",
            "mcpRunning": "MCPは稼働中です",
            "mcpStopping": "MCPを停止中…",
            "mcpFailed": "MCPの起動に失敗しました：",
            "launchArgumentError": "漫画キッチンの起動引数が不正です",
            "stateSyncFailed": "アプリケーション状態を同期できません：",
        ],
        "ko": [
            "sourcePanelTitle": "만화 원본 폴더에서 프로젝트 만들기 또는 열기",
            "createProject": "프로젝트 만들기",
            "additionalPagesPanelTitle": "이미지, 폴더, 압축 파일 또는 PDF 추가",
            "addPages": "페이지 추가",
            "outputPanelTitle": "번역 결과 출력 폴더 선택",
            "choose": "선택",
            "modelPanelTitle": "mangakitchen-model.json이 포함된 모델 폴더 선택",
            "dataDirectoryPanelTitle": "만화 주방 데이터 저장 위치 선택",
            "imageToTextModelPanelTitle": "이미지→텍스트 모델 폴더 선택",
            "imageToTextModelDownloadDirectoryPanelTitle": "이미지→텍스트 모델 저장 폴더 선택",
            "superResolutionModelPanelTitle": "초해상도 모델 폴더 선택",
            "superResolutionModelDownloadDirectoryPanelTitle": "초해상도 모델 저장 폴더 선택",
            "imageToImageModelPanelTitle": "이미지→이미지 모델 폴더 선택",
            "dataDirectoryRestartRequired": "데이터 저장 위치가 변경되었습니다. 만화 주방을 다시 시작하면 적용됩니다.",
            "loadModel": "모델 불러오기",
            "copyEndpoint": "MCP Endpoint 복사",
            "mcpMenuTitle": "만화 주방 MCP",
            "openApp": "만화 주방 열기",
            "quitApp": "만화 주방 종료",
            "mcpDisabled": "MCP 비활성화됨",
            "mcpStarting": "MCP 시작 중…",
            "mcpRunning": "MCP 실행 중",
            "mcpStopping": "MCP 중지 중…",
            "mcpFailed": "MCP 시작 실패: ",
            "launchArgumentError": "만화 주방 실행 인수가 잘못되었습니다",
            "stateSyncFailed": "애플리케이션 상태를 동기화할 수 없습니다: ",
        ],
    ]
}
