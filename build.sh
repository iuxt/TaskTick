#!/bin/bash
# Build, install and launch TaskTick on this Mac: ./build.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TaskTick"
INSTALL_ROOT="/Applications"
INSTALL_PATH="${INSTALL_ROOT}/${APP_NAME}.app"
BUILD_DIR=""
INSTALL_STAGE=""
USE_SUDO=false
ORIGINAL_TMPDIR="${TMPDIR:-/tmp}"

fail() {
  echo "错误：$*" >&2
  exit 1
}

install_command() {
  if [ "$USE_SUDO" = true ]; then
    sudo "$@"
  else
    "$@"
  fi
}

cleanup() {
  export TMPDIR="$ORIGINAL_TMPDIR"
  if [ -n "$INSTALL_STAGE" ]; then
    # Restore the previous app if moving the new bundle into place failed.
    if [ -d "$INSTALL_STAGE/Previous.app" ] && [ ! -e "$INSTALL_PATH" ]; then
      install_command mv "$INSTALL_STAGE/Previous.app" "$INSTALL_PATH"
    fi
    install_command rm -rf "$INSTALL_STAGE"
  fi
  if [ -n "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"
  fi
}
trap 'exit_status=$?; cleanup; exit "$exit_status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(uname -s)" = Darwin ] || fail "请在 macOS 上运行此脚本。"
command -v swift >/dev/null 2>&1 || fail "请先安装 Xcode 或 Xcode Command Line Tools。"
BUILD_DIR="$(mktemp -d "${ORIGINAL_TMPDIR%/}/TaskTick-build.XXXXXX")"
mkdir -p "$BUILD_DIR/tmp"
# SwiftPM also writes locks and compiler scratch files under TMPDIR.
# Keep those inside our build directory so cleanup removes them as well.
export TMPDIR="$BUILD_DIR/tmp/"
xcrun --find swift >/dev/null 2>&1 || fail "找不到 Swift 工具链，请检查 xcode-select 设置。"
if [ ! -w "$INSTALL_ROOT" ]; then
  echo "安装到 $INSTALL_ROOT 需要管理员权限。"
  sudo -v
  USE_SUDO=true
fi

echo "退出 TaskTick…"
# SIGTERM uses AppDelegate.gracefulShutdown(), including child-process cleanup
# and a final database save. The separate TaskTick Dev app stays independent.
for process_name in TaskTick TaskTickApp; do
  if pgrep -x "$process_name" >/dev/null; then
    pkill -TERM -x "$process_name" || true
    attempts=0
    while pgrep -x "$process_name" >/dev/null; do
      attempts=$((attempts + 1))
      [ "$attempts" -lt 150 ] || fail "$process_name 未能在 15 秒内退出，请退出应用后重试。"
      sleep 0.1
    done
  fi
done

APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
echo "构建 Release 版本…"
swift build --package-path "$PROJECT_ROOT" --configuration release \
  --build-path "$BUILD_DIR/build" --product TaskTickApp
BIN_DIR="$(swift build --package-path "$PROJECT_ROOT" --configuration release \
  --build-path "$BUILD_DIR/build" --show-bin-path)"
[ -x "$BIN_DIR/TaskTickApp" ] || fail "找不到构建产物：$BIN_DIR/TaskTickApp"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/TaskTickApp" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Package every resource bundle, including localization, in the signed app.
while IFS= read -r -d '' bundle; do
  cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done < <(find "$BIN_DIR" -maxdepth 1 -type d -name '*.bundle' -print0)
cp "$PROJECT_ROOT/Sources/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

VERSION="$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
VERSION="${VERSION#v}"
VERSION="${VERSION:-0.0.0}"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.iuxt.TaskTick</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "安装到 ${INSTALL_PATH}…"
# Stage on the destination filesystem so the final move is a rename. Keep the
# existing app until the new bundle has been copied and verified successfully.
INSTALL_STAGE="$(install_command mktemp -d "$INSTALL_ROOT/.TaskTick-install.XXXXXX")"
install_command chmod 755 "$INSTALL_STAGE"
install_command ditto "$APP_BUNDLE" "$INSTALL_STAGE/$APP_NAME.app"
codesign --verify --deep --strict "$INSTALL_STAGE/$APP_NAME.app"
if [ -e "$INSTALL_PATH" ]; then
  install_command mv "$INSTALL_PATH" "$INSTALL_STAGE/Previous.app"
fi
install_command mv "$INSTALL_STAGE/$APP_NAME.app" "$INSTALL_PATH"

echo "清理临时文件…"
cleanup
INSTALL_STAGE=""
BUILD_DIR=""
trap - EXIT

echo "启动 TaskTick…"
open "$INSTALL_PATH"
echo "完成：$INSTALL_PATH"
