#!/bin/zsh
# app-uninstaller — 彻底卸载 macOS 应用：本体 + 残留文件 + 驻留进程 + 启动项 + 钥匙串 + pkg 收据 + 系统扩展
#
# 用法:
#   app-uninstaller.sh /Applications/XXX.app [--yes] [--dry-run]   命令行
#   app-uninstaller.sh --gui /Applications/XXX.app                 由"彻底卸载.app"拖放调用
#
# 安全设计（经 36 个对抗评审 agent 验证后重写）:
#   - 名称令牌 >=4 字符且非通用词；无"首词"宽令牌（防 "microsoft" 灭门共享目录）
#   - 家目录顶层/.config/.cache/.local/share/Containers/Group Containers/LaunchAgents
#     只按完整 Bundle ID 删除；名称命中进 REVIEW 清单（只提示不删，防 Claude.app 误删 ~/.claude）
#   - 其他已安装应用（含输入法/系统扩展目录）的 BID 双向点边界 + 名称边界保护
#   - 进程匹配用全量进程表 + zsh 字面量，排除自身及祖先进程（防 pkill -f 误杀终端）
#   - find 一律 -print0 + zsh 字面量子串过滤（防名称含 [ ] * ? 变成 glob 注入）
#   - 公司 IT 组件（Puppet/CorpLink/Defender/DLP/SealSuite/Lark 等）路径段级保护
set -u
export LC_ALL=en_US.UTF-8

GUI=0; ASSUME_YES=0; DRY_RUN=0; JSON_MODE=0; ITEMS_FILE=""
APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gui) GUI=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    --json) JSON_MODE=1 ;;
    --items-file) ITEMS_FILE="$2"; shift ;;
    --) ;;
    *) APP="$1" ;;
  esac
  shift
done

LOGDIR="$HOME/Library/Logs/app-uninstaller"
/bin/mkdir -p "$LOGDIR"
LOG="$LOGDIR/$(/bin/date +%Y%m%d-%H%M%S).log"

# ---------- 弹窗（环境变量传参，规避 AppleScript 转义问题）----------
# 弹窗图标：直接读拖放壳 bundle 里的 icns 资源，绕开 IconServices 缓存
ICON_FILE="$HOME/Applications/彻底卸载.app/Contents/Resources/droplet.icns"
[[ -r "$ICON_FILE" ]] || ICON_FILE=""

dialog() { # $1=标题 $2=正文 $3=icon(note|stop|caution)
  D_TITLE="$1" D_MSG="$2" D_ICON="$ICON_FILE" /usr/bin/osascript - "$3" >/dev/null 2>&1 <<'AS'
on run argv
  set ic to item 1 of argv
  set t to system attribute "D_TITLE"
  set m to system attribute "D_MSG"
  set ip to system attribute "D_ICON"
  if ip is not "" then
    display dialog m with title t buttons {"好"} default button 1 with icon (POSIX file ip)
  else if ic is "stop" then
    display dialog m with title t buttons {"好"} default button 1 with icon stop
  else if ic is "caution" then
    display dialog m with title t buttons {"好"} default button 1 with icon caution
  else
    display dialog m with title t buttons {"好"} default button 1 with icon note
  end if
end run
AS
}

confirm_dialog() { # $1=正文; 返回 0 = 点了"删除"。默认按钮=取消（防误触）
  D_MSG="$1" D_ICON="$ICON_FILE" /usr/bin/osascript >/dev/null 2>&1 <<'AS'
set m to system attribute "D_MSG"
set ip to system attribute "D_ICON"
if ip is not "" then
  display dialog m with title "彻底卸载" buttons {"取消", "删除"} default button 1 cancel button 1 with icon (POSIX file ip)
else
  display dialog m with title "彻底卸载" buttons {"取消", "删除"} default button 1 cancel button 1 with icon caution
end if
AS
}

die() {
  print -r -- "ERROR: $1" | /usr/bin/tee -a "$LOG"
  if [[ $GUI == 1 ]]; then
    dialog "彻底卸载" "$1" stop
    exit 2   # 已自行弹窗；droplet 对 exit 2 不再追加错误框
  fi
  exit 1
}

