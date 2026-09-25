#!/bin/zsh
set -u
# 被测引擎路径，默认安装位置；可用参数覆盖: zsh run_uninstaller_tests.zsh /path/to/app-uninstaller.sh
ENGINE="${1:-$HOME/bin/app-uninstaller.sh}"
R=/tmp/uninstaller-test
/bin/rm -rf "$R"; mkdir -p "$R"

mkapp() {
  mkdir -p "$1/Contents/MacOS"
  cat > "$1/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleName</key><string>$3</string>
</dict></plist>
P
}
mkapp "$R/FakeTest.app" com.test.fakeapp FakeTest
mkapp "$R/Foo [Bar].app" com.test.foobar "Foo [Bar]"
mkapp "$R/Helper.app" com.testvendor.helper Helper
mkapp "$R/Microsoft Foo.app" com.mstest.foo "Microsoft Foo"
mkapp "$HOME/Applications/FakeTestOtherProduct.app" com.other.fakeproduct "FakeTestOtherProduct"

# 残留
mkdir -p ~/Library/Application\ Support/FakeTest ~/Library/Caches/com.test.fakeapp ~/Library/Containers/com.test.fakeapp "$HOME/Library/Application Support/Foo [Bar] Data" ~/.faketest
echo x > ~/Library/Preferences/com.test.fakeapp.plist
echo x > ~/Library/Application\ Support/FakeTest/data.db
# 诱饵（必须存活）
mkdir -p ~/Library/Application\ Support/FakeTestOtherProduct ~/.faketest-other
echo x > ~/Library/Application\ Support/FakeTestOtherProduct/keep.me

# 假可执行文件（真实二进制，路径在 bundle 内）
printf '#include <unistd.h>\nint main(){for(;;)pause();return 0;}\n' > /tmp/faketest.c
/usr/bin/clang /tmp/faketest.c -o "$R/FakeTest.app/Contents/MacOS/FakeTest" || { echo "CLANG FAIL"; exit 1; }
"$R/FakeTest.app/Contents/MacOS/FakeTest" & FAKE_PID=$!
/bin/bash -c 'exec -a "/usr/bin/tail -f com.test.fakeapp" sleep 3600' & DECOY_PID=$!
sleep 1
/bin/kill -0 $FAKE_PID 2>/dev/null && echo "fake exe alive ($FAKE_PID)" || { echo "FAKE EXE DIED"; exit 1; }
/bin/kill -0 $DECOY_PID 2>/dev/null && echo "decoy alive ($DECOY_PID): $(/bin/ps -o comm= -p $DECOY_PID)" || { echo "DECOY DIED AT LAUNCH"; exit 1; }

pass=0; fail=0
check() { if [[ "$2" == 0 ]]; then pass=$((pass+1)); print -r -- "PASS: $1"; else fail=$((fail+1)); print -r -- "FAIL: $1"; fi }

echo "===== T1: FakeTest 完整卸载 ====="
OUT=$(/bin/zsh "$ENGINE" --yes "$R/FakeTest.app" 2>&1)
[[ ! -e "$R/FakeTest.app" ]]; check "T1.1 app 本体已删" $?
[[ ! -e ~/Library/Application\ Support/FakeTest ]]; check "T1.2 Application Support 已删" $?
[[ ! -e ~/Library/Caches/com.test.fakeapp ]]; check "T1.3 Caches 已删" $?
[[ ! -e ~/Library/Preferences/com.test.fakeapp.plist ]]; check "T1.4 Preferences 已删" $?
[[ ! -e ~/Library/Containers/com.test.fakeapp || -z "$(/bin/ls -A ~/Library/Containers/com.test.fakeapp 2>/dev/null | /usr/bin/grep -v metadata)" ]]; check "T1.5 Container 已删/仅剩保护壳" $?
[[ -d ~/.faketest ]]; check "T1.6 家目录名称命中进 REVIEW 未删" $?
[[ -e ~/Library/Application\ Support/FakeTestOtherProduct/keep.me ]]; check "T1.7 诱饵 AppSupport 存活" $?
[[ -d ~/.faketest-other ]]; check "T1.8 诱饵 dotdir 存活" $?
/bin/kill -0 $FAKE_PID 2>/dev/null; [[ $? != 0 ]]; check "T1.9 bundle 内进程被终止" $?
echo "decoy pre-check: $(/bin/ps -p $DECOY_PID -o pid=,stat=,comm= 2>&1 || echo GONE)"
/bin/kill -0 $DECOY_PID 2>/dev/null; check "T1.10 诱饵进程（仅命令行含 BID）存活" $?
[[ "$OUT" == *名称相近* && "$OUT" == *faketest* ]]; check "T1.11 REVIEW 清单列出名称命中" $?

