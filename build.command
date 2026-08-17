#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIRECTORY=${0:A:h}
readonly PROJECT_ROOT="$SCRIPT_DIRECTORY"
readonly PRODUCT_NAME="MangaKitchen"
readonly APP_NAME="${PRODUCT_NAME}.app"
readonly OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-$PROJECT_ROOT/Dist}"
readonly APP_VERSION="$(date '+1.%y%m.%H%M')"
readonly APP_ICON_PATH="$PROJECT_ROOT/Sources/MangaKitchenApp/Resources/AppIcon/MangaKitchen.icns"

configuration="release"
build_worker=false
clean_build=false

print_usage() {
  cat <<'EOF'
用法：./build.command [選項]

選項：
  --release       建立 Release 版本（預設）
  --debug         建立 Debug 版本
  --with-worker   一併編譯 Qwen Image Edit Worker（需要 macOS 26）
  --clean         編譯前清除 Swift Package 建置快取
  -h, --help      顯示說明

環境變數：
  OUTPUT_DIRECTORY  指定 .app 輸出目錄，預設為專案內的 Dist
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --release)
      configuration="release"
      ;;
    --debug)
      configuration="debug"
      ;;
    --with-worker)
      build_worker=true
      ;;
    --clean)
      clean_build=true
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      print -u2 "錯誤：不支援的選項：$1"
      print_usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v swift >/dev/null 2>&1; then
  print -u2 "錯誤：找不到 Swift。請先安裝 Xcode 或 Command Line Tools。"
  exit 1
fi

temporary_app=""

cleanup() {
  if [[ -n "$temporary_app" && -e "$temporary_app" ]]; then
    rm -rf "$temporary_app"
  fi
}

report_failure() {
  local exit_code=$?
  cleanup
  print -u2 ""
  print -u2 "建置失敗（錯誤碼：$exit_code）。"
  if [[ -t 0 ]]; then
    read -r -k 1 "?按任意鍵關閉視窗..."
    print
  fi
  exit "$exit_code"
}

trap report_failure ZERR
trap cleanup EXIT

cd "$PROJECT_ROOT"

if [[ "$clean_build" == true ]]; then
  print "==> 清除主程式建置快取"
  swift package clean --package-path "$PROJECT_ROOT"

  if [[ "$build_worker" == true ]]; then
    print "==> 清除 Worker 建置快取"
    swift package clean \
      --package-path "$PROJECT_ROOT/RuntimeSupport/QwenImageEditWorker"
  fi
fi

print "==> 編譯 $PRODUCT_NAME（$configuration）"
swift build \
  --package-path "$PROJECT_ROOT" \
  --configuration "$configuration" \
  --product "$PRODUCT_NAME"

binary_directory=$(swift build \
  --package-path "$PROJECT_ROOT" \
  --configuration "$configuration" \
  --show-bin-path)
executable_path="$binary_directory/$PRODUCT_NAME"

if [[ ! -x "$executable_path" ]]; then
  print -u2 "錯誤：找不到建置完成的執行檔：$executable_path"
  exit 1
fi

mkdir -p "$OUTPUT_DIRECTORY"
temporary_app="$OUTPUT_DIRECTORY/.${APP_NAME}.tmp.$$"
final_app="$OUTPUT_DIRECTORY/$APP_NAME"

rm -rf "$temporary_app"
mkdir -p \
  "$temporary_app/Contents/MacOS" \
  "$temporary_app/Contents/Resources" \
  "$temporary_app/Contents/Helpers"

ditto "$executable_path" "$temporary_app/Contents/MacOS/$PRODUCT_NAME"
chmod +x "$temporary_app/Contents/MacOS/$PRODUCT_NAME"

for resource_bundle in "$binary_directory"/*.bundle(N); do
  ditto "$resource_bundle" \
    "$temporary_app/Contents/Resources/${resource_bundle:t}"
done

if [[ -d "$PROJECT_ROOT/Samples" ]]; then
  ditto "$PROJECT_ROOT/Samples" "$temporary_app/Contents/Resources/Samples"
fi

if [[ ! -f "$APP_ICON_PATH" ]]; then
  print -u2 "錯誤：找不到 App Icon：$APP_ICON_PATH"
  exit 1
fi
ditto "$APP_ICON_PATH" "$temporary_app/Contents/Resources/MangaKitchen.icns"

cat > "$temporary_app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_TW</string>
  <key>CFBundleDisplayName</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIconFile</key>
  <string>MangaKitchen.icns</string>
  <key>CFBundleIdentifier</key>
  <string>person.vader.mangakitchen</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.graphics-design</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

if [[ "$build_worker" == true ]]; then
  readonly WORKER_PACKAGE="$PROJECT_ROOT/RuntimeSupport/QwenImageEditWorker"
  readonly WORKER_NAME="MangaKitchenQwenImageEditWorker"

  print "==> 編譯 Qwen Image Edit Worker（$configuration）"
  swift build \
    --package-path "$WORKER_PACKAGE" \
    --configuration "$configuration" \
    --product "$WORKER_NAME"

  worker_binary_directory=$(swift build \
    --package-path "$WORKER_PACKAGE" \
    --configuration "$configuration" \
    --show-bin-path)
  worker_path="$worker_binary_directory/$WORKER_NAME"

  if [[ ! -x "$worker_path" ]]; then
    print -u2 "錯誤：找不到建置完成的 Worker：$worker_path"
    exit 1
  fi

  ditto "$worker_path" "$temporary_app/Contents/Helpers/$WORKER_NAME"
  chmod +x "$temporary_app/Contents/Helpers/$WORKER_NAME"
fi

if command -v codesign >/dev/null 2>&1; then
  print "==> 套用本機 Ad Hoc 簽章"
  codesign --force --deep --sign - "$temporary_app"
fi

rm -rf "$final_app"
mv "$temporary_app" "$final_app"
temporary_app=""

print ""
print "建置完成：$final_app"
print "App 版本：$APP_VERSION"
print "可使用以下指令開啟："
print "open ${(q)final_app}"

if [[ -t 0 ]]; then
  print ""
  read -r -k 1 "?按任意鍵關閉視窗..."
  print
fi
