#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIRECTORY=${0:A:h}
readonly PROJECT_ROOT="$SCRIPT_DIRECTORY"
readonly PRODUCT_NAME="MangaKitchen"
readonly APP_NAME="${PRODUCT_NAME}.app"
readonly DIST_DIRECTORY="${DIST_DIRECTORY:-$PROJECT_ROOT/Dist}"
readonly APP_PATH="$DIST_DIRECTORY/$APP_NAME"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
readonly STAPLE_MAX_ATTEMPTS="${STAPLE_MAX_ATTEMPTS:-6}"
readonly STAPLE_RETRY_SECONDS="${STAPLE_RETRY_SECONDS:-15}"

skip_build=false
configuration="release"
build_worker=false
clean_build=false
temporary_directory=""

print_usage() {
  cat <<'EOF'
用法：./packDMG.command [選項]

選項：
  --skip-build    使用 Dist 內既有的 MangaKitchen.app
  --release       建立 Release 版本（預設）
  --debug         建立 Debug 版本
  --with-worker   一併編譯 Qwen Image Edit Worker
  --clean         編譯前清除 Swift Package 建置快取
  --notary-profile NAME
                  使用指定的 notarytool Keychain Profile
  --skip-notarization
                  建立並簽署 DMG，但略過 Apple 公證
  -h, --help      顯示說明

環境變數：
  DIST_DIRECTORY       App 與 DMG 輸出目錄，預設為專案內的 Dist
  CODESIGN_IDENTITY     Developer ID Application 簽章身分；未指定時自動偵測
  SKIP_NOTARIZATION     0 公證 App 與 DMG（預設），1 則略過公證
  NOTARYTOOL_PROFILE    notarytool Keychain Profile；未指定時自動偵測
  STAPLE_MAX_ATTEMPTS   公證票據釘選重試次數，預設 6
  STAPLE_RETRY_SECONDS  公證票據釘選重試間隔秒數，預設 15
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --skip-build)
      skip_build=true
      ;;
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
    --notary-profile)
      shift
      if (( $# == 0 )) || [[ -z "$1" ]]; then
        print -u2 "錯誤：--notary-profile 需要 profile 名稱。"
        exit 2
      fi
      NOTARYTOOL_PROFILE="$1"
      ;;
    --notary-profile=*)
      NOTARYTOOL_PROFILE="${1#*=}"
      if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
        print -u2 "錯誤：--notary-profile 需要 profile 名稱。"
        exit 2
      fi
      ;;
    --skip-notarization)
      SKIP_NOTARIZATION=1
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

cleanup() {
  if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
    rm -rf "$temporary_directory"
  fi
}

report_failure() {
  local exit_code=$?
  cleanup
  print -u2 ""
  print -u2 "DMG 建立失敗（錯誤碼：$exit_code）。"
  if [[ -t 0 ]]; then
    read -r -k 1 "?按任意鍵關閉視窗..."
    print
  fi
  exit "$exit_code"
}

staple_with_retry() {
  local target_path="$1"
  local target_name="$2"
  local attempt

  for ((attempt = 1; attempt <= STAPLE_MAX_ATTEMPTS; attempt++)); do
    print "==> 釘選 $target_name 公證票據（$attempt/$STAPLE_MAX_ATTEMPTS）"
    if xcrun stapler staple "$target_path"; then
      xcrun stapler validate "$target_path"
      return 0
    fi
    if (( attempt < STAPLE_MAX_ATTEMPTS )); then
      print "票據尚未就緒，${STAPLE_RETRY_SECONDS} 秒後重試..."
      sleep "$STAPLE_RETRY_SECONDS"
    fi
  done

  print -u2 "$target_name 公證已完成，但票據無法釘選。"
  return 1
}

trap report_failure ZERR
trap cleanup EXIT

for command_name in codesign ditto hdiutil security; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 "錯誤：缺少必要指令：$command_name"
    exit 1
  fi
done

if [[ ! -x /usr/libexec/PlistBuddy ]]; then
  print -u2 "錯誤：找不到 /usr/libexec/PlistBuddy。"
  exit 1
fi

if [[ "$SKIP_NOTARIZATION" != "0" && "$SKIP_NOTARIZATION" != "1" ]]; then
  print -u2 "錯誤：SKIP_NOTARIZATION 只能是 0 或 1。"
  exit 1
fi