echo "===== T2: Helper 通用名（dry-run） ====="
OUT2=$(/bin/zsh "$ENGINE" --dry-run "$R/Helper.app" 2>&1)
[[ "$OUT2" == *"com.testvendor.helper"* ]]; check "T2.1 bid 令牌生效" $?
[[ "$OUT2" != *Microsoft* && "$OUT2" != *Defender* && "$OUT2" != *SentinelOne* ]]; check "T2.2 零跨厂商误配（微软/Defender/SentinelOne）" $?

echo "===== T3: Foo [Bar] glob 字符名（dry-run） ====="
OUT3=$(/bin/zsh "$ENGINE" --dry-run "$R/Foo [Bar].app" 2>&1)
[[ "$OUT3" == *"Foo [Bar] Data"* ]]; check "T3.1 含方括号名称的残留被字面匹配找到" $?

echo "===== T4: Claude.app 安全边界（dry-run，只读） ====="
OUT4=$(/bin/zsh "$ENGINE" --dry-run /Applications/Claude.app 2>&1)
pre="${OUT4%%*名称相近*}"
[[ "$pre" != *"/.claude"* ]]; check "T4.1 删除清单不含 ~/.claude 系列" $?
[[ "$OUT4" == *名称相近* && "${OUT4#*名称相近}" == *"/.claude"* ]]; check "T4.2 ~/.claude 系列出现在 REVIEW 提示" $?
[[ ! -e ~/Library/Preferences/com.anthropic.claudefordesktop.plist.bak ]]; check "T4.3 dry-run 无副作用（抽查）" $?

echo "===== T6: Microsoft Foo 厂商名（dry-run） ====="
OUT6=$(/bin/zsh "$ENGINE" --dry-run "$R/Microsoft Foo.app" 2>&1)
[[ "$OUT6" != *"Application Support/Microsoft"* && "$OUT6" != *"com.microsoft."* ]]; check "T6.1 不触碰 Office 共享目录/com.microsoft.*" $?

echo "===== T7: items-file 无换行末行（回归：read 丢末项） ====="
mkapp "$R/T7App.app" com.test.t7app T7App
mkdir -p ~/Library/Caches/com.test.t7app.a ~/Library/Caches/com.test.t7app.b
echo x > ~/Library/Caches/com.test.t7app.a/x
echo x > ~/Library/Caches/com.test.t7app.b/x
printf '%s\n%s' "$HOME/Library/Caches/com.test.t7app.a" "$HOME/Library/Caches/com.test.t7app.b" > "$R/t7-plan.txt"
/bin/zsh "$ENGINE" --items-file "$R/t7-plan.txt" "$R/T7App.app" >/dev/null 2>&1
[[ ! -e ~/Library/Caches/com.test.t7app.a ]]; check "T7.1 items-file 首项已删" $?
[[ ! -e ~/Library/Caches/com.test.t7app.b ]]; check "T7.2 无换行末项也已删（GUI 拼接无尾换行）" $?

echo ""
echo "===== 结果: $pass PASS / $fail FAIL ====="

# 清理测试现场
/bin/kill $DECOY_PID 2>/dev/null
/bin/rm -rf "$R" ~/.faketest ~/.faketest-other ~/Library/Application\ Support/FakeTestOtherProduct ~/Library/Containers/com.test.fakeapp "$HOME/Applications/FakeTestOtherProduct.app" /tmp/faketest.c ~/Library/Caches/com.test.t7app.a ~/Library/Caches/com.test.t7app.b
exit $(( fail > 0 ))
