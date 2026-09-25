import SwiftUI
import AppKit

// ==================== 模型 ====================

struct ScanItem: Codable, Identifiable {
    let path: String
    let kb: Int
    let kind: String
    let group: String
    var id: String { path }
}

struct ScanProc: Codable, Identifiable {
    let pid: Int
    let cmd: String
    var id: Int { pid }
}

struct ScanResult: Codable {
    let app: String
    let bid: String
    let name: String
    let items: [ScanItem]
    let processes: [ScanProc]
    let proc_review: [String]
    let receipts: [String]
    let keychain: [String]
    let sysex: [String]
    let btm: [String]
    let installers: [String]
    let review: [String]
    let total_kb: Int
    let log: String
}

struct AppRecord: Identifiable, Hashable {
    let path: String
    let name: String
    let bid: String
    var id: String { path }
}

struct OrphanItem: Identifiable, Hashable {
    let path: String
    let group: String
    let isSys: Bool
    var kb: Int = 0
    var id: String { path }
}

enum MainTab: Hashable { case apps, orphans, about }

let CURRENT_VERSION = "2.2.0"
let RELEASES_API = "https://api.github.com/repos/xiaoyuediandao/app-uninstaller/releases/latest"
let REPO_PAGE = "https://github.com/xiaoyuediandao/app-uninstaller"

enum UpdatePhase: Equatable {
    case idle, checking, upToDate, available(String), downloading, installing, failed(String)
}

struct GHRelease: Decodable {
    let tag_name: String
    let name: String?
    let body: String?
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let browser_download_url: String }
}

func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x < y ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
}

// ==================== 工具 ====================

let ENGINE = NSHomeDirectory() + "/bin/app-uninstaller.sh"
let ACCENT = Color(red: 0.36, green: 0.36, blue: 0.90)

func runProcess(_ launch: String, _ args: [String]) -> (Int32, Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, Data()) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

func fmtKB(_ kb: Int) -> String {
    if kb >= 1024 * 1024 { return String(format: "%.1f GB", Double(kb) / 1048576.0) }
    if kb >= 1024 { return String(format: "%.1f MB", Double(kb) / 1024.0) }
    return "\(kb) KB"
}

func duKB(_ path: String) -> Int {
    let (_, d) = runProcess("/usr/bin/du", ["-sk", path])
    guard let s = String(data: d, encoding: .utf8),
          let n = Int(s.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "") else { return 0 }
    return n
}

func appName(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
}

// 公司 IT 组件保护（与引擎一致）
let PROTECT_KEYWORDS = ["puppet","corplink","volcengine","flinco","knightmdm","grahamgilbert",
                        "erikng","macjutsu","ide_check","wdav","fresno","dlp","byteplus","sealsuite",
                        "larksuite","arcadepayout-guard"]
func isProtected(_ bidOrName: String) -> Bool {
    let l = bidOrName.lowercased()
    return PROTECT_KEYWORDS.contains { l.contains($0) }
}

// ==================== ViewModel ====================

@MainActor
final class AppViewModel: ObservableObject {
    @Published var tab: MainTab? = .apps

    // 应用列表
    @Published var apps: [AppRecord] = []
    @Published var appSizes: [String: Int] = [:]
    @Published var searchText = ""
    @Published var sortBySize = false
    @Published var selectedApp: String? = nil

    // 扫描
    @Published var scan: ScanResult? = nil
    @Published var scanning = false
    @Published var scanError: String? = nil

    // 勾选
    @Published var uncheckedPaths: Set<String> = []
    @Published var uncheckedPids: Set<Int> = []
    @Published var uncheckedReceipts: Set<String> = []
    @Published var uncheckedKC: Set<String> = []
    @Published var uncheckedSysex: Set<String> = []

    // 执行
    @Published var removing = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    @Published var showAlert = false
    @Published var confirmRemove = false

    // 残留文件
    @Published var orphans: [OrphanItem] = []
    @Published var orphanScanning = false
    @Published var uncheckedOrphans: Set<String> = []
    @Published var orphanScannedOnce = false
    @Published var collapsedGroups: Set<String> = []
    @Published var appDates: [String: String] = [:]
    @Published var updatePhase: UpdatePhase = .idle
    @Published var updateNotes = ""
    @Published var updateURL = ""

    // ---------- OTA 更新（参考 AgenticGo：GitHub Releases latest + URLSession 下载替换）----------
    func checkForUpdate() {
        if case .checking = updatePhase { return }
        updatePhase = .checking
        Task.detached { [weak self] in
            do {
                var req = URLRequest(url: URL(string: RELEASES_API)!)
                req.setValue("app-uninstaller/\(CURRENT_VERSION)", forHTTPHeaderField: "User-Agent")
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let rel = try JSONDecoder().decode(GHRelease.self, from: data)
                let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if compareVersions(latest, CURRENT_VERSION) == .orderedDescending,
                   let asset = rel.assets.first(where: { $0.name.hasSuffix(".zip") }) {
                    await MainActor.run {
                        self?.updateNotes = rel.body ?? ""
                        self?.updateURL = asset.browser_download_url
                        self?.updatePhase = .available(latest)
                    }
                } else {
                    await MainActor.run { self?.updatePhase = .upToDate }
                }
            } catch {
                await MainActor.run { self?.updatePhase = .failed(error.localizedDescription) }
            }
        }
    }

