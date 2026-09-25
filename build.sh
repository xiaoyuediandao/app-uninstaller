#!/bin/zsh
# 彻底卸载 v2 — 一键构建/安装（SwiftUI 原生应用）
# 用法: ./build.sh        引擎 + Swift 编译 + 打包 + 图标
#       ./build.sh icon   只重新渲染图标
set -e
ROOT="${0:A:h}"
SRC="$ROOT/Sources/main.swift"
ENGINE_SRC="$ROOT/bin/app-uninstaller.sh"
ENGINE_DST="$HOME/bin/app-uninstaller.sh"
APP_DST="${APP_DST:-$HOME/Applications/彻底卸载.app}"
ICON_ICNS="$ROOT/assets/icon.icns"

build_icon() {
  echo "→ 渲染图标与插画…"
  /usr/bin/swift "$ROOT/assets/make_icon.swift" "$ROOT/assets/icon_1024.png"
  [[ -f "$ROOT/assets/make_illustration.swift" ]] && /usr/bin/swift "$ROOT/assets/make_illustration.swift" "$ROOT/assets/illustration.png"
  local iconset="$ROOT/build/icon.iconset"
  /bin/rm -rf "$iconset"; /bin/mkdir -p "$iconset"
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
              "512 icon_512x512" "1024 icon_512x512@2x"; do
    sz=${spec%% *}; fn=${spec##* }
    /usr/bin/sips -z $sz $sz "$ROOT/assets/icon_1024.png" --out "$iconset/$fn.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$iconset" -o "$ICON_ICNS"
}

if [[ "${1:-}" == icon ]]; then build_icon; exit 0; fi
[[ ! -f "$ICON_ICNS" || "$ROOT/assets/make_icon.swift" -nt "$ICON_ICNS" ]] && build_icon

echo "→ 安装引擎…"
/bin/mkdir -p "$HOME/bin"
/bin/cp "$ENGINE_SRC" "$ENGINE_DST"
/bin/chmod +x "$ENGINE_DST"
/bin/zsh -n "$ENGINE_DST"

echo "→ 编译 SwiftUI…"
/usr/bin/swiftc -O -target arm64-apple-macosx14.0 "$SRC" -o "$ROOT/build/彻底卸载" -suppress-warnings

echo "→ 打包 $APP_DST …"
/bin/rm -rf "$APP_DST"
/bin/mkdir -p "$APP_DST/Contents/MacOS" "$APP_DST/Contents/Resources"
/bin/cp "$ROOT/build/彻底卸载" "$APP_DST/Contents/MacOS/彻底卸载"
/bin/cp "$ICON_ICNS" "$APP_DST/Contents/Resources/AppIcon.icns"
[[ -f "$ROOT/assets/illustration.png" ]] && /bin/cp "$ROOT/assets/illustration.png" "$APP_DST/Contents/Resources/illustration.png"
/usr/bin/plutil -create xml1 "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleExecutable string 彻底卸载' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleIdentifier string com.xiaoyuediandao.app-uninstaller' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleName string 彻底卸载' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleDisplayName string 彻底卸载' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundlePackageType string APPL' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleShortVersionString string 2.3.0' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleVersion string 2.3.0' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleIconFile string AppIcon' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add LSMinimumSystemVersion string 14.0' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add NSHighResolutionCapable bool true' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add NSAppleEventsUsageDescription string 需要借助 Finder 将 App 本体移入废纸篓（未授予「App 管理」时的系统级备选通道）。' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleDocumentTypes array' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleDocumentTypes:0 dict' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleDocumentTypes:0:CFBundleTypeName string Application' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleDocumentTypes:0:LSHandlerRank string Alternate' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleDocumentTypes:0:LSItemContentTypes array' "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add CFBundleDocumentTypes:0:LSItemContentTypes:0 string com.apple.application-bundle' "$APP_DST/Contents/Info.plist"
echo "→ 代码签名…"
SIGN_ID="App Uninstaller Dev"
SIGN_PASS='au-dev-cert-2026-xiaoyuediandao'
KC="$HOME/Library/Keychains/au-dev.keychain-db"
if [[ "${CI:-}" == true ]]; then
  KC="$ROOT/build/au-dev.keychain-db"
  /bin/rm -f "$KC"
  /usr/bin/security create-keychain -p ci "$KC" >/dev/null
  /usr/bin/security unlock-keychain -p ci "$KC"
  /usr/bin/security import "$ROOT/assets/dev-cert.p12" -k "$KC" -P "$SIGN_PASS" -A -T /usr/bin/codesign >/dev/null
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ci "$KC" >/dev/null
elif [[ -f "$KC" ]]; then
  /usr/bin/security unlock-keychain -p 'au-dev-kc-2026' "$KC" 2>/dev/null || true
fi
if /usr/bin/codesign --keychain "$KC" --force --timestamp=none --sign "$SIGN_ID" "$APP_DST" 2>/dev/null; then
  echo "  签名身份: $SIGN_ID"
else
  echo "  ⚠️ 找不到签名身份，退回 ad-hoc（TCC 授权将随每次重建失效）"
  /usr/bin/codesign --force --timestamp=none --sign - "$APP_DST"
fi

/usr/bin/touch "$APP_DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DST" 2>/dev/null || true
echo ""
echo "✅ 完成: $APP_DST"
echo "   引擎: $ENGINE_DST   (GUI 依赖它，勿删)"
