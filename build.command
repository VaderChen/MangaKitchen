#!/bin/zsh

set -euo pipefail
export COPYFILE_DISABLE=1

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
staging_root=""

cleanup() {
  if [[ -n "$staging_root" && -e "$staging_root" ]]; then
    rm -rf "$staging_root"
  elif [[ -n "$temporary_app" && -e "$temporary_app" ]]; then
    rm -rf "$temporary_app"
  fi
}

publish_app_bundle() {
  local previous_app="$OUTPUT_DIRECTORY/.${APP_NAME}.previous.$$"
  local running_pids=""

  running_pids="$(/usr/bin/pgrep -x "$PRODUCT_NAME" 2>/dev/null || true)"
  if [[ -n "$running_pids" ]]; then
    print -u2 "錯誤：偵測到仍在執行的 $PRODUCT_NAME（PID：${running_pids//$'\n'/, }）。"
    print -u2 "請先結束舊版 App 再重新建置。"
    return 1
  fi

  rm -rf "$previous_app"
  if [[ -e "$final_app" ]]; then
    mv "$final_app" "$previous_app"
  fi
  if mv "$temporary_app" "$final_app"; then
    temporary_app=""
    rm -rf "$previous_app"
    return 0
  fi
  if [[ -e "$previous_app" ]]; then
    mv "$previous_app" "$final_app"
  fi
  print -u2 "錯誤：無法將完成的 App 發佈至：$final_app"
  return 1
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

mlx_metallib_path=""

prepare_mlx_metallib() {
  local mlx_generated_root="$PROJECT_ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated"
  local shader_root="$mlx_generated_root/metal"
  local cache_directory="$PROJECT_ROOT/.build/mangakitchen-metal/$configuration"
  local output_path="$cache_directory/mlx.metallib"
  local rebuild=false
  local shader_source
  local relative_path
  local air_name
  local air_path
  local -a shader_sources
  local -a air_files

  if [[ ! -d "$shader_root" ]]; then
    print -u2 "錯誤：找不到 MLX Metal shader 原始碼：$shader_root"
    exit 1
  fi
  shader_sources=("$shader_root"/**/*.metal(N))
  if (( ${#shader_sources} == 0 )); then
    print -u2 "錯誤：MLX 不含可編譯的 Metal shader。"
    exit 1
  fi

  if [[ ! -f "$output_path" ]]; then
    rebuild=true
  else
    for shader_source in "${shader_sources[@]}"; do
      if [[ "$shader_source" -nt "$output_path" ]]; then
        rebuild=true
        break
      fi
    done
  fi

  if [[ "$rebuild" == true ]]; then
    if ! command -v xcrun >/dev/null 2>&1 \
        || ! xcrun -f metal >/dev/null 2>&1 \
        || ! xcrun -f metallib >/dev/null 2>&1; then
      print -u2 "錯誤：找不到 Xcode Metal 編譯工具，無法建立 MLX shader。"
      exit 1
    fi

    print "==> 編譯 MLX Metal shader"
    rm -rf "$cache_directory"
    mkdir -p "$cache_directory"
    for shader_source in "${shader_sources[@]}"; do
      relative_path="${shader_source#$mlx_generated_root/}"
      air_name="${relative_path//\//_}"
      air_name="${air_name:r}.air"
      air_path="$cache_directory/$air_name"
      xcrun -sdk macosx metal \
        -x metal \
        -Wall \
        -Wextra \
        -fno-fast-math \
        -Wno-c++17-extensions \
        -Wno-c++20-extensions \
        -mmacosx-version-min=14.0 \
        -I"$mlx_generated_root" \
        -c "$shader_source" \
        -o "$air_path"
      air_files+=("$air_path")
    done
    xcrun -sdk macosx metallib "${air_files[@]}" -o "$output_path"
  fi

  mlx_metallib_path="$output_path"
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

prepare_mlx_metallib

mkdir -p "$OUTPUT_DIRECTORY"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/mangakitchen-app.XXXXXX")"
temporary_app="$staging_root/$APP_NAME"
final_app="$OUTPUT_DIRECTORY/$APP_NAME"

mkdir -p \
  "$temporary_app/Contents/MacOS" \
  "$temporary_app/Contents/Resources" \
  "$temporary_app/Contents/Helpers"

/bin/cp "$executable_path" "$temporary_app/Contents/MacOS/$PRODUCT_NAME"
chmod +x "$temporary_app/Contents/MacOS/$PRODUCT_NAME"
/bin/cp "$mlx_metallib_path" "$temporary_app/Contents/MacOS/mlx.metallib"

for resource_bundle in "$binary_directory"/*.bundle(N); do
  ditto --norsrc --noqtn "$resource_bundle" \
    "$temporary_app/Contents/Resources/${resource_bundle:t}"
done

if [[ -d "$PROJECT_ROOT/Samples" ]]; then
  ditto --norsrc --noqtn \
    "$PROJECT_ROOT/Samples" \
    "$temporary_app/Contents/Resources/Samples"
fi

if [[ ! -f "$APP_ICON_PATH" ]]; then
  print -u2 "錯誤：找不到 App Icon：$APP_ICON_PATH"
  exit 1
fi
ditto --norsrc --noqtn \
  "$APP_ICON_PATH" \
  "$temporary_app/Contents/Resources/MangaKitchen.icns"

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

  /bin/cp "$worker_path" "$temporary_app/Contents/Helpers/$WORKER_NAME"
  chmod +x "$temporary_app/Contents/Helpers/$WORKER_NAME"
fi

# 簽章前在 APFS 暫存區清掉從外接磁碟複製進來的舊 AppleDouble。
find "$temporary_app" -type f -name '._*' -delete

if command -v codesign >/dev/null 2>&1; then
  print "==> 套用本機 Ad Hoc 簽章"
  codesign --force --sign - "$temporary_app/Contents/MacOS/mlx.metallib"
  codesign --force --deep --sign - "$temporary_app"
  codesign --verify --deep --strict "$temporary_app"
fi

publish_app_bundle

if command -v codesign >/dev/null 2>&1; then
  # 外接磁碟會將 metallib 的簽章 extended attributes 保存成 `._*`
  # AppleDouble 檔案；這些檔案不可刪除。
  codesign --verify --deep --strict "$final_app"
fi

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