    func performUpdate() {
        guard case .available = updatePhase else { return }
        updatePhase = .downloading
        let url = updateURL
        Task.detached { [weak self] in
            do {
                let (tmpFile, _) = try await URLSession.shared.download(from: URL(string: url)!)
                let work = NSTemporaryDirectory() + "app-uninstaller-update-\(UUID().uuidString)"
                try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
                let zipPath = work + "/update.zip"
                try FileManager.default.moveItem(atPath: tmpFile.path, toPath: zipPath)
                _ = runProcess("/usr/bin/ditto", ["-xk", zipPath, work])
                let contents = try FileManager.default.contentsOfDirectory(atPath: work)
                guard let appDir = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw URLError(.cannotDecodeContentData)
                }
                await MainActor.run { self?.updatePhase = .installing }
                let dest = NSHomeDirectory() + "/Applications/彻底卸载.app"
                _ = try? FileManager.default.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil)
                try FileManager.default.moveItem(atPath: work + "/" + appDir, toPath: dest)
                _ = runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest])
                _ = runProcess("/usr/bin/open", ["-n", dest])
                exit(0)
            } catch {
                await MainActor.run { self?.updatePhase = .failed(error.localizedDescription) }
            }
        }
    }
    func isCollapsed(_ key: String) -> Bool { collapsedGroups.contains(key) }
    func toggleCollapsed(_ key: String) {
        if collapsedGroups.contains(key) { collapsedGroups.remove(key) }
        else { collapsedGroups.insert(key) }
    }

    var filteredApps: [AppRecord] {
        var list = apps
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.bid.localizedCaseInsensitiveContains(searchText) }
        }
        if sortBySize {
            list.sort { (appSizes[$0.path] ?? 0) > (appSizes[$1.path] ?? 0) }
        } else {
            list.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        return list
    }

    func start() {
        loadApps()
    }

    func loadApps() {
        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [String: AppRecord] = [:]
            let (_, data) = runProcess("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"])
            var paths = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
            let extra = ["/Applications", NSHomeDirectory() + "/Applications", "/Library/Input Methods"]
            for dir in extra {
                if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    paths += items.filter { $0.hasSuffix(".app") }.map { dir + "/" + $0 }
                }
            }
            for p in paths {
                guard p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/") || p.hasPrefix("/Library/Input Methods/") else { continue }
                guard let bundle = Bundle(path: p), let bid = bundle.bundleIdentifier else { continue }
                if bid.hasPrefix("com.apple.") || isProtected(bid) { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? appName(p)
                if isProtected(name) { continue }
                found[p] = AppRecord(path: p, name: name, bid: bid)
            }
            let list = Array(found.values)
            let df = DateFormatter()
            df.dateFormat = "yyyy年M月d日"
            var dates: [String: String] = [:]
            for rec in list {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: rec.path),
                   let d = attrs[.modificationDate] as? Date {
                    dates[rec.path] = df.string(from: d)
                }
            }
            await MainActor.run {
                self?.apps = list
                self?.appDates = dates
            }
            // 后台逐个算大小
            for rec in list {
                let kb = duKB(rec.path)
                await MainActor.run { self?.appSizes[rec.path] = kb }
            }
        }
    }

    func openExternalApp(path: String) {
        tab = .apps
        selectedApp = path
        scanApp(path: path)
    }

    func scanApp(path: String) {
        if scanning { return }
        scanning = true
        scanError = nil
        scan = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let (rc, data) = runProcess("/bin/zsh", [ENGINE, "--json", path])
            await MainActor.run {
                guard let self else { return }
                self.scanning = false
                if rc == 0, let result = try? JSONDecoder().decode(ScanResult.self, from: data) {
                    self.scan = result
                    self.uncheckedPaths = []
                    self.uncheckedPids = []
                    self.uncheckedReceipts = []
                    self.uncheckedKC = []
                    self.uncheckedSysex = []
                } else {
                    let txt = String(data: data, encoding: .utf8) ?? "未知错误"
                    self.scanError = txt.components(separatedBy: "\n").first { $0.hasPrefix("ERROR") } ?? "扫描失败 (rc=\(rc))"
                }
            }
        }
    }

    var checkedItems: [ScanItem] { (scan?.items ?? []).filter { !uncheckedPaths.contains($0.path) } }
    var checkedKB: Int { checkedItems.reduce(0) { $0 + $1.kb } }
    var checkedCount: Int {
        checkedItems.count
            + (scan?.processes ?? []).filter { !uncheckedPids.contains($0.pid) }.count
            + (scan?.receipts ?? []).filter { !uncheckedReceipts.contains($0) }.count
            + (scan?.keychain ?? []).filter { !uncheckedKC.contains($0) }.count
            + (scan?.sysex ?? []).filter { !uncheckedSysex.contains($0) }.count
    }

    func groupedItems() -> [(String, [ScanItem])] {
        let order = ["应用本体", "Application Support", "Caches", "Preferences", "Containers",
                     "Group Containers", "HTTPStorages", "WebKit", "Saved Application State",
                     "Logs", "启动项", "家目录顶层", "/Library 系统级", "其他"]
        let g = Dictionary(grouping: checkedItemsAll, by: { $0.group })
        return order.compactMap { key in g[key].map { (key, $0) } } + g.filter { !order.contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    var checkedItemsAll: [ScanItem] { scan?.items ?? [] }

    func groupChecked(_ group: String) -> Bool {
        let paths = (scan?.items ?? []).filter { $0.group == group }.map { $0.path }
        return !paths.isEmpty && paths.allSatisfy { !uncheckedPaths.contains($0) }
    }
    func toggleGroup(_ group: String) {
        let paths = (scan?.items ?? []).filter { $0.group == group }.map { $0.path }
        if groupChecked(group) { paths.forEach { uncheckedPaths.insert($0) } }
        else { paths.forEach { uncheckedPaths.remove($0) } }
    }
    func selectAll() {
        uncheckedPaths = []; uncheckedPids = []; uncheckedReceipts = []; uncheckedKC = []; uncheckedSysex = []
    }
    func selectNone() {
        uncheckedPaths = Set((scan?.items ?? []).map { $0.path })
        uncheckedPids = Set((scan?.processes ?? []).map { $0.pid })
        uncheckedReceipts = Set(scan?.receipts ?? [])
        uncheckedKC = Set(scan?.keychain ?? [])
        uncheckedSysex = Set(scan?.sysex ?? [])
    }

    @Published var showPermHint = false

    func removeSelected() {
        guard let scan else { return }
        removing = true
        // 本体/容器：macOS「App 管理」TCC 会拦引擎的 mv，改由 GUI 用系统原生 trashItem（走系统授权流）
        let guiTrashGroups: Set<String> = ["应用本体", "Containers", "Group Containers"]
        let guiItems = scan.items.filter { !uncheckedPaths.contains($0.path) && guiTrashGroups.contains($0.group) }
        let engineItems = scan.items.filter { !uncheckedPaths.contains($0.path) && !guiTrashGroups.contains($0.group) }
        var lines: [String] = engineItems.map { $0.path }
        for pr in scan.processes where !uncheckedPids.contains(pr.pid) { lines.append("PROC:\(pr.pid)") }
        for r in scan.receipts where !uncheckedReceipts.contains(r) { lines.append("RECEIPT:\(r)") }
        for k in scan.keychain where !uncheckedKC.contains(k) { lines.append("KC:\(k)") }
        for x in scan.sysex where !uncheckedSysex.contains(x) { lines.append("SYSEX:\(x)") }
        let appPath = scan.app
        let scanName = scan.name
        let logPath = scan.log
        Task.detached(priority: .userInitiated) { [weak self] in
            var failures: [String] = []
            var protectedLeft = 0
            // 1) 引擎：终止进程 + 删除勾选残留（不动本体/容器）
            if !lines.isEmpty {
                let planFile = NSTemporaryDirectory() + "uninstall-plan-\(UUID().uuidString).txt"
                try? lines.joined(separator: "\n").write(toFile: planFile, atomically: true, encoding: .utf8)
                let (_, data) = runProcess("/bin/zsh", [ENGINE, "--items-file", planFile, appPath])
                try? FileManager.default.removeItem(atPath: planFile)
                let out = String(data: data, encoding: .utf8) ?? ""
                failures += out.components(separatedBy: "\n").filter { $0.hasPrefix("FAIL") }
            }
            // 2) 本体/容器：系统原生 trashItem（可进废纸篓；未授权 App 管理时返回错误）
            var appFailed = false
            for it in guiItems {
                do {
                    _ = try FileManager.default.trashItem(at: URL(fileURLWithPath: it.path), resultingItemURL: nil)
                } catch {
                    if it.group == "应用本体" { appFailed = true } else { protectedLeft += 1 }
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.removing = false
                if appFailed {
                    self.alertMessage = "macOS 的「App 管理」保护拦截了删除 \(scanName).app。\n授权一次后重试即可：系统设置 → 隐私与安全性 → App 管理 → 打开「彻底卸载」。"
                    self.showPermHint = true
                } else if !failures.isEmpty {
                    self.alertTitle = "基本完成"
                    self.alertMessage = "以下项目未能清除：\n" + failures.prefix(6).joined(separator: "\n")
                        + (protectedLeft > 0 ? "\n另有 \(protectedLeft) 个系统保护目录未删（无数据，可忽略）" : "")
                        + "\n\n日志: \(logPath)"
                    self.showAlert = true
                } else {
                    self.alertTitle = "卸载完成"
                    self.alertMessage = "\(scanName) 已彻底卸载，文件已进废纸篓。"
                        + (protectedLeft > 0 ? "\n（\(protectedLeft) 个系统保护目录壳未删，无数据，可忽略）" : "")
                        + "\n日志: \(logPath)"
                    self.showAlert = true
                }
                if FileManager.default.fileExists(atPath: appPath) {
                    self.scanApp(path: appPath)
                } else {
                    self.scan = nil
                    self.selectedApp = nil
                    self.loadApps()
                }
            }
        }
    }

    // ---------- 残留文件（孤儿扫描，Swift 原生实现）----------

    func scanOrphans() {
        orphanScanning = true
        orphans = []
        uncheckedOrphans = []
        Task.detached(priority: .userInitiated) { [weak self] in
            // 高置信度规则（v2.1）：
            //  a) 必须"长得像某 app 私产"——反向域名三段式（com.x.y / cn.x.y ...）
            //  b) 归属判定：已安装应用的 bid 精确匹配 + 厂商家族令牌（bid 第二段/名称首词）
            //  c) 不扫描 Containers/Group Containers（系统保护删不掉）、家目录 dotfiles、崩溃报告
            var bids = Set<String>()
            var family = Set<String>()
            let genericSeg: Set<String> = ["electron","framework","system","library","lib","app","apps","mac","macos","osx","ios","swift","cocoa","bot","pc","client","desktop","common","core","base","ui","web","node","js","lite","pro","plus","free","tool","tools","util","utils","helper","service","agent","daemon","manager","studio","code","cloud","drive","mail","video","music","player","notes","browser","game","games","cups","printing"]
            func ingestApp(_ p: String) {
                guard let bundle = Bundle(path: p), var bid = bundle.bundleIdentifier else { return }
                bid = bid.lowercased()
                if bid.hasPrefix("com.apple.") { return }
                bids.insert(bid)
                let segs = bid.split(separator: ".").map(String.init)
                for v in segs.dropFirst() {
                    if v.count >= 4 && !genericSeg.contains(v) { family.insert(v) }
                }
                let nm = ((bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? appName(p)).lowercased()
                if let first = nm.split(separator: " ").first {
                    let f = String(first)
                    if f.count >= 4 && !genericSeg.contains(f) { family.insert(f) }
                }
            }
            let (_, appData) = runProcess("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"])
            var appPaths = String(data: appData, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
            for dir in ["/Applications", NSHomeDirectory() + "/Applications", "/Library/Input Methods", "/Library/SystemExtensions"] {
                if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    appPaths += items.filter { $0.hasSuffix(".app") }.map { dir + "/" + $0 }
                }
            }
            appPaths.forEach(ingestApp)

            let keepNames = ["arcadepayout-guard", "app-uninstaller", "org.cups"]
            func owned(_ lb: String) -> Bool {
                if lb.hasPrefix("com.apple.") || lb.hasPrefix("group.com.apple") { return true }
                for kw in PROTECT_KEYWORDS { if lb.contains(kw) { return true } }
                for k in keepNames { if lb.contains(k) { return true } }
                for b in bids {
                    if lb == b || lb.hasPrefix(b + ".") || b.hasPrefix(lb + ".") { return true }
                }
                for f in family {
                    if lb.contains(f) { return true }
                }
                return false
            }
            let rdns = try! NSRegularExpression(pattern: #"^[a-z]{2,4}\.[a-z0-9][a-z0-9_-]*\.[a-z0-9][a-z0-9._-]*$"#)
            func looksAppOwned(_ lb: String) -> Bool {
                rdns.firstMatch(in: lb, range: NSRange(lb.startIndex..., in: lb)) != nil
            }

            let home = NSHomeDirectory()
            let scanDirs: [(String, String, Bool, String?)] = [
                (home + "/Library/Application Support", "Application Support", false, nil),
                (home + "/Library/Caches", "Caches", false, nil),
                (home + "/Library/Preferences", "Preferences", false, ".plist"),
                (home + "/Library/HTTPStorages", "HTTPStorages", false, nil),
                (home + "/Library/WebKit", "WebKit", false, nil),
                (home + "/Library/Saved Application State", "Saved Application State", false, ".savedState"),
                (home + "/Library/LaunchAgents", "启动项", false, ".plist"),
                ("/Library/Application Support", "/Library 系统级", true, nil),
                ("/Library/Caches", "/Library 系统级", true, nil),
                ("/Library/LaunchAgents", "启动项", true, ".plist"),
                ("/Library/LaunchDaemons", "启动项", true, ".plist"),
            ]
            var result: [OrphanItem] = []
            var seen = Set<String>()
            for (dir, group, isSys, suffix) in scanDirs {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for e in entries {
                    if e.hasPrefix(".") { continue }
                    var base = e.lowercased()
                    if let suf = suffix {
                        guard base.hasSuffix(suf) else { continue }
                        base = String(base.dropLast(suf.count))
                    }
                    if !looksAppOwned(base) { continue }
                    if owned(base) { continue }
                    let full = dir + "/" + e
                    if seen.contains(full) { continue }
                    seen.insert(full)
                    result.append(OrphanItem(path: full, group: group, isSys: isSys))
                }
            }
            var sized: [OrphanItem] = []
            for item in result.prefix(800) {
                var i = item
                i.kb = duKB(item.path)
                sized.append(i)
            }
            sized.sort { $0.kb > $1.kb }
            let allPaths = Set(sized.map { $0.path })
            await MainActor.run {
                self?.orphans = sized
                self?.uncheckedOrphans = allPaths   // 默认全不选：高置信但需人工确认
                self?.orphanScanning = false
                self?.orphanScannedOnce = true
            }
        }
    }

    func removeOrphans() {
        let targets = orphans.filter { !uncheckedOrphans.contains($0.path) }
        guard !targets.isEmpty else { return }
        removing = true
        let userTargets = targets.filter { !$0.isSys }
        let sysTargets = targets.filter { $0.isSys }
        Task.detached(priority: .userInitiated) { [weak self] in
            var failures: [String] = []
            for t in userTargets {
                do {
                    _ = try FileManager.default.trashItem(at: URL(fileURLWithPath: t.path), resultingItemURL: nil)
                } catch {
                    failures.append(t.path)
                }
            }
            if !sysTargets.isEmpty {
                // 系统级：一次提权删除
                let cmds = sysTargets.map { t -> String in
                    let q = t.path.replacingOccurrences(of: "'", with: "'\\''")
                    return "/bin/rm -rf -- '\(q)'"
                }
                let script = cmds.joined(separator: "; ")
                let esc = script
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let osa = "do shell script \"\(esc)\" with administrator privileges"
                let (rc, _) = runProcess("/usr/bin/osascript", ["-e", osa])
                if rc != 0 { failures += sysTargets.map { $0.path } }
            }
            await MainActor.run {
                guard let self else { return }
                self.removing = false
                if failures.isEmpty {
                    self.alertTitle = "清理完成"
                    self.alertMessage = "已删除 \(targets.count) 项残留（用户级进废纸篓，可恢复）。"
                } else {
                    self.alertTitle = "部分完成"
                    self.alertMessage = "以下 \(failures.count) 项未能删除：\n" + failures.prefix(8).joined(separator: "\n")
                }
                self.showAlert = true
                self.scanOrphans()
            }
        }
    }
}

// ==================== 界面 ====================

let SIDEBAR_TOP = Color(red: 0.063, green: 0.165, blue: 0.361)
let SIDEBAR_BOT = Color(red: 0.114, green: 0.290, blue: 0.600)
let ROW_SEL = Color(red: 0.898, green: 0.937, blue: 1.000)
let GROUP_BG = Color(red: 0.949, green: 0.965, blue: 1.000)
let BTN_DISABLED = Color(red: 0.910, green: 0.929, blue: 0.961)
let FOLDER_BLUE = Color(red: 0.290, green: 0.565, blue: 0.886)
let ACCENT2 = Color(red: 0.180, green: 0.420, blue: 0.910)

struct ContentView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            Sep()
            if (model.tab ?? .apps) == .about {
                AboutView()
            } else {
                MiddleView()
                Sep()
                DetailView()
            }
        }
        .frame(minWidth: 1140, minHeight: 700)
        .background(.white)
        .alert("需要授权才能删除 App 本体", isPresented: $model.showPermHint) {
            Button("打开 App 管理设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }
        .alert(model.alertTitle, isPresented: $model.showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }
        .alert("确认删除", isPresented: $model.confirmRemove) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { model.removeSelected() }
        } message: {
            Text("将删除 \(model.checkedCount) 项（约 \(fmtKB(model.checkedKB))），文件进废纸篓（可恢复）。\n若有系统级项目，将弹一次管理员密码。")
        }
        .overlay {
            if model.removing {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("正在删除…").font(.headline)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

struct Sep: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(width: 1)
    }
}

struct HSep: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1)
    }
}

