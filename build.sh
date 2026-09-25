#!/bin/zsh
# 彻底卸载 — 一键构建/安装
# 用法: ./build.sh          构建图标(如有变更) + 编译拖放壳 + 安装引擎
#       ./build.sh icon     只重新渲染图标
set -e
ROOT="${0:A:h}"
SRC_APPLET="$ROOT/src/uninstall-droplet.applescript"
ENGINE_SRC="$ROOT/bin/app-uninstaller.sh"
ENGINE_DST="$HOME/bin/app-uninstaller.sh"
APP_DST="$HOME/Applications/彻底卸载.app"
ICON_ICNS="$ROOT/assets/icon.icns"

build_icon() {
  echo "→ 渲染图标…"
  /usr/bin/swift "$ROOT/assets/make_icon.swift" "$ROOT/assets/icon_1024.png"
  local iconset="$ROOT/build/icon.iconset"
  /bin/rm -rf "$iconset"; /bin/mkdir -p "$iconset"
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
              "512 icon_512x512" "1024 icon_512x512@2x"; do
    sz=${spec%% *}; fn=${spec##* }
    /usr/bin/sips -z $sz $sz "$ROOT/assets/icon_1024.png" --out "$iconset/$fn.png" >/dev/null
  done
  /usr/bin/iconutil -c icns "$iconset" -o "$ICON_ICNS"
  echo "  图标: $ICON_ICNS"
}

if [[ "${1:-}" == icon ]]; then build_icon; exit 0; fi

[[ ! -f "$ICON_ICNS" || "$ROOT/assets/make_icon.swift" -nt "$ICON_ICNS" ]] && build_icon

echo "→ 安装引擎…"
/bin/mkdir -p "$HOME/bin"
/bin/cp "$ENGINE_SRC" "$ENGINE_DST"
/bin/chmod +x "$ENGINE_DST"
/bin/zsh -n "$ENGINE_DST"

echo "→ 编译拖放壳…"
/usr/bin/osacompile -o "$APP_DST" "$SRC_APPLET"
/bin/cp "$ICON_ICNS" "$APP_DST/Contents/Resources/applet.icns"
/bin/cp "$ICON_ICNS" "$APP_DST/Contents/Resources/droplet.icns"  # 本机 osacompile 引用的是 droplet
/usr/bin/touch "$APP_DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DST" 2>/dev/null || true

echo ""
echo "✅ 完成"
echo "   拖放壳: $APP_DST  （拖到 Dock 或访达工具栏可常驻）"
echo "   引擎:   $ENGINE_DST"
echo "   命令行: app-uninstaller.sh /路径/X.app [--dry-run|--yes]"
