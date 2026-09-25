# 彻底卸载 (app-uninstaller)

macOS 原生卸载工具 v2.0：**SwiftUI 三栏 GUI**（蓝色渐变侧边栏 / 应用列表 / 文件分组勾选），把要卸载的 .app 拖进窗口（或从列表选择）→ 引擎找出全部痕迹 → 勾选 → Remove 连根拔起。残留文件页可扫描已删应用的孤儿文件。零第三方依赖（zsh 引擎 + SwiftUI GUI + Swift 画图标）。

![icon](assets/icon_1024.png)

## 安装 / 构建

```bash
cd ~/Code/app-uninstaller
./build.sh
```

产物：
- **GUI 应用**：`~/Applications/彻底卸载.app`（SwiftUI 原生，可拖到 Dock 常驻）
- **引擎**：`~/bin/app-uninstaller.sh`（GUI 通过它的 `--json` / `--items-file` 接口工作）

只重画图标：`./build.sh icon`（改 `assets/make_icon.swift` 里的配色/符号后跑这个）。

## 用法

**GUI（推荐）**：打开 `彻底卸载.app`，左侧选应用（或把 .app 拖进窗口）→ 右侧分组勾选要删的痕迹 → Remove。文件进废纸篓；系统级项目一次密码。

**残留文件页**：扫描已删除应用留下的孤儿文件，勾选清理。

**命令行**：

```bash
app-uninstaller.sh /Applications/XXX.app            # 列出清单，交互确认
app-uninstaller.sh /Applications/XXX.app --dry-run  # 只扫描列出，不删任何东西
app-uninstaller.sh /Applications/XXX.app --yes      # 免确认直接删
```

每次运行全量日志：`~/Library/Logs/app-uninstaller/YYYYMMDD-HHMMSS.log`。

## 清理范围

应用本体 + 约 30 个位置的残留：`~/Library` 的 Application Support / Caches / Preferences(含 ByHost) / Containers / Group Containers / HTTPStorages / WebKit / Logs / Saved State / LaunchAgents 等；`/Library` 对应位置；家目录 dotfiles；`/private/var/folders` 缓存；Spotlight 按 Bundle ID 全卷索引；驻留进程；launchd 启动项/守护；钥匙串（含 Electron Safe Storage）；pkg 安装收据（lsbom 反查组件包）；`.systemextension` 系统扩展（提权停用）。另提示：Downloads 安装包、BTM 后台项开关（仅提示不删）。

## 安全设计（为什么不会误删）

- 文件**进废纸篓**（可恢复），系统级文件才走一次性密码提权
- 匹配令牌 = 完整 Bundle ID + 名称令牌（≥4 字符、非通用词）；**无厂商首词宽匹配**（不会卸 Teams 误删 Office 共享目录）
- 家目录顶层 / `.config` / Containers / Group Containers / LaunchAgents **只按 Bundle ID 删**；名称撞车只提示（卸 Claude.app 不会碰 `~/.claude`）
- 其他已安装应用（含输入法、系统扩展目录全量枚举）双向保护
- 进程按 PID 精确终止 bundle 内可执行文件；命令行仅引用路径的无关进程只提示
- 公司 IT 组件（Puppet / CorpLink / Defender / DLP / SealSuite / Lark 等）硬保护：拖入拒绝 + 候选过滤
- Apple 系统项永不删除

## 测试

```bash
zsh tests/run_uninstaller_tests.zsh
```

18 项端到端用例：完整卸载、通用名（"Helper"）、glob 字符名（"Foo [Bar]"）、真实 Claude.app 安全边界（dry-run）、厂商名（"Microsoft Foo"）、进程误杀防护。全绿才算完。

## 项目结构

```
Sources/main.swift            # SwiftUI GUI（三栏布局/扫描展示/勾选/执行编排）
bin/app-uninstaller.sh        # 引擎（zsh；--json 扫描 / --items-file 执行 / 经典 CLI）
assets/make_icon.swift        # 图标渲染器（AppKit 绘制）
assets/icon_1024.png / icon.icns
tests/run_uninstaller_tests.zsh
build.sh                      # 一键构建安装（图标+引擎+swiftc+打包）
```

## 已知边界

- `~/Library/Containers` 个别保护壳删不掉（containermanagerd/TCC，需给终端完全磁盘访问权限；无数据残留，可无视）
- 系统扩展停用可能需重启后生效
- BTM「登录项」开关记录无逐项删除接口（macOS 限制），只会提示
- 与目标同 vendor 但**未安装**的撞车目录会进删除名单——确认弹窗逐项可见，取消即可

## 卸载本工具

```bash
rm -rf ~/Applications/彻底卸载.app ~/bin/app-uninstaller.sh ~/Library/Logs/app-uninstaller
```