// ---------- 侧边栏 ----------

struct SidebarView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 36)
            Text("清理")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 22)
                .padding(.bottom, 2)
            SidebarRow(icon: "square.grid.2x2.fill", title: "应用程序",
                       selected: (model.tab ?? .apps) == .apps) { model.tab = .apps }
            SidebarRow(icon: "trash.fill", title: "残留文件",
                       selected: (model.tab ?? .apps) == .orphans) { model.tab = .orphans }
            SidebarRow(icon: "info.circle.fill", title: "关于",
                       selected: (model.tab ?? .apps) == .about) { model.tab = .about }
            Spacer()
            HStack(spacing: 7) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                Text("彻底卸载 v\(CURRENT_VERSION)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.leading, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(colors: [SIDEBAR_TOP, SIDEBAR_BOT],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

struct SidebarRow: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(red: 0.55, green: 0.72, blue: 1.0))
                .font(.system(size: 14, weight: .medium))
                .frame(width: 22, alignment: .center)
            Text(title)
                .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.white.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// ---------- 中栏 ----------

struct MiddleView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.tab ?? .apps {
            case .apps: AppsMiddle()
            case .orphans: OrphansMiddle()
            case .about: EmptyView()
            }
        }
        .frame(width: 302)
        .frame(maxHeight: .infinity)
        .background(.white)
    }
}