if [[ ! "$STAPLE_MAX_ATTEMPTS" =~ '^[1-9][0-9]*$' ]] \
  || [[ ! "$STAPLE_RETRY_SECONDS" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "錯誤：STAPLE_MAX_ATTEMPTS 與 STAPLE_RETRY_SECONDS 必須是正整數。"
  exit 1
fi

available_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(
    print -r -- "$available_identities" \
      | sed -En 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ "(Developer ID Application:.*)"$/\1/p' \
      | head -1
  )"
fi
if [[ -z "$CODESIGN_IDENTITY" ]] \
  || ! print -r -- "$available_identities" \
    | grep -F "$CODESIGN_IDENTITY" \
    | grep -F 'Developer ID Application:' >/dev/null; then
  print -u2 "錯誤：找不到有效的 Developer ID Application 簽章身分。"
  print -u2 "請確認 Developer ID 憑證與私鑰已安裝於 Keychain。"
  exit 1
fi

if [[ "$SKIP_NOTARIZATION" == "0" ]]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    print -u2 "錯誤：找不到 xcrun。"
    exit 1
  fi
  available_notary_profiles="$(
    security dump-keychain 2>/dev/null \
      | sed -En 's/.*"acct"<blob>="com\.apple\.gke\.notary\.tool\.saved-creds\.([^"[:space:]]+)".*/\1/p' \
      | sort -u \
      || true
  )"
  if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
    NOTARYTOOL_PROFILE="$(print -r -- "$available_notary_profiles" | head -1)"
  fi
  if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
    NOTARYTOOL_PROFILE="mangakitchen-notary"
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" >/dev/null 2>&1; then
    print -u2 "錯誤：無法使用 notarytool Keychain Profile：$NOTARYTOOL_PROFILE"
    if [[ -n "$available_notary_profiles" ]]; then
      print -u2 "目前鑰匙圈中的 Profile："
      print -r -- "$available_notary_profiles" | sed 's/^/  - /' >&2
      print -u2 "可用 --notary-profile NAME 指定其他 Profile。"
    else
      print -u2 "請先建立公證憑證："
      print -u2 "  xcrun notarytool store-credentials \"mangakitchen-notary\" --apple-id \"APPLE_ID\" --team-id \"TEAM_ID\""
    fi
    print -u2 "若只建立本機測試 DMG，可使用 --skip-notarization。"
    exit 1
  fi
fi

print "Developer ID Application：$CODESIGN_IDENTITY"
if [[ "$SKIP_NOTARIZATION" == "0" ]]; then
  print "Notary Profile：$NOTARYTOOL_PROFILE"
else
  print "注意：本次略過 Apple 公證。"
fi

cd "$PROJECT_ROOT"
mkdir -p "$DIST_DIRECTORY"

if [[ "$skip_build" == false ]]; then
  build_arguments=("--$configuration")
  [[ "$build_worker" == true ]] && build_arguments+=("--with-worker")
  [[ "$clean_build" == true ]] && build_arguments+=("--clean")
  print "==> 建立 $PRODUCT_NAME.app"
  OUTPUT_DIRECTORY="$DIST_DIRECTORY" \
    "$PROJECT_ROOT/build.command" "${build_arguments[@]}" </dev/null
fi

if [[ ! -d "$APP_PATH" ]]; then
  print -u2 "錯誤：找不到 App：$APP_PATH"
  print -u2 "請先執行 build.command，或移除 --skip-build。"
  exit 1
fi

readonly INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  print -u2 "錯誤：App 缺少 Info.plist：$INFO_PLIST"
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
if [[ -z "$version" || -z "$bundle_id" ]]; then
  print -u2 "錯誤：無法取得 App 版本或 Bundle ID。"
  exit 1
fi

print "==> 使用 Developer ID 簽署 App"
codesign --force --deep --options runtime --timestamp \
  --sign "$CODESIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mangakitchen-dmg.XXXXXX")"
staging_directory="$temporary_directory/staging"
mkdir -p "$staging_directory"

if [[ "$SKIP_NOTARIZATION" == "0" ]]; then
  app_archive="$temporary_directory/$PRODUCT_NAME.zip"
  print "==> 建立 App 公證封裝"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$app_archive"
  print "==> 送交 App 至 Apple Notary Service"
  xcrun notarytool submit "$app_archive" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  staple_with_retry "$APP_PATH" "App"
fi

print "==> 準備 DMG 內容"
ditto --norsrc --noextattr --noqtn "$APP_PATH" "$staging_directory/$APP_NAME"
ln -s /Applications "$staging_directory/Applications"

license_directory="$staging_directory/Licenses"
mkdir -p "$license_directory"
for license_file in LICENSE COMMERCIAL-LICENSE.md; do
  if [[ -f "$PROJECT_ROOT/$license_file" ]]; then
    ditto "$PROJECT_ROOT/$license_file" "$license_directory/$license_file"
  fi
done

dmg_path="$DIST_DIRECTORY/$PRODUCT_NAME-$version.dmg"
volume_name="$PRODUCT_NAME $version"
if [[ -e "$dmg_path" ]]; then
  rm -f "$dmg_path"
fi

print "==> 建立 DMG：$dmg_path"
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_directory" \
  -ov \
  -format UDZO \
  "$dmg_path"

print "==> 使用 Developer ID 簽署 DMG"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$dmg_path"
codesign --verify --strict --verbose=2 "$dmg_path"

if [[ "$SKIP_NOTARIZATION" == "0" ]]; then
  print "==> 送交 DMG 至 Apple Notary Service"
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  staple_with_retry "$dmg_path" "DMG"
fi

print ""
print "DMG 建立完成：$dmg_path"
print "App 版本：$version"
print "Bundle ID：$bundle_id"
if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
  print "注意：目前略過 Apple 公證；正式發布時請設定 Developer ID 與公證參數。"
fi

if [[ -t 0 ]]; then
  print ""
  read -r -k 1 "?按任意鍵關閉視窗..."
  print
fi