# ---------- 校验目标 ----------
[[ -n "$APP" ]] || die "用法: app-uninstaller.sh /路径/XXX.app [--yes] [--dry-run] [--gui]"
APP="${APP%/}"
[[ -d "$APP" && "$APP" == *.app ]] || die "不是一个 .app 应用: $APP"
case "$APP" in /System/*|/Library/System*) die "系统路径，拒绝操作" ;; esac
INFO="$APP/Contents/Info.plist"
[[ -r "$INFO" ]] || die "无法读取: $INFO"

BID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INFO" 2>/dev/null)
[[ -n "$BID" ]] || die "读不到 CFBundleIdentifier"
case "${BID:l}" in
  com.apple.*) die "Apple 系统应用不可卸载" ;;
esac

NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$INFO" 2>/dev/null)
[[ -z "$NAME" ]] && NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$INFO" 2>/dev/null)
[[ -z "$NAME" ]] && NAME="${${APP:t}%.app}"

# 公司 IT 组件与本机守护——禁止作为卸载目标
PROTECT_DROP=(puppet corplink volcengine flinco knightmdm grahamgilbert erikng macjutsu ide_check wdav fresno dlp byteplus sealsuite larksuite arcadepayout-guard)
for kw in "${PROTECT_DROP[@]}"; do
  [[ "${BID:l}" == *"$kw"* || "${NAME:l}" == *"$kw"* ]] && die "这是公司 IT 管理组件 ($NAME)，禁止卸载"
done

# 候选文件路径段级保护（含 com.apple.* 前缀与共享组件）
PROTECT_KEYWORDS=("${PROTECT_DROP[@]}")

# ---------- 匹配令牌（BID 精确 + 名称令牌>=4字符且非通用词；无首词宽令牌）----------
GENERIC=(electron launcher app helper daemon service agent background updater update crash handler framework installer)
TOKENS=("${BID:l}")
for t in "${NAME:l}" "${${NAME// /}:l}"; do
  [[ -z "$t" ]] && continue
  (( ${#t} >= 4 )) || continue
  [[ -n "${GENERIC[(r)$t]:-}" ]] && continue
  [[ -n "${TOKENS[(r)$t]:-}" ]] && continue
  TOKENS+=("$t")
done

# ---------- 其他已安装应用全量枚举（BID 双向点边界 + 名称边界保护）----------
OTHER_BIDS=(); OTHER_NAMES=(); typeset -A _APP_SEEN
_ingest_app() {
  local a="$1" b n
  [[ -d "$a" && "$a" == *.app ]] || return 0
  [[ "$a" == "$APP" ]] && return 0
  [[ -n "${_APP_SEEN[$a]:-}" ]] && return 0
  _APP_SEEN[$a]=1
  b=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$a/Contents/Info.plist" 2>/dev/null) || return 0
  b="${b:l}"; [[ "$b" == com.apple.* ]] && return 0
  OTHER_BIDS+=("$b")
  n=$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$a/Contents/Info.plist" 2>/dev/null)
  [[ -z "$n" ]] && n="${${a:t}%.app}"
  n="${n:l}"
  OTHER_NAMES+=("$n")
  [[ -n "${n// /}" && "${n// /}" != "$n" ]] && OTHER_NAMES+=("${n// /}")
}
while IFS= read -r a; do _ingest_app "$a"; done \
  < <(/usr/bin/mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null)
for d in /Applications "$HOME/Applications" /System/Applications "/Library/Input Methods" /Library/SystemExtensions; do
  [[ -d "$d" ]] || continue
  for a in "$d"/*.app(N) "$d"/*/*.app(N); do _ingest_app "$a"; done
done