struct AppsMiddle: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("彻底卸载").font(.system(size: 19, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 10)
            // 搜索 + 排序
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("搜索", text: $model.searchText)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                Menu {
                    Button("按名称") { model.sortBySize = false }
                    Button("按大小") { model.sortBySize = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(model.sortBySize ? "大小" : "名称").font(.system(size: 12.5))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 62)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            HSep()
            // 应用列表
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredApps) { rec in
                        VStack(spacing: 0) {
                            AppRow(rec: rec, selected: model.selectedApp == rec.path,
                                   sizeKB: model.appSizes[rec.path],
                                   date: model.appDates[rec.path])
                                .onTapGesture { model.selectedApp = rec.path }
                            if rec.id != model.filteredApps.last?.id {
                                HSep().padding(.leading, 56)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onChange(of: model.selectedApp) { _, newValue in
            if let p = newValue { model.scanApp(path: p) }
        }
    }
}

struct AppRow: View {
    let rec: AppRecord
    let selected: Bool
    let sizeKB: Int?
    let date: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: rec.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(date ?? rec.bid)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(sizeKB.map { fmtKB($0) } ?? "…")
                    .font(.system(size: 12, weight: .semibold))
                Text(rec.bid)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(selected ? ROW_SEL : Color.clear)
        .contentShape(Rectangle())
    }
}

struct OrphansMiddle: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("残留文件").font(.system(size: 19, weight: .bold))
                    Text("仅列出高置信度残留 · 默认不勾选").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.scanOrphans()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(model.orphanScanning)
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 10)
            HSep()
            if model.orphanScanning {
                Spacer()
                ProgressView("正在扫描…").controlSize(.regular)
                Spacer()
            } else if model.orphans.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: model.orphanScannedOnce ? "checkmark.circle" : "trash")
                        .font(.system(size: 34))
                        .foregroundStyle(model.orphanScannedOnce ? .green : ACCENT2)
                    Text(model.orphanScannedOnce ? "没有发现残留，很干净" : "点击右上角 ↻ 开始扫描")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.orphans) { item in
                            OrphanRow(item: item)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .onAppear {
            if !model.orphanScannedOnce && !model.orphanScanning { model.scanOrphans() }
        }
    }
}

