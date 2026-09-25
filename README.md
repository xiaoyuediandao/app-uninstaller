# 彻底卸载 (app-uninstaller)

# 彻底卸载 (app-uninstaller)

[![release](https://img.shields.io/github/v/release/xiaoyuediandao/app-uninstaller)](https://github.com/xiaoyuediandao/app-uninstaller/releases)
[![CI](https://github.com/xiaoyuediandao/app-uninstaller/actions/workflows/release.yml/badge.svg)](https://github.com/xiaoyuediandao/app-uninstaller/actions/workflows/release.yml)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

macOS 原生卸载与系统清理工具：**SwiftUI 三栏 GUI**。四大能力：
- **应用程序**：拖入 .app（或列表选择）→ 引擎找出全部痕迹 → 勾选 → 连根拔起
- **残留文件**：扫描已删应用的孤儿文件（高置信度规则，默认不勾选）
- **系统清理**（v2.4）：CPU/内存/磁盘一键体检——异常进程（持续高 CPU / 高内存 / 僵尸 / 卡死 / 孤儿）+ 磁盘赘肉（应用缓存 / 日志 / 开发缓存 / 废纸篓 / 大文件）→ 确认后一键清理恢复最佳状态
- 内置 **OTA 升级**（GitHub Releases，参考 AgenticGo 方式）与 **CI/CD**（tag 触发自动构建发布）

零第三方依赖（zsh 引擎 + SwiftUI GUI + Swift 画图标/插画）。

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

## OTA 升级与 CI/CD

- **应用内 OTA**：点左下角版本号 → 检查更新。查询 `releases/latest`，发现新版本一键下载 zip、替换本地 app、去隔离、自动重启（与 AgenticGo 同机制）。
- **固定签名**：构建产物用仓库内自签名 dev 证书（`assets/dev-cert.p12`）签名 + 固定 Bundle ID，保证 TCC 授权（App 管理 / 控制 Finder）跨重建、跨 OTA 升级持续有效（v2.3 起）。
- **发布流水线**：`git tag v2.x.y && git push --tags` → GitHub Actions 自动完成 图标渲染 → swiftc 编译 → 打包 zip → 创建 Release（见 `.github/workflows/release.yml`）。

## 用法

**GUI（推荐）**：打开 `彻底卸载.app`，左侧选应用（或把 .app 拖进窗口）→ 右侧分组勾选要删的痕迹 → Remove。文件进废纸篓；系统级项目一次密码。

**残留文件页**：扫描已删除应用留下的孤儿文件——只列出高置信度项（反向域名命名的私产文件，且不属于任何在装应用的厂商家族），**默认全不选**，逐项确认后再删。

**命令行**：

```bash
app-uninstaller.sh /Applications/XXX.app            # 列出清单，交互确认
app-uninstaller.sh /Applications/XXX.app --dry-run  # 只扫描列出，不删任何东西
app-uninstaller.sh /Applications/XXX.app --yes      # 免确认直接删
```

每次运行全量日志：`~/Library/Logs/app-uninstaller/YYYYMMDD-HHMMSS.log`。

## 清理范围

应用本体 + 约 30 个位置的残留：`~/Library` 的 Application Support / Caches / Preferences(含 ByHost) / Containers / Group Containers / HTTPStorages / WebKit / Logs / Saved State / LaunchAgents 等；`/Library` 对应位置；家目录 dotfiles；`/private/var/folders` 缓存；Spotlight 按 Bundle ID 全卷索引；驻留进程；launchd 启动项/守护；钥匙串（含 Electron Safe Storage）；pkg 安装收据（lsbom 反查组件包）；`.systemextension` 系统扩展（提权停用）。另提示：Downloads 安装包、BTM 后台项开关（仅提示不删）。

## 系统清理的安全边界（v2.4）

- 进程：只列 uid 501 用户进程；系统路径（/System /usr /bin /sbin /Library/Apple）、裸名守护、必需名单（含终端/编辑器宿主/本工具）、公司组件（lark、defender、corplink 等硬保护）一律不出现或只提示；僵尸/卡死只提示不杀；**全部默认不勾选**；终止前二次核验 uid+可执行路径+**启动时间**（防 pid 复用误杀）+状态（U/Z 不杀），仅 SIGTERM
- 磁盘：缓存/日志默认勾选（可再生、属主在跑则默认不勾）；开发缓存按重建成本分档；**大文件、废纸篓、慢重建仓库默认不勾选**；废纸篓清空前先保护名单过滤，且在同轮清理中最先处理（后删的项留篓可恢复）
- 大文件扫描不穿透 .photoslibrary/.fcpbundle/.app 等 POSIX 包、不跨挂载卷；云盘占位文件 6 秒读取熔断，超时不阻塞扫描

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
Sources/SystemClean.swift     # 系统清理页（体检扫描/进程判定/磁盘清理/超时熔断）
bin/app-uninstaller.sh        # 引擎（zsh；--json 扫描 / --items-file 执行 / 经典 CLI）
assets/make_icon.swift        # 图标渲染器（AppKit 绘制）
assets/icon_1024.png / icon.icns
tests/run_uninstaller_tests.zsh
build.sh                      # 一键构建安装（图标+引擎+swiftc+打包）
```

## 已知边界

- 删除 App 本体走三段通道：① 系统原生删除（在 系统设置 → 隐私与安全性 → App 管理 授予一次后永久静默）；② 未授权时自动改走 Finder 通道（首次需允许一次「控制 Finder」；root 所有的 app 由 Finder 弹一次管理员密码）；③ 都失败时引导授权，回到窗口自动重试
- `~/Library/Containers` 保护壳删不掉（containermanagerd/TCC，需完全磁盘访问；无数据残留，残留文件页不展示此类项目）

- 系统扩展停用可能需重启后生效
- BTM「登录项」开关记录无逐项删除接口（macOS 限制），只会提示
- 与目标同 vendor 但**未安装**的撞车目录会进删除名单——确认弹窗逐项可见，取消即可

## 卸载本工具

```bash
rm -rf ~/Applications/彻底卸载.app ~/bin/app-uninstaller.sh ~/Library/Logs/app-uninstaller
```