# ---------- 目标 app 声明的 Group Containers（entitlements）----------
TARGET_GROUPS=()
while IFS= read -r g; do [[ -n "$g" ]] && TARGET_GROUPS+=("$g"); done \
  < <(/usr/bin/codesign -d --xml --entitlements - "$APP" 2>/dev/null \
      | /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' /dev/stdin 2>/dev/null)
ALL_OTHER_GROUPS=()
if (( ${#TARGET_GROUPS[@]} )); then
  for a in "${(@k)_APP_SEEN}"; do
    while IFS= read -r g; do [[ -n "$g" ]] && ALL_OTHER_GROUPS+=("$g"); done \
      < <(/usr/bin/codesign -d --xml --entitlements - "$a" 2>/dev/null \
          | /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' /dev/stdin 2>/dev/null)
  done
fi

# ---------- 收集框架 ----------
typeset -A SEEN
USER_CAND=(); SYS_CAND=(); REVIEW=()
add_candidate() {
  local p="$1" lb lp ob on seg
  [[ -e "$p" || -L "$p" ]] || return 0
  lb="${${p:t}:l}"; lp="${p:l}"
  [[ "$lb" == com.apple.* || "$lb" == group.com.apple.* ]] && return 0
  for seg in "${(s:/:)lp}"; do
    for kw in "${PROTECT_KEYWORDS[@]}"; do [[ "$seg" == *"$kw"* ]] && return 0; done
  done
  for ob in "${OTHER_BIDS[@]}"; do
    case "$lb" in "$ob"|"$ob".*) return 0 ;; esac   # 其他 app 自身或其子组件
    case "$ob" in "$lb".*) return 0 ;; esac          # 共享父级目录（如 com.microsoft）
  done
  for on in "${OTHER_NAMES[@]}"; do
    [[ "$lb" == "$on" || "$lb" == "$on "* || "$lb" == "$on-"* || "$lb" == "${on}_"* || "$lb" == "$on."* ]] && return 0
  done
  [[ -n "${SEEN[$p]:-}" ]] && return 0
  SEEN[$p]=1
  case "$p" in
    /private/var/folders/*) USER_CAND+=("$p") ;;
    /Library/*|/usr/local/*|/opt/*|/private/*) SYS_CAND+=("$p") ;;
    *) USER_CAND+=("$p") ;;
  esac
}
add_review() { # 名称相近但可能属于其他产品——只提示，永不删除
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  [[ -n "${SEEN[$p]:-}" ]] && return 0
  SEEN[$p]=1
  REVIEW+=("$p")
}

# scan_dir <目录> <name|review|bid>
#   name:   bid 命中→删除候选; 名称命中→删除候选
#   review: bid 命中→删除候选; 名称命中→REVIEW 清单（不删）
#   bid:    仅 bid 命中→删除候选
scan_dir() {
  local d="$1" mode="$2" hit lb t
  [[ -d "$d" ]] || return 0
  while IFS= read -r -d '' hit; do
    lb=${${hit:t}:l}
    if [[ "$lb" == *"${BID:l}"* ]]; then add_candidate "$hit"; continue; fi
    [[ "$mode" == bid ]] && continue
    for t in "${TOKENS[@]}"; do
      [[ "$t" == "${BID:l}" ]] && continue
      if [[ "$lb" == *"$t"* ]]; then
        if [[ "$mode" == name ]]; then add_candidate "$hit"; else add_review "$hit"; fi
        break
      fi
    done
  done < <(/usr/bin/find "$d" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
}

NAME_DIRS=(
  "$HOME/Library/Application Support" "$HOME/Library/Caches" "$HOME/Library/HTTPStorages"
  "$HOME/Library/WebKit" "$HOME/Library/Logs" "$HOME/Library/Logs/DiagnosticReports"
  "$HOME/Library/Saved Application State" "$HOME/Library/Cookies"
  "$HOME/Library/Autosave Information" "$HOME/Library/Preferences" "$HOME/Library/Preferences/ByHost"
  "$HOME/Library/PreferencePanes" "$HOME/Library/Internet Plug-Ins" "$HOME/Library/QuickLook"
  "$HOME/Library/Services" "$HOME/Library/Screen Savers" "$HOME/Library/Fonts"
  /Library/Application\ Support /Library/Caches /Library/Logs/DiagnosticReports
  /Library/PreferencePanes /Library/Internet\ Plug-Ins /Library/QuickLook /Library/Fonts
  /usr/local /opt
)
REVIEW_DIRS=(
  "$HOME/Library/Containers" "$HOME/Library/Group Containers" "$HOME/Library/LaunchAgents"
  "$HOME/Library/Application Scripts" "$HOME/Library/Input Methods"
  /Library/LaunchAgents /Library/LaunchDaemons /Library/PrivilegedHelperTools /Library/Input\ Methods
)
BID_DIRS=( "$HOME" "$HOME/.config" "$HOME/.cache" "$HOME/.local/share" )

if (( JSON_MODE )); then
  {
    print -r -- "=== app-uninstaller $(/bin/date) ==="
    print -r -- "目标: $APP"
    print -r -- "Bundle ID: $BID   名称: $NAME"
    print -r -- "匹配令牌: ${TOKENS[*]}"
  } >> "$LOG"
else
  {
    print -r -- "=== app-uninstaller $(/bin/date) ==="
    print -r -- "目标: $APP"
    print -r -- "Bundle ID: $BID   名称: $NAME"
    print -r -- "匹配令牌: ${TOKENS[*]}"
  } | /usr/bin/tee -a "$LOG"
fi

# 应用本体排第一
USER_CAND+=("$APP"); SEEN[$APP]=1

for d in "${NAME_DIRS[@]}";   do scan_dir "$d" name;   done
for d in "${REVIEW_DIRS[@]}"; do scan_dir "$d" review; done
# 家目录顶层/.config/.cache/.local/share: 仅 BID 删除; 名称命中→REVIEW
for d in "${BID_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  while IFS= read -r -d '' hit; do
    lb=${${hit:t}:l}
    if [[ "$lb" == *"${BID:l}"* ]]; then add_candidate "$hit"; continue; fi
    for t in "${TOKENS[@]}"; do
      [[ "$t" == "${BID:l}" ]] && continue
      [[ "$lb" == *"$t"* ]] && { add_review "$hit"; break; }
    done
  done < <(/usr/bin/find "$d" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
done

# 目标独有的 Group Containers（entitlements 声明且未被其他 app 共享）
for g in "${TARGET_GROUPS[@]}"; do
  shared=0
  for og in "${ALL_OTHER_GROUPS[@]}"; do [[ "$og" == "$g" ]] && { shared=1; break; }; done
  (( shared )) && continue
  add_candidate "$HOME/Library/Group Containers/$g"
done

# per-user 缓存 /private/var/folders（仅精确 bid；含 C/T/X/XPC）
while IFS= read -r hit; do add_candidate "$hit"; done \
  < <(/usr/bin/find /private/var/folders -maxdepth 5 \( -path '*/C/*' -o -path '*/T/*' -o -path '*/X/*' -o -path '*/XPC/*' \) -iname "*${BID}*" 2>/dev/null)

# Spotlight 补充（仅本卷——排除挂载的 DMG 等外卷）
root_dev=$(/usr/bin/stat -f '%d' /)
while IFS= read -r hit; do
  case "$hit" in
    /Library/Developer/*|*/go/pkg/*|*/node_modules/*|*/.git/*|/System/*) continue ;;
  esac
  [[ "$hit" == "$APP" ]] && continue
  [[ $(/usr/bin/stat -f '%d' "${hit%/*}" 2>/dev/null) == "$root_dev" ]] || continue
  add_candidate "$hit"
done < <(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '${BID}'c" 2>/dev/null)

# Downloads 安装包——只提示，不自动删
INSTALLERS=()
while IFS= read -r -d '' hit; do
  lb=${${hit:t}:l}
  for t in "${TOKENS[@]}"; do [[ "$lb" == *"$t"* ]] && { INSTALLERS+=("$hit"); break; }; done
done < <(/usr/bin/find "$HOME/Downloads" -maxdepth 2 \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.zip' \) -print0 2>/dev/null)

# ---------- 驻留进程（全量进程表 + 字面量匹配；排除自身与祖先；KILL/REVIEW 分组）----------
PROC_KILL=(); PROC_KILL_CMD=(); PROC_REVIEW=(); typeset -A PROC_SEEN
build_proc_list() {
  PROC_KILL=(); PROC_KILL_CMD=(); PROC_REVIEW=(); PROC_SEEN=()
  local _ap=$$ pid ppid cmd exe
  local -a ANC; ANC=()
  while (( _ap > 1 )); do
    ANC+=("$_ap")
    _ap=$(/bin/ps -o ppid= -p "$_ap" 2>/dev/null | /usr/bin/tr -d ' ')
    [[ -z "$_ap" ]] && break
  done
  while read -r pid ppid cmd; do
    [[ -z "$pid" ]] && continue
    pid="${pid// /}"
    (( pid == $$ )) && continue
    [[ -n "${ANC[(r)$pid]:-}" ]] && continue
    [[ "$cmd" == *"$APP/"* || "$cmd" == *"$BID"* ]] || continue
    [[ -n "${PROC_SEEN[$pid]:-}" ]] && continue
    PROC_SEEN[$pid]=1
    exe=$(/bin/ps -o comm= -p "$pid" 2>/dev/null)
    if [[ "$exe" == "$APP/"* ]]; then
      PROC_KILL+=("$pid"); PROC_KILL_CMD+=("$pid $cmd")
    else
      PROC_REVIEW+=("$pid $cmd")
    fi
  done < <(/bin/ps -axo pid=,ppid=,command=)
}
build_proc_list

# ---------- 钥匙串（只列 service，绝不读密钥）----------
KC_SERVICES=()
for svc in "$BID" "$NAME" "$NAME Safe Storage"; do
  /usr/bin/security find-generic-password -s "$svc" >/dev/null 2>&1 && KC_SERVICES+=("$svc")
done

# ---------- pkg 收据（bid 直查 + BOM 反查，跳过与其他在装 app 共享的）----------
RECEIPTS=(); typeset -A RSEEN
add_receipt() { [[ -z "${RSEEN[$1]:-}" ]] && { RSEEN[$1]=1; RECEIPTS+=("$1"); } }
APPNAME="${APP:t}"
while IFS= read -r r; do [[ -n "$r" ]] && add_receipt "$r"
done < <(/usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -iF "$BID")
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  case "${r:l}" in
    com.apple.*) continue ;;
  esac
  skip=0
  for kw in "${PROTECT_KEYWORDS[@]}"; do [[ "${r:l}" == *"$kw"* ]] && { skip=1; break; }; done
  (( skip )) && continue
  bom="/var/db/receipts/$r.bom"; [[ -r "$bom" ]] || continue
  hit=0; shared=0
  while IFS= read -r an; do
    [[ -z "$an" ]] && continue
    if [[ "$an" == "$APPNAME" ]]; then hit=1
    elif [[ -d "/Applications/$an" || -d "$HOME/Applications/$an" ]]; then shared=1; fi
  done < <(/usr/bin/lsbom "$bom" 2>/dev/null | /usr/bin/cut -f1 \
    | /usr/bin/sed -E 's#^\./##; s#^Applications/##' \
    | /usr/bin/grep -E '^[^/]+\.app(/|$)' | /usr/bin/sed -E 's#^([^/]+\.app).*#\1#' | /usr/bin/sort -u)
  (( hit && ! shared )) && add_receipt "$r"
done < <(/usr/sbin/pkgutil --pkgs 2>/dev/null)

# ---------- 系统扩展（.systemextension）----------
SYSEX=()
while IFS= read -r ext; do
  xbid=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$ext/Contents/Info.plist" 2>/dev/null) || continue
  [[ -z "$xbid" ]] && continue
  team=$(/usr/bin/codesign -dvvv "$ext" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
  SYSEX+=("${team:-UNKNOWN} $xbid")
done < <(/usr/bin/find "$APP" -type d -name '*.systemextension' 2>/dev/null)
SYSEX_ACTIVE=()
if (( ${#SYSEX[@]} )); then
  syx_list=$(/usr/bin/systemextensionsctl list 2>/dev/null)
  for s in "${SYSEX[@]}"; do
    [[ "$syx_list" == *"${${(z)s}[2]}"* ]] && SYSEX_ACTIVE+=("$s")
  done
fi

# ---------- BTM 后台项快照（只读提示，绝不 resetbtm）----------
# GUI 链路（--json 扫描 / --items-file 执行）下跳过：sfltool 从无授权 app 的进程树调用会弹管理员授权
BTM_ENTRIES=()
if (( ! JSON_MODE )) && [[ -z "$ITEMS_FILE" ]]; then
  while IFS= read -r b; do [[ -n "$b" ]] && BTM_ENTRIES+=("$b")
  done < <(/usr/bin/sfltool dumpbtm 2>/dev/null | /usr/bin/grep -iF "$BID" | /usr/bin/sed 's/^ *//' | /usr/bin/sort -u)
fi

# ---------- --items-file：按 GUI 勾选清单过滤候选并免确认执行 ----------
if [[ -n "$ITEMS_FILE" ]]; then
  [[ -r "$ITEMS_FILE" ]] || die "items-file 不可读: $ITEMS_FILE"
  typeset -A SELP SELPROC SELKC SELRCPT SELSYX
  # `read` 对无换行结尾的末行返回非零——必须 || [[ -n ]] 兜底，否则最后一项永远丢失
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    case "$line" in
      PROC:*)    SELPROC[${line#PROC:}]=1 ;;
      KC:*)      SELKC[${line#KC:}]=1 ;;
      RECEIPT:*) SELRCPT[${line#RECEIPT:}]=1 ;;
      SYSEX:*)   SELSYX[${line#SYSEX:}]=1 ;;
      *)         SELP[$line]=1 ;;
    esac
  done < "$ITEMS_FILE"
  keep=(); for x in "${USER_CAND[@]}"; do [[ -n "${SELP[$x]:-}" ]] && keep+=("$x"); done; USER_CAND=("${keep[@]}")
  keep=(); for x in "${SYS_CAND[@]}";  do [[ -n "${SELP[$x]:-}" ]] && keep+=("$x"); done; SYS_CAND=("${keep[@]}")
  keep=(); i=0
  for pid in "${PROC_KILL[@]}"; do
    i=$(( i + 1 ))
    if [[ -n "${SELPROC[$pid]:-}" ]]; then keep+=("$pid"); fi
  done
  PROC_KILL=("${keep[@]}")
  keep=(); for c in "${PROC_KILL_CMD[@]}"; do pid="${${(z)c}[1]}"; [[ -n "${SELPROC[$pid]:-}" ]] && keep+=("$c"); done; PROC_KILL_CMD=("${keep[@]}")
  keep=(); for x in "${KC_SERVICES[@]}"; do [[ -n "${SELKC[$x]:-}" ]] && keep+=("$x"); done; KC_SERVICES=("${keep[@]}")
  keep=(); for x in "${RECEIPTS[@]}"; do [[ -n "${SELRCPT[$x]:-}" ]] && keep+=("$x"); done; RECEIPTS=("${keep[@]}")
  keep=(); for x in "${SYSEX_ACTIVE[@]}"; do [[ -n "${SELSYX[$x]:-}" ]] && keep+=("$x"); done; SYSEX_ACTIVE=("${keep[@]}")
  ASSUME_YES=1
fi

# ---------- --json：结构化扫描结果（供 GUI 消费），输出后退出 ----------
size_of() { /usr/bin/du -sk "$1" 2>/dev/null | /usr/bin/cut -f1; }
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; print -rn -- "$s"; }
group_of() {
  local p="$1" parent="${p:h}"
  case "$p" in
    "$APP") print -r -- "应用本体"; return ;;
  esac
  case "$parent" in
    "$HOME") print -r -- "家目录顶层" ;;
    "$HOME/Library/Application Support"|/Library/Application\ Support) print -r -- "Application Support" ;;
    "$HOME/Library/Caches"|/Library/Caches) print -r -- "Caches" ;;
    "$HOME/Library/Preferences"|"$HOME/Library/Preferences/ByHost") print -r -- "Preferences" ;;
    "$HOME/Library/Containers") print -r -- "Containers" ;;
    "$HOME/Library/Group Containers") print -r -- "Group Containers" ;;
    "$HOME/Library/LaunchAgents"|/Library/LaunchAgents|/Library/LaunchDaemons) print -r -- "启动项" ;;
    "$HOME/Library/HTTPStorages") print -r -- "HTTPStorages" ;;
    "$HOME/Library/WebKit") print -r -- "WebKit" ;;
    "$HOME/Library/Saved Application State") print -r -- "Saved Application State" ;;
    "$HOME/Library/Logs"|"$HOME/Library/Logs/DiagnosticReports"|/Library/Logs/DiagnosticReports) print -r -- "Logs" ;;
    /private/var/folders/*) print -r -- "Caches" ;;
    /Library/*|/usr/local|/opt) print -r -- "/Library 系统级" ;;
    *) print -r -- "其他" ;;
  esac
}
if (( JSON_MODE )); then
  {
    print -n '{'
    print -n "\"app\":\"$(json_escape "$APP")\",\"bid\":\"$(json_escape "$BID")\",\"name\":\"$(json_escape "$NAME")\","
    print -n '\"items\":['
    first=1; json_total=0
    for p in "${USER_CAND[@]}"; do
      kb=$(size_of "$p"); kb=${kb:-0}; json_total=$(( json_total + kb ))
      (( first )) && first=0 || print -n ','
      print -n "{\"path\":\"$(json_escape "$p")\",\"kb\":$kb,\"kind\":\"user\",\"group\":\"$(json_escape "$(group_of "$p")")\"}"
    done
    for p in "${SYS_CAND[@]}"; do
      kb=$(size_of "$p"); kb=${kb:-0}; json_total=$(( json_total + kb ))
      (( first )) && first=0 || print -n ','
      print -n "{\"path\":\"$(json_escape "$p")\",\"kb\":$kb,\"kind\":\"sys\",\"group\":\"$(json_escape "$(group_of "$p")")\"}"
    done
    print -n '],'
    print -n '\"processes\":['; first=1
    for c in "${PROC_KILL_CMD[@]}"; do
      (( first )) && first=0 || print -n ','
      pid="${${(z)c}[1]}"; rest="${c#* }"
      print -n "{\"pid\":$pid,\"cmd\":\"$(json_escape "$rest")\"}"
    done
    print -n '],'
    print -n '\"proc_review\":['; first=1
    for c in "${PROC_REVIEW[@]}"; do (( first )) && first=0 || print -n ','; print -n "\"$(json_escape "$c")\""; done
    print -n '],'
    print -n '\"receipts\":['; first=1
    for x in "${RECEIPTS[@]}"; do (( first )) && first=0 || print -n ','; print -n "\"$(json_escape "$x")\""; done
    print -n '],'
    print -n '\"keychain\":['; first=1
    for x in "${KC_SERVICES[@]}"; do (( first )) && first=0 || print -n ','; print -n "\"$(json_escape "$x")\""; done
    print -n '],'
    print -n '\"sysex\":['; first=1
    for x in "${SYSEX_ACTIVE[@]}"; do (( first )) && first=0 || print -n ','; print -n "\"$(json_escape "$x")\""; done
    print -n '],'
    print -n '\"btm\":['; first=1
    for x in "${BTM_ENTRIES[@]}"; do (( first )) && first=0 || print -n ','; print -n "\"$(json_escape "$x")\""; done
    print -n '],'
    print -n '\"installers\":['; first=1
    for x in "${INSTALLERS[@]}"; do (( first )) && first=0 || print -n ','; print -n "\"$(json_escape "$x")\""; done
    print -n '],'
    print -n '\"review\":['; first=1
    for x in "${REVIEW[@]}"; do (( first )) && first=0 || print -n ','; print -n "\"$(json_escape "$x")\""; done
    print -n '],'
    print -n '"total_kb":' ; print -n "$json_total"
    print -n ",\"log\":\"$(json_escape "$LOG")\"}"
    print
  }
  exit 0
fi

# ---------- 汇总 ----------
size_of() { /usr/bin/du -sk "$1" 2>/dev/null | /usr/bin/cut -f1; }
total_kb=0; report=""
for p in "${USER_CAND[@]}" "${SYS_CAND[@]}"; do
  kb=$(size_of "$p"); kb=${kb:-0}
  total_kb=$(( total_kb + kb ))
  report+="$(printf '%8.1fM  %s' $(( kb / 1024.0 )) "$p")"$'\n'
done
total_mb=$(printf '%.0f' $(( total_kb / 1024.0 )))
n_items=$(( ${#USER_CAND[@]} + ${#SYS_CAND[@]} ))

{
  print -r -- ""
  print -r -- "== 将删除 $n_items 项 (约 ${total_mb} MB) =="
  print -rn -- "$report"
  (( ${#PROC_KILL[@]} ))    && print -rl -- "== 将终止进程 ${#PROC_KILL[@]} 个 ==" "${PROC_KILL_CMD[@]}"
  (( ${#PROC_REVIEW[@]} ))  && print -rl -- "== 命令行引用了路径/BID 但不属于该 app（不会终止，请自行确认）==" "${PROC_REVIEW[@]}"
  (( ${#RECEIPTS[@]} ))     && print -rl -- "== pkg 收据 ==" "${RECEIPTS[@]}"
  (( ${#KC_SERVICES[@]} ))  && print -rl -- "== 钥匙串条目 ==" "${KC_SERVICES[@]}"
  (( ${#SYSEX[@]} ))        && print -rl -- "== 系统扩展（将请求停用，可能需重启）==" "${SYSEX[@]}"
  (( ${#BTM_ENTRIES[@]} ))  && print -rl -- "== BTM 后台项（删除后开关可能残留在系统设置，无逐项删除接口）==" "${BTM_ENTRIES[@]}"
  (( ${#INSTALLERS[@]} ))   && print -rl -- "== Downloads 安装包（仅提示,不删）==" "${INSTALLERS[@]}"
  (( ${#REVIEW[@]} ))       && print -rl -- "== 名称相近但可能属于其他产品（不删除,需逐项确认）==" "${REVIEW[@]}"
} | /usr/bin/tee -a "$LOG"

if (( DRY_RUN )); then
  print -r -- "[dry-run] 不执行任何删除" | /usr/bin/tee -a "$LOG"
  exit 0
fi

# ---------- 确认（按风险分组；高危组永远逐行可见）----------
HOME_TOP=(); LAUNCH_ITEMS=(); SYS_OTHER=(); LIB_OTHER=()
for p in "${USER_CAND[@]}"; do
  if [[ "$p" == "$APP" ]]; then continue
  elif [[ "${p:h}" == "$HOME" ]]; then HOME_TOP+=("$p")
  else LIB_OTHER+=("$p"); fi
done
for p in "${SYS_CAND[@]}"; do
  case "$p" in */LaunchAgents/*|*/LaunchDaemons/*) LAUNCH_ITEMS+=("$p") ;; *) SYS_OTHER+=("$p") ;; esac
done

confirm_text="即将彻底卸载: $NAME
Bundle ID: $BID

【应用本体】$APP
【~/Library 等残留】${#LIB_OTHER[@]} 项（完整清单见日志）"
(( ${#HOME_TOP[@]} ))    && confirm_text+=$'\n\n'"【家目录顶层——可能含个人数据】"$'\n'"${(F)HOME_TOP}"
(( ${#SYS_OTHER[@]} ))   && confirm_text+=$'\n\n'"【系统级——永久删除不进废纸篓】"$'\n'"${(F)SYS_OTHER}"
(( ${#LAUNCH_ITEMS[@]} )) && confirm_text+=$'\n\n'"【启动项/守护】"$'\n'"${(F)LAUNCH_ITEMS}"
extra=""
(( ${#PROC_KILL[@]} ))   && extra+=$'\n'"终止进程: ${#PROC_KILL[@]} 个"
(( ${#PROC_REVIEW[@]} )) && extra+=$'\n'"命令行引用本 app 的其他进程: ${#PROC_REVIEW[@]} 个（不终止）"
(( ${#RECEIPTS[@]} ))    && extra+=$'\n'"pkg 收据: ${#RECEIPTS[@]} 条"
(( ${#KC_SERVICES[@]} )) && extra+=$'\n'"钥匙串: ${#KC_SERVICES[@]} 条"
(( ${#SYSEX[@]} ))       && extra+=$'\n'"系统扩展: ${#SYSEX[@]} 个（停用可能需重启）"
(( ${#BTM_ENTRIES[@]} )) && extra+=$'\n'"BTM 后台项: ${#BTM_ENTRIES[@]} 条（开关或残留于系统设置）"
(( ${#INSTALLERS[@]} ))  && extra+=$'\n'"Downloads 安装包: ${#INSTALLERS[@]} 个（不自动删）"
(( ${#REVIEW[@]} ))      && extra+=$'\n'"名称相近未删除: ${#REVIEW[@]} 项（见日志）"
[[ -n "$extra" ]] && confirm_text+=$'\n'"$extra"
confirm_text+=$'\n\n'"共 $n_items 项, 约 ${total_mb} MB。日志: $LOG"

if (( GUI )); then
  confirm_dialog "$confirm_text" || { print -r -- "用户取消" | /usr/bin/tee -a "$LOG"; exit 0; }
  # 高危项二次确认（默认按钮=取消）
  if (( ${#HOME_TOP[@]} + ${#SYS_OTHER[@]} + ${#LAUNCH_ITEMS[@]} )); then
    hi_text="以下项目风险较高，再次确认:
"
    (( ${#HOME_TOP[@]} ))    && hi_text+=$'\n'"家目录顶层:"$'\n'"${(F)HOME_TOP}"$'\n'
    (( ${#SYS_OTHER[@]} ))   && hi_text+=$'\n'"系统级(永久删除):"$'\n'"${(F)SYS_OTHER}"$'\n'
    (( ${#LAUNCH_ITEMS[@]} )) && hi_text+=$'\n'"启动项:"$'\n'"${(F)LAUNCH_ITEMS}"
    confirm_dialog "$hi_text" || { print -r -- "用户在二次确认时取消" | /usr/bin/tee -a "$LOG"; exit 0; }
  fi
elif (( ! ASSUME_YES )); then
  print -n "确认删除以上项目? [y/N] "
  ans=""
  if ! read -rk 1 ans 2>/dev/null; then
    print; print -r -- "取消（非交互环境，请加 --yes）"; exit 0
  fi
  print
  [[ "${ans:-}" == [yY] ]] || { print -r -- "取消"; exit 0; }
fi

# ---------- 执行 ----------
UID_NUM=$(/usr/bin/id -u)

# 1) 更新器活动检测：Sparkle/Squirrel(ShipIt) 在优雅退出时会"换包+重启"
updater_active=0
/bin/launchctl print "gui/$UID_NUM/${BID}.ShipIt" >/dev/null 2>&1 && updater_active=1
for c in "${PROC_KILL_CMD[@]}" "${PROC_REVIEW[@]}"; do
  [[ "$c" == *ShipIt* || "$c" == *Autoupdate* ]] && updater_active=1
done
if (( updater_active )); then
  print -r -- "!! 检测到自动更新器活动，跳过优雅退出，先摘除更新器" | /usr/bin/tee -a "$LOG"
  /bin/launchctl bootout "gui/$UID_NUM/${BID}.ShipIt" 2>/dev/null
  /bin/sleep 1
else
  /usr/bin/osascript -e "tell application id \"$BID\" to quit" >/dev/null 2>&1
  /bin/sleep 2
fi

# 2) 仅按 PID 终止 bundle 内进程（绝不 pkill -f，防误杀引用路径的无关终端）
for pid in "${PROC_KILL[@]}"; do /bin/kill -TERM "$pid" 2>/dev/null; done
/bin/sleep 2
for pid in "${PROC_KILL[@]}"; do
  /bin/kill -0 "$pid" 2>/dev/null && /bin/kill -KILL "$pid" 2>/dev/null
done
print -r -- "进程清理完毕（终止 ${#PROC_KILL[@]} 个）" | /usr/bin/tee -a "$LOG"

# 3) 用户 LaunchAgents 按 plist 路径 bootout（Label 与文件名不一致也能命中）
for p in "${USER_CAND[@]}"; do
  [[ "$p" == "$HOME/Library/LaunchAgents/"*.plist ]] && \
    /bin/launchctl bootout "gui/$UID_NUM" "$p" 2>/dev/null
done

# 4) 注销 defaults 域（含 ByHost；防 cfprefsd 复活 plist）
HOST_UUID=$(/usr/sbin/ioreg -d2 -c IOPlatformExpertDevice | /usr/bin/awk -F'"' '/IOPlatformUUID/{print $4}')
for p in "${USER_CAND[@]}"; do
  case "$p" in
    "$HOME/Library/Preferences/ByHost/"*.plist)
      dom="${${p:t}%.plist}"; [[ -n "$HOST_UUID" ]] && dom="${dom%.$HOST_UUID}"
      /usr/bin/defaults -currentHost delete "$dom" >/dev/null 2>&1 ;;
    "$HOME/Library/Preferences/"*.plist)
      /usr/bin/defaults delete "${${p:t}%.plist}" >/dev/null 2>&1 ;;
  esac
done

# 5) 用户级文件进废纸篓（直接 mv 到 ~/.Trash，逐项独立；不依赖 Finder/TCC 授权）
TRASH_DIR="$HOME/.Trash"
trash_failed=()
for p in "${USER_CAND[@]}"; do
  base="${p:t}"
  dst="$TRASH_DIR/$base"
  [[ -e "$dst" || -L "$dst" ]] && dst="$TRASH_DIR/${base}.$(/bin/date +%H%M%S).$$"
  if ! /bin/mv -- "$p" "$dst" 2>/dev/null; then
    trash_failed+=("FAIL $p")
    print -r -- "FAIL $p（mv 进废纸篓失败：被占用/权限不足，详见复查）" | /usr/bin/tee -a "$LOG"
  fi
done
if (( ${#trash_failed[@]} )); then
  print -r -- "用户级文件处理完毕，${#trash_failed[@]} 项未能进废纸篓" | /usr/bin/tee -a "$LOG"
else
  print -r -- "用户级文件已进废纸篓" | /usr/bin/tee -a "$LOG"
fi

# 6) 系统级：一次提权（bootout + rm + pkg 收据 + 系统扩展停用）
if (( ${#SYS_CAND[@]} || ${#RECEIPTS[@]} || ${#SYSEX_ACTIVE[@]} )); then
  elev=$(/usr/bin/mktemp /tmp/app-uninstaller-elev.XXXXXX)
  {
    print -r -- '#!/bin/zsh'
    for p in "${SYS_CAND[@]}"; do
      case "$p" in
        /Library/LaunchDaemons/*.plist) print -r -- "/bin/launchctl bootout system ${(q)p} 2>/dev/null || echo BOOTOUT_FAIL ${(q)p}" ;;
        /Library/LaunchAgents/*.plist)  print -r -- "/bin/launchctl bootout gui/$UID_NUM ${(q)p} 2>/dev/null || echo BOOTOUT_FAIL ${(q)p}" ;;
      esac
      [[ "$p" == /Library/PrivilegedHelperTools/* ]] && \
        print -r -- "/usr/bin/pkill -TERM -f ${(q)p} 2>/dev/null; /bin/sleep 1; /usr/bin/pkill -KILL -f ${(q)p} 2>/dev/null"
      print -r -- "/bin/rm -rf -- ${(q)p}"
    done
    for r in "${RECEIPTS[@]}"; do
      print -r -- "/usr/sbin/pkgutil --forget ${(q)r} 2>/dev/null"
    done
    for s in "${SYSEX_ACTIVE[@]}"; do
      st="${${(z)s}[1]}"; sb="${${(z)s}[2]}"
      [[ "$st" == UNKNOWN || -z "$sb" ]] && continue
      print -r -- "/usr/bin/systemextensionsctl uninstall ${(q)st} ${(q)sb} 2>&1"
    done
    (( ${#SYSEX_ACTIVE[@]} )) && print -r -- "/usr/bin/systemextensionsctl gc 2>&1"
  } > "$elev"
  B64=$(/usr/bin/base64 < "$elev"); /bin/rm -f "$elev"
  elev_out=$(/usr/bin/osascript -e "do shell script \"echo $B64 | /usr/bin/base64 -D | /bin/zsh 2>&1\" with administrator privileges" 2>&1)
  if [[ -n "$elev_out" ]]; then print -r -- "$elev_out" | /usr/bin/tee -a "$LOG"; fi
  if [[ "$elev_out" == *BOOTOUT_FAIL* ]]; then
    print -r -- "!! 有启动项 bootout 失败（见上），文件已删但作业可能仍在运行，建议重启" | /usr/bin/tee -a "$LOG"
  fi
  print -r -- "系统级处理完毕" | /usr/bin/tee -a "$LOG"
fi

# 7) 钥匙串（同 service 循环删到没有为止）
for svc in "${KC_SERVICES[@]}"; do
  [[ -n "$svc" ]] || continue
  deleted=0
  while /usr/bin/security delete-generic-password -s "$svc" >/dev/null 2>&1; do deleted=1; done
  (( deleted )) && print -r -- "钥匙串已删（同 service 全部条目）: $svc" | /usr/bin/tee -a "$LOG"
done

# ---------- 复查（文件 + 进程 + 收据 + 钥匙串 + 系统扩展）----------
left=()
for p in "${USER_CAND[@]}" "${SYS_CAND[@]}"; do [[ -e "$p" || -L "$p" ]] && left+=("[文件] $p"); done
build_proc_list
for c in "${PROC_KILL_CMD[@]}"; do left+=("[驻留进程] $c"); done
while IFS= read -r r; do [[ -n "$r" ]] && left+=("[pkg收据] $r")
done < <(/usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -iF "$BID")
for svc in "${KC_SERVICES[@]}"; do
  /usr/bin/security find-generic-password -s "$svc" >/dev/null 2>&1 && left+=("[钥匙串] $svc")
done
if (( ${#SYSEX[@]} )); then
  syx_after=$(/usr/bin/systemextensionsctl list 2>/dev/null)
  for s in "${SYSEX[@]}"; do
    sb="${${(z)s}[2]}"
    [[ -n "$sb" && "$syx_after" == *"$sb"* ]] && left+=("[系统扩展] $s（可能需重启后移除）")
  done
fi

{
  print -r -- ""
  if (( ${#left[@]} )); then
    print -rl -- "== 未能清除 ${#left[@]} 项 ==" "${left[@]}"
    print -r -- "（Containers 空壳需 完全磁盘访问 授权；bootout 失败或系统扩展停用需重启）"
  else
    print -r -- "== 全部清理完毕，无残留 =="
  fi
} | /usr/bin/tee -a "$LOG"

if (( GUI )); then
  fin="$NAME 卸载完成：$n_items 项（约 ${total_mb} MB）。"
  (( ${#left[@]} )) && fin="$NAME 基本卸载完成，${#left[@]} 项未能清除（详见日志）。"
  (( ${#REVIEW[@]} )) && fin+=$'\n'"另有 ${#REVIEW[@]} 项名称相近的文件未动（可能属于其他产品，见日志）。"
  fin+=$'\n'"日志: $LOG"
  (( ${#left[@]} )) && dialog "彻底卸载" "$fin" caution || dialog "彻底卸载" "$fin"
fi