struct OrphanRow: View {
    @EnvironmentObject var model: AppViewModel
    let item: OrphanItem

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !model.uncheckedOrphans.contains(item.path) },
                set: { on in
                    if on { model.uncheckedOrphans.remove(item.path) }
                    else { model.uncheckedOrphans.insert(item.path) }
                }))
            .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: item.isSys ? "lock.fill" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(item.isSys ? .orange : FOLDER_BLUE)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(item.path)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(fmtKB(item.kb)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// ---------- 详情栏 ----------

struct DetailView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        switch model.tab ?? .apps {
        case .apps: ScanDetailView()
        case .orphans: OrphanDetailView()
        case .about: EmptyView()
        }
    }
}

struct ScanDetailView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.scanning {
                Spacer()
                ProgressView("正在扫描全部痕迹…").controlSize(.large)
                Spacer()
            } else if let err = model.scanError {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 38)).foregroundStyle(.orange)
                    Text(err).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
            } else if let scan = model.scan {
                headerView(scan)
                HSep()
                selectAllRow(scan)
                HSep()
                groupsScroll(scan)
                HSep()
                bottomBar(scan)
            } else {
                dropHint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.path.hasSuffix(".app") {
                        DispatchQueue.main.async { model.openExternalApp(path: url.path) }
                    }
                }
            }
            return true
        }
    }

    var dropHint: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("彻底卸载")
                .font(.system(size: 26, weight: .bold))
            Text("选择应用，审查关联文件。\n彻底卸载任何应用程序。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            if let url = Bundle.main.url(forResource: "illustration", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 380)
                    .padding(.vertical, 18)
            }
            // 虚线拖放区
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, ACCENT2)
                    .font(.system(size: 26))
                Text("拖放 .app 到这里，快速彻底卸载")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 440, height: 104)
            .background(Color(red: 0.965, green: 0.980, blue: 1.0),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(ACCENT2, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            )
            Spacer()
            HStack {
                Spacer()
                Text("卸载")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.62, green: 0.66, blue: 0.73))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 8)
                    .background(BTN_DISABLED, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    func headerView(_ scan: ScanResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("即将删除的文件").font(.system(size: 19, weight: .bold))
                Text("\(scan.name) 及其全部关联痕迹").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(nsImage: NSWorkspace.shared.icon(forFile: scan.app))
                .resizable().frame(width: 40, height: 40)
            VStack(alignment: .trailing, spacing: 2) {
                Text(fmtKB(scan.total_kb)).font(.system(size: 17, weight: .semibold)).foregroundStyle(ACCENT2)
                Text("\(scan.items.count) 项痕迹").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    var allChecked: Bool {
        model.uncheckedPaths.isEmpty && model.uncheckedPids.isEmpty
            && model.uncheckedReceipts.isEmpty && model.uncheckedKC.isEmpty
            && model.uncheckedSysex.isEmpty
    }

    func selectAllRow(_ scan: ScanResult) -> some View {
        HStack {
            Toggle("全选", isOn: Binding(
                get: { allChecked },
                set: { on in on ? model.selectAll() : model.selectNone() }))
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))
            Spacer()
            Text("\(model.checkedCount)/\(scan.items.count + scan.processes.count + scan.receipts.count + scan.keychain.count + scan.sysex.count) 项")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    func groupsScroll(_ scan: ScanResult) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.groupedItems(), id: \.0) { group, items in
                    FileGroupView(group: group, items: items)
                }
                if !scan.processes.isEmpty {
                    ProcGroupView(scan: scan)
                }
                if !scan.receipts.isEmpty {
                    SimpleGroupView(title: "pkg 安装收据", icon: "doc.text.fill", rows: scan.receipts,
                                    isUnchecked: { model.uncheckedReceipts.contains($0) },
                                    setUnchecked: { r, on in
                                        if on { model.uncheckedReceipts.remove(r) } else { model.uncheckedReceipts.insert(r) }
                                    })
                }
                if !scan.keychain.isEmpty {
                    SimpleGroupView(title: "钥匙串条目", icon: "key.fill", rows: scan.keychain,
                                    isUnchecked: { model.uncheckedKC.contains($0) },
                                    setUnchecked: { r, on in
                                        if on { model.uncheckedKC.remove(r) } else { model.uncheckedKC.insert(r) }
                                    })
                }
                if !scan.sysex.isEmpty {
                    SimpleGroupView(title: "系统扩展（停用可能需重启）", icon: "puzzlepiece.fill", rows: scan.sysex,
                                    isUnchecked: { model.uncheckedSysex.contains($0) },
                                    setUnchecked: { r, on in
                                        if on { model.uncheckedSysex.remove(r) } else { model.uncheckedSysex.insert(r) }
                                    })
                }
                if !scan.review.isEmpty {
                    ReviewGroupView(scan: scan)
                }
                if !scan.btm.isEmpty || !scan.installers.isEmpty {
                    InfoGroupView(scan: scan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    func bottomBar(_ scan: ScanResult) -> some View {
        HStack {
            Text("已选 \(model.checkedCount) 项 · \(fmtKB(model.checkedKB))")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button {
                model.confirmRemove = true
            } label: {
                Text("卸载")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.checkedCount == 0 ? Color.secondary : .white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 8)
                    .background(model.checkedCount == 0 ? BTN_DISABLED : ACCENT2,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.checkedCount == 0 || model.removing)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// 文件分组（Application Support / Caches / ...）
struct FileGroupView: View {
    @EnvironmentObject var model: AppViewModel
    let group: String
    let items: [ScanItem]

    var body: some View {
        VStack(spacing: 0) {
            // 组头
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { model.groupChecked(group) },
                    set: { _ in model.toggleGroup(group) }))
                .toggleStyle(.checkbox).labelsHidden()
                Image(systemName: model.isCollapsed(group) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text(group).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(items.count) 项 · \(fmtKB(items.reduce(0) { $0 + $1.kb }))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(GROUP_BG, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCollapsed(group) }
            // 组内文件
            if !model.isCollapsed(group) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { !model.uncheckedPaths.contains(item.path) },
                                set: { on in
                                    if on { model.uncheckedPaths.remove(item.path) }
                                    else { model.uncheckedPaths.insert(item.path) }
                                }))
                            .toggleStyle(.checkbox).labelsHidden()
                            Image(systemName: item.kind == "sys" ? "lock.fill" : "folder.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(item.kind == "sys" ? .orange : FOLDER_BLUE)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                    .font(.system(size: 12)).lineLimit(1)
                                Text(item.path)
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(fmtKB(item.kb)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        if item.id != items.last?.id {
                            HSep().padding(.leading, 36)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

// 进程分组
struct ProcGroupView: View {
    @EnvironmentObject var model: AppViewModel
    let scan: ScanResult
    private let key = "__proc"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.isCollapsed(key) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text("驻留进程（将终止）").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(scan.processes.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(GROUP_BG, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCollapsed(key) }
            if !model.isCollapsed(key) {
                VStack(spacing: 0) {
                    ForEach(scan.processes) { pr in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { !model.uncheckedPids.contains(pr.pid) },
                                set: { on in
                                    if on { model.uncheckedPids.remove(pr.pid) } else { model.uncheckedPids.insert(pr.pid) }
                                }))
                            .toggleStyle(.checkbox).labelsHidden()
                            Image(systemName: "gearshape.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("PID \(pr.pid)  \(pr.cmd)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

// 简单勾选分组（收据/钥匙串/系统扩展）
struct SimpleGroupView: View {
    @EnvironmentObject var model: AppViewModel
    let title: String
    let icon: String
    let rows: [String]
    let isUnchecked: (String) -> Bool
    let setUnchecked: (String, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.isCollapsed(title) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(rows.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(GROUP_BG, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCollapsed(title) }
            if !model.isCollapsed(title) {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.self) { r in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { !isUnchecked(r) },
                                set: { on in setUnchecked(r, !on) }))
                            .toggleStyle(.checkbox).labelsHidden()
                            Text(r).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

// 名称相近（仅提示）
struct ReviewGroupView: View {
    @EnvironmentObject var model: AppViewModel
    let scan: ScanResult
    private let key = "__review"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.isCollapsed(key) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("名称相近，可能属于其他软件").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(scan.review.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCollapsed(key) }
            if !model.isCollapsed(key) {
                VStack(spacing: 0) {
                    ForEach(scan.review, id: \.self) { r in
                        HStack(spacing: 8) {
                            Text(r).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("不删除").font(.system(size: 9.5))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

// 提示分组（BTM/安装包）
struct InfoGroupView: View {
    @EnvironmentObject var model: AppViewModel
    let scan: ScanResult
    private let key = "__info"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.isCollapsed(key) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("提示（不自动处理）").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(scan.btm.count + scan.installers.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCollapsed(key) }
            if !model.isCollapsed(key) {
                VStack(spacing: 0) {
                    ForEach(scan.btm, id: \.self) { b in
                        Text("BTM 后台项: \(b)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                    }
                    ForEach(scan.installers, id: \.self) { i in
                        Text("安装包: \(i)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

// 残留文件详情
struct OrphanDetailView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(ACCENT2.opacity(0.65))
                let checked = model.orphans.filter { !model.uncheckedOrphans.contains($0.path) }
                let kb = checked.reduce(0) { $0 + $1.kb }
                Text("已选 \(checked.count) 项").font(.system(size: 16, weight: .medium))
                Text(fmtKB(kb)).font(.system(size: 20, weight: .semibold)).foregroundStyle(ACCENT2)
                Text("默认不勾选——请逐项确认后再删\n用户级文件进废纸篓（可恢复）；🔒 系统级需管理员密码")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    model.removeOrphans()
                } label: {
                    Text("卸载")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(checked.isEmpty ? Color.secondary : .white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 8)
                        .background(checked.isEmpty ? BTN_DISABLED : ACCENT2,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(checked.isEmpty || model.removing)
            }
            .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// ---------- 关于 ----------

struct AboutRow: View {
    let icon: String
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(ACCENT2)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 46, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct AboutView: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer().frame(height: 36)
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 92, height: 92)
                }
                Text("彻底卸载")
                    .font(.system(size: 24, weight: .bold))
                Text("v\(CURRENT_VERSION)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("把要卸载的 .app 拖进来，连根拔起：\n本体、残留文件、驻留进程、启动项、钥匙串、pkg 收据、系统扩展一次清净。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HSep().frame(width: 340).padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 10) {
                    AboutRow(icon: "person.fill", title: "开发者", value: "xiaoyuediandao")
                    AboutRow(icon: "c.circle", title: "版权", value: "© 2026 xiaoyuediandao · MIT License")
                    AboutRow(icon: "link", title: "仓库", value: "github.com/xiaoyuediandao/app-uninstaller")
                    AboutRow(icon: "shield.lefthalf.filled", title: "安全", value: "文件进废纸篓可恢复 · 同名文件只提示不删 · 公司组件硬保护")
                }
                HStack(spacing: 12) {
                    Button {
                        NSWorkspace.shared.open(URL(string: REPO_PAGE)!)
                    } label: {
                        Label("GitHub 仓库", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                    updateButton
                }
                .padding(.top, 6)
                updateStatus
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }

    @ViewBuilder var updateButton: some View {
        switch model.updatePhase {
        case .available(let v):
            Button { model.performUpdate() } label: {
                Label("更新到 v\(v)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(ACCENT2)
        case .downloading, .installing:
            ProgressView().controlSize(.small).frame(width: 90)
        default:
            Button { model.checkForUpdate() } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder var updateStatus: some View {
        switch model.updatePhase {
        case .idle:
            EmptyView()
        case .checking:
            Text("正在检查更新…").font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Label("已是最新版本", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .available(let v):
            Text("发现新版本 v\(v)：一键下载、替换并自动重启")
                .font(.caption).foregroundStyle(.secondary)
        case .downloading:
            Text("正在下载更新包…").font(.caption).foregroundStyle(.secondary)
        case .installing:
            Text("正在安装并重启…").font(.caption).foregroundStyle(.secondary)
        case .failed(let e):
            Text("更新检查失败: \(e)").font(.caption).foregroundStyle(.red)
        }
    }
}

// ==================== 启动 ====================

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = AppViewModel()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        let content = ContentView().environmentObject(model)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "彻底卸载"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let p = filenames.first(where: { $0.hasSuffix(".app") }) {
            window?.makeKeyAndOrderFront(nil)
            model.openExternalApp(path: p)
            sender.reply(toOpenOrPrint: .success)
        } else {
            sender.reply(toOpenOrPrint: .failure)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于彻底卸载", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出彻底卸载", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()   // run() 不返回，delegate 随闭包常驻
}
