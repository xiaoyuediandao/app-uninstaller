import SwiftUI
import AppKit

// ==================== 系统清理：模型 ====================

struct SysStats {
    let cpuBusy: Double      // 0-100
    let memUsedGB: Double
    let memTotalGB: Double
    let memFreePct: Int      // memory_pressure 报告的空闲百分比
    let diskFreeGB: Double
    let diskTotalGB: Double
}

struct CleanProc: Identifiable {
    let pid: Int
    let ppid: Int
    let name: String
    let cmd: String          // 可执行文件全路径（用于二次核验）
    let lstart: String       // 进程启动时间串（终止前代际核验，防 pid 复用误杀）
    let cpu: Double
    let memMB: Double
    let reason: String
    let killable: Bool       // false = 只提示（僵尸/卡死/系统进程）
    var id: Int { pid }
}

struct CleanItem: Identifiable {
    let path: String
    let kb: Int
    let group: String        // 应用缓存 / 日志文件 / 开发者缓存 / 废纸篓 / 大文件
    let note: String
    var id: String { path }
}

// 分组常量
let CG_PROC = "异常进程"
let CG_CACHE = "应用缓存"
let CG_LOG = "日志文件"
let CG_DEV = "开发者缓存"
let CG_TRASH = "废纸篓"
let CG_BIG = "大文件（请人工确认）"

// 进程清理的系统必需名单（永不可杀，含终端/自身宿主）
let ESSENTIAL_PROCS: Set<String> = [
    "Finder", "Dock", "SystemUIServer", "WindowServer", "loginwindow", "launchd",
    "kernel_task", "UserEventAgent", "cfprefsd", "distnoted", "opendirectoryd",
    "coreaudiod", "powerd", "logd", "notifyd", "diskarbitrationd", "configd",
    "mds", "mdworker", "Spotlight", "fontd", "ATSServer", "iconservicesd",
    "iconservicesagent", "ControlCenter", "NotificationCenter", "Terminal",
    "iTerm2", "securityd", "trustd", "tccd", "containermanagerd", "AudioComponentRegistrar",
    "com.apple.Terminal", "zsh", "bash", "sh", "login", "sshd", "tailspind",
    "syspolicyd", "symptomsd", "dasd", "backupd", "cloudd", "bird",
    "claude", "Claude", "Claude Helper", "osascript", "sfltool", "du", "top",
    "ghostty", "Ghostty", "彻底卸载",
    "cloudphotod", "photolibraryd", "nsurlsessiond", "mds_stores", "corespotlightd",
    "XProtect", "XProtectPluginService", "remotepairingd", "sharingd",
]

// ==================== 系统清理：采集与执行 ====================

extension AppViewModel {

    // ---------- 统计信息 ----------
    nonisolated static func gatherStats() -> SysStats {
        // CPU：top 第 2 次采样才准（第 1 次是开机以来均值）
        var cpuBusy = 0.0
        let (_, cpuData, _) = runProcessT("/usr/bin/top", ["-l", "2", "-n", "0", "-s", "1", "-stats", "cpu"], 12)
        let cpuOut = String(data: cpuData, encoding: .utf8) ?? ""
        let usageLines = cpuOut.components(separatedBy: "\n").filter { $0.contains("CPU usage") }
        if let last = usageLines.last,
           let rx = try? NSRegularExpression(pattern: #"([\d.]+)%\s*idle"#),
           let m = rx.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)),
           let rr = Range(m.range(at: 1), in: last) {
            cpuBusy = max(0, 100 - (Double(last[rr]) ?? 100))
        }
        // 内存：memory_pressure 空闲百分比 + sysctl 总量
        var freePct = 50
        let (_, mpData, _) = runProcessT("/usr/bin/memory_pressure", [], 5)
        let mpOut = String(data: mpData, encoding: .utf8) ?? ""
        if let r = mpOut.range(of: #"free percentage: (\d+)%"#, options: .regularExpression) {
            freePct = Int(mpOut[r].dropLast(1).filter(\.isNumber)) ?? 50
        }
        var memTotal = 0.0
        let (_, hwData, _) = runProcessT("/usr/sbin/sysctl", ["-n", "hw.memsize"], 3)
        if let bytes = Double(String(data: hwData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            memTotal = bytes / 1073741824.0
        }
        let memUsed = memTotal * Double(100 - freePct) / 100.0
        // 磁盘
        var dFree = 0.0, dTotal = 0.0
        let (_, dfData, _) = runProcessT("/bin/df", ["-k", "/"], 3)
        let dfLines = String(data: dfData, encoding: .utf8)?.components(separatedBy: "\n") ?? []
        if dfLines.count > 1 {
            let f = dfLines[1].split(separator: " ", omittingEmptySubsequences: true)
            if f.count > 3 {
                dTotal = (Double(f[1]) ?? 0) / 1048576.0
                dFree = (Double(f[3]) ?? 0) / 1048576.0
            }
        }
        return SysStats(cpuBusy: cpuBusy, memUsedGB: memUsed, memTotalGB: memTotal,
                        memFreePct: freePct, diskFreeGB: dFree, diskTotalGB: dTotal)
    }

    // ---------- 带超时的进程执行（云盘占位文件会把 du/find 挂死在 0% CPU，必须超时熔断） ----------
    nonisolated static func runProcessT(_ launch: String, _ args: [String], _ timeout: Double) -> (Int32, Data, Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data(), false) }
        // 读出与等待必须并发：输出超过 64KB 管道缓冲会写满阻塞，进程永不退出——
        // 先等退出再读会把 ps 这类大输出静默截断（高 pid 行全丢）
        var out = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            out = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        let exitDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); exitDone.signal() }
        let timedOut = exitDone.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.15)
            if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
        }
        _ = readDone.wait(timeout: .now() + 2)
        return (p.terminationStatus, out, timedOut)
    }

    nonisolated static func duKBT(_ path: String, _ timeout: Double) -> Int {
        let (rc, d, to) = runProcessT("/usr/bin/du", ["-sk", path], timeout)
        guard !to, rc == 0 else { return -1 }
        let str = String(data: d, encoding: .utf8) ?? ""
        return Int(str.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
    }

    // ---------- 进程快照 ----------
    struct PSRow { let pid: Int; let ppid: Int; let uid: Int; let cpu: Double; let rssKB: Int; let stat: String; let comm: String; let lstart: String; let cpuSec: Double }
    nonisolated static func parseCPUTime(_ t: String) -> Double {
        // ps time 格式：[[dd-]hh:]mm:ss[.cc]
        var days = 0.0, rest = t
        if let dash = rest.firstIndex(of: "-") { days = Double(rest[..<dash]) ?? 0; rest = String(rest[rest.index(after: dash)...]) }
        let segs = rest.split(separator: ":").map(String.init)
        var sec = 0.0
        for seg in segs { sec = sec * 60 + (Double(seg) ?? 0) }
        return days * 86400 + sec
    }
    nonisolated static func snapshotPS() -> [Int: PSRow] {
        // 字段序：pid ppid uid %cpu rss stat lstart(5 段) time comm（comm 兜底含空格）
        let (_, d, to) = runProcessT("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,%cpu=,rss=,stat=,lstart=,time=,comm="], 8)
        if to { fputs("[系统清理] 警告: ps 快照超时，进程表可能不完整\n", stderr) }
        var out: [Int: PSRow] = [:]
        for line in (String(data: d, encoding: .utf8) ?? "").components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let parts = t.split(separator: " ", maxSplits: 12, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 13, let pid = Int(parts[0]), let ppid = Int(parts[1]),
                  let uid = Int(parts[2]), let cpu = Double(parts[3]), let rss = Int(parts[4]) else { continue }
            out[pid] = PSRow(pid: pid, ppid: ppid, uid: uid, cpu: cpu, rssKB: rss, stat: parts[5],
                             comm: parts[12], lstart: parts[6...10].joined(separator: " "),
                             cpuSec: parseCPUTime(parts[11]))
        }
        return out
    }

    nonisolated static func ancestorPids() -> Set<Int> {
        var set = Set<Int>([Int(getpid())])
        var cur = Int(getppid())
        let table = snapshotPS()
        var hops = 0
        while cur > 1 && hops < 32 {
            if !set.insert(cur).inserted { break }
            cur = table[cur]?.ppid ?? 1
            hops += 1
        }
        return set
    }

    // ---------- 主扫描 ----------
    func scanSystem() {
        guard !sysScanning, !sysCleaning else { return }
        sysScanning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let home = NSHomeDirectory()
            // 1) 统计
            let stats = AppViewModel.gatherStats()
            // 2) 进程（双采样定持续高 CPU）
            let ps1 = AppViewModel.snapshotPS()
            Thread.sleep(forTimeInterval: 2.0)
            let ps2 = AppViewModel.snapshotPS()
            let anc = AppViewModel.ancestorPids()
            let selfUid = 501
            // launchctl 注册 pid（孤儿进程判定）
            let (_, lcData, _) = AppViewModel.runProcessT("/bin/launchctl", ["list"], 5)
            var launchdPids = Set<Int>()
            for line in (String(data: lcData, encoding: .utf8) ?? "").components(separatedBy: "\n").dropFirst() {
                let f = line.split(separator: "\t", omittingEmptySubsequences: true).map(String.init)
                if let p = Int(f.first ?? "") { launchdPids.insert(p) }
            }
            // 在跑应用名令牌（缓存归属判定）：从 comm 里的 *.app 路径提取应用名，
            // 兼容 bid 命名的缓存目录（com.tinyspeck.slackmacgap 由 "slack" 命中）
            var appTokens = Set<String>()
            if let appRx = try? NSRegularExpression(pattern: #"\/Applications\/[^\/]+\.app"#) {
                for r in ps2.values {
                    let range = NSRange(r.comm.startIndex..., in: r.comm)
                    if let m = appRx.firstMatch(in: r.comm, range: range), let rr = Range(m.range, in: r.comm) {
                        var nm = String(r.comm[rr])
                        nm = nm.replacingOccurrences(of: ".app", with: "").components(separatedBy: "/").last ?? ""
                        let low = nm.lowercased()
                        if low.count >= 3 { appTokens.insert(low) }
                        for seg in low.components(separatedBy: " ") where seg.count >= 4 { appTokens.insert(seg) }
                    }
                }
            }
            func ownerRunning(_ dirName: String) -> Bool {
                let low = dirName.lowercased()
                return appTokens.contains { low.contains($0) || (low.count >= 4 && $0.count >= 4 && $0.contains(low)) }
            }

            var procs: [CleanProc] = []
            for (pid, r2) in ps2 {
                guard pid > 1, r2.uid == selfUid, !anc.contains(pid) else { continue }
                let base = URL(fileURLWithPath: r2.comm).lastPathComponent
                if isProtected(r2.comm) || isProtected(base) { continue }
                let baseLow = base.lowercased()
                if baseLow.contains("crashpad") || baseLow.contains("crash_handler") || baseLow.contains("crashreporter") { continue }
                let isSystemPath = r2.comm.hasPrefix("/System/") || r2.comm.hasPrefix("/usr/") || r2.comm.hasPrefix("/bin/") || r2.comm.hasPrefix("/sbin/") || r2.comm.hasPrefix("/Library/Apple/")
                let essential = ESSENTIAL_PROCS.contains(base) || ESSENTIAL_PROCS.contains(r2.comm)
                // 裸名 comm（无路径斜杠）一律按系统进程对待：只提示不杀
                let killable = r2.comm.hasPrefix("/") && !isSystemPath && !essential && !r2.stat.contains("Z")
                var reasons: [String] = []
                if r2.stat.contains("Z") { reasons.append("僵尸进程（等父进程回收，杀不掉）") }
                if r2.stat.contains("U") { reasons.append("疑似卡死（不可中断等待）") }
                if let r1 = ps1[pid] {
                    let recent = (r2.cpuSec - r1.cpuSec) / 2.0 * 100   // 2 秒窗口内的真实占用
                    if recent > 50 { reasons.append(String(format: "持续高 CPU %.0f%%", recent)) }
                }
                if r2.rssKB > 1500 * 1024 { reasons.append(String(format: "高内存 %.1f GB", Double(r2.rssKB) / 1048576.0)) }
                if r2.ppid == 1, !launchdPids.contains(pid), !r2.comm.contains(".appex/"), !r2.comm.contains(".xpc/"),
                   r2.comm.hasPrefix("/Users/") || r2.comm.hasPrefix("/Applications/") || r2.comm.hasPrefix("/opt/homebrew") {
                    reasons.append("孤儿进程（父进程已退出）")
                }
                guard !reasons.isEmpty else { continue }
                procs.append(CleanProc(pid: pid, ppid: r2.ppid, name: base, cmd: r2.comm, lstart: r2.lstart,
                                       cpu: r2.cpu, memMB: Double(r2.rssKB) / 1024.0,
                                       reason: reasons.joined(separator: "；"), killable: killable && reasons.allSatisfy { !$0.hasPrefix("僵尸") && !$0.hasPrefix("疑似卡死") }))
            }
            procs.sort { ($0.memMB + $0.cpu * 20) > ($1.memMB + $1.cpu * 20) }
            if procs.count > 30 { procs = Array(procs.prefix(30)) }

            // 3) 磁盘项
            var items: [CleanItem] = []
            var defUnchecked = Set<String>()
            var skipped = 0
            func duTop(_ dir: String, _ thresholdKB: Int, _ group: String, _ note: String, _ excludeApple: Bool) {
                let kids = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                for k in kids {
                    if isProtected(k) { continue }                                        // 公司组件硬保护：不列出（LarkShell 等）
                    if excludeApple && (k.hasPrefix("com.apple.") || ["GeoServices", "CloudKit", "icloud", "Family"].contains(k)) { continue }
                    let path = dir + "/" + k
                    let kb = AppViewModel.duKBT(path, 6)                                  // 云盘占位挂死 → 6s 熔断跳过
                    if kb < 0 { skipped += 1; continue }
                    guard kb >= thresholdKB else { continue }
                    items.append(CleanItem(path: path, kb: kb, group: group, note: note))
                    if ownerRunning(k) { defUnchecked.insert(path) }                      // 属主在跑：默认不勾
                }
            }
            duTop(home + "/Library/Caches", 51200, CG_CACHE, "可再生缓存", true)
            duTop(home + "/Library/Logs", 10240, CG_LOG, "日志可再生", false)

            // 开发者缓存白名单（路径, 说明, 默认勾选）
            let devCands: [(String, String, Bool)] = [
                (home + "/Library/Developer/Xcode/DerivedData", "编译产物，可安全重建", true),
                (home + "/Library/Developer/Xcode/iOS DeviceSupport", "设备符号缓存，重连自动生成", true),
                (home + "/Library/Developer/CoreSimulator/Caches", "模拟器缓存", true),
                (home + "/Library/Caches/org.swift.swiftpm", "SwiftPM 缓存", true),
                (home + "/.npm/_cacache", "npm 包缓存，自动重建", true),
                (home + "/.cache/pip", "pip 缓存", true),
                (home + "/Library/Caches/pip", "pip 缓存", true),
                (home + "/go/pkg/mod/cache", "Go 模块下载缓存", true),
                (home + "/.cache/uv", "uv 包缓存，自动重建", true),
                (home + "/Library/Caches/node-gyp", "node 原生模块编译缓存", true),
                (home + "/.cocoapods", "CocoaPods 仓库缓存（重新克隆较慢）", false),
                (home + "/.gradle/caches", "Gradle 缓存（重新下载较慢）", false),
                (home + "/.m2/repository", "Maven 本地仓库（重新下载慢）", false),
                (home + "/Library/Developer/Xcode/Archives", "打包归档——你的构建产物", false),
            ]
            var devList = devCands
            if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
                let (_, bd, _) = AppViewModel.runProcessT("/opt/homebrew/bin/brew", ["--cache"], 8)
                let bp = String(data: bd, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !bp.isEmpty { devList.append((bp, "Homebrew 下载缓存", true)) }
            }
            for (path, note, defChecked) in devList {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if items.contains(where: { $0.path == path }) { continue }   // 与 Caches 扫描去重
                if isProtected(path) { continue }
                let kb = AppViewModel.duKBT(path, 20)
                if kb < 0 { skipped += 1; continue }
                guard kb >= 10240 else { continue }
                items.append(CleanItem(path: path, kb: kb, group: CG_DEV, note: note))
                if !defChecked { defUnchecked.insert(path) }
            }

            // 废纸篓（默认不勾——可能含有刚卸载的 App，清空不可恢复）
            let trashKB = AppViewModel.duKBT(home + "/.Trash", 20)
            if trashKB >= 10240 {
                items.append(CleanItem(path: home + "/.Trash", kb: trashKB, group: CG_TRASH,
                                       note: "内含最近删除的文件，清空后不可恢复"))
                defUnchecked.insert(home + "/.Trash")
            }

            // 大文件 >500MB（用户数据，全部默认不勾）
            let bigDirs = ["Downloads", "Desktop", "Documents", "Movies"]
            // POSIX 包/资源库扩展名：find 会把它们当普通目录穿透，列出内部组件文件——必须跳过
            let bundleExts: Set<String> = ["app", "appex", "framework", "bundle", "plugin", "kext", "prefpane",
                                           "qlgenerator", "saver", "wdgt", "xcodeproj", "xcworkspace", "playground",
                                           "photoslibrary", "fcpbundle", "logicx", "imovielibrary", "tvlibrary",
                                           "musiclibrary", "pkg", "mpkg", "sparsebundle", "sparseimage"]
            func insideBundle(_ path: String) -> Bool {
                for comp in path.split(separator: "/") {
                    if let dot = comp.lastIndex(of: "."),
                       bundleExts.contains(String(comp[comp.index(after: dot)...]).lowercased()) { return true }
                }
                return false
            }
            var bigs: [(String, Int)] = []
            for d0 in bigDirs {
                let dir = home + "/" + d0
                // -x：不跨文件系统（防穿透挂载到家目录的网络卷——那种删除不进废纸篓）
                let (_, d, _) = AppViewModel.runProcessT("/usr/bin/find", [dir, "-x", "-type", "f", "-size", "+500M", "-print0"], 30)
                for p in (String(data: d, encoding: .utf8) ?? "").components(separatedBy: "\0") {
                    guard !p.isEmpty, !isProtected(p), !insideBundle(p) else { continue }
                    let kbb = AppViewModel.duKBT(p, 8)
                    if kbb > 0 { bigs.append((p, kbb)) }
                }
            }
            bigs.sort { $0.1 > $1.1 }
            for (p, kb) in bigs.prefix(20) {
                items.append(CleanItem(path: p, kb: kb, group: CG_BIG, note: "用户文件，删除进废纸篓"))
                defUnchecked.insert(p)
            }

            await MainActor.run {
                guard let self else { return }
                self.sysStats = stats
                self.sysProcs = procs
                self.sysItems = items
                self.sysSkipped = skipped
                self.sysUncheckedPaths = defUnchecked
                self.sysCheckedPids = []
                self.sysScanning = false
                self.sysScannedOnce = true
            }
        }
    }

    // ---------- 勾选辅助 ----------
    var sysGroups: [String] {
        var order: [String] = []
        for g in [CG_PROC, CG_CACHE, CG_LOG, CG_DEV, CG_TRASH, CG_BIG] {
            let has = (g == CG_PROC) ? !sysProcs.isEmpty : sysItems.contains { $0.group == g }
            if has { order.append(g) }
        }
        return order
    }
    func sysGroupItems(_ g: String) -> [CleanItem] { sysItems.filter { $0.group == g } }
    var sysCheckedKB: Int { sysItems.filter { !sysUncheckedPaths.contains($0.path) }.reduce(0) { $0 + $1.kb } }
    func sysGroupChecked(_ g: String) -> Bool {
        if g == CG_PROC { return !sysProcs.isEmpty && sysProcs.filter(\.killable).allSatisfy { sysCheckedPids.contains($0.pid) } && !sysProcs.filter(\.killable).isEmpty }
        let its = sysGroupItems(g)
        return !its.isEmpty && its.allSatisfy { !sysUncheckedPaths.contains($0.path) }
    }
    func sysToggleGroup(_ g: String) {
        if g == CG_PROC {
            let killables = sysProcs.filter(\.killable).map(\.pid)
            if sysGroupChecked(g) { killables.forEach { sysCheckedPids.remove($0) } }
            else { killables.forEach { sysCheckedPids.insert($0) } }
            return
        }
        let paths = sysGroupItems(g).map(\.path)
        if sysGroupChecked(g) { paths.forEach { sysUncheckedPaths.insert($0) } }
        else { paths.forEach { sysUncheckedPaths.remove($0) } }
    }

    // ---------- 执行清理 ----------
    func cleanSystem() {
        guard !sysCleaning, !sysScanning else { return }
        sysCleaning = true
        let killList = sysProcs.filter { sysCheckedPids.contains($0.pid) && $0.killable }
        // 废纸篓排最前：先清空，后 trash 的缓存项留在篓里仍可恢复（否则同轮被永久删除）
        let fileList = sysItems.filter { !sysUncheckedPaths.contains($0.path) }
            .sorted { ($0.group == CG_TRASH ? 0 : 1) < ($1.group == CG_TRASH ? 0 : 1) }
        Task.detached(priority: .userInitiated) { [weak self] in
            var killed = 0, killFailed = 0, freedKB = 0, failed = 0
            // 1) 进程：终止前二次核验——uid + 可执行路径 + 启动时间（防 pid 复用误杀）+ 状态（U/Z 不杀）
            for p in killList {
                let (_, d, _) = AppViewModel.runProcessT("/bin/ps", ["-p", "\(p.pid)", "-o", "uid=,stat=,lstart=,comm="], 5)
                let line = (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // 字段：uid(1) stat(1) lstart(5) comm(其余)
                let f = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
                guard f.count == 8 else { killFailed += 1; continue }
                let uid = f[0], stat = f[1], lstart = f[2...6].joined(separator: " "), comm = f[7]
                guard uid == "501", comm == p.cmd, lstart == p.lstart,
                      !stat.contains("Z"), !stat.contains("U"), !isProtected(comm) else { killFailed += 1; continue }
                if Darwin.kill(pid_t(p.pid), SIGTERM) == 0 { killed += 1 } else { killFailed += 1 }
            }
            // 2) 文件：trashItem 进废纸篓；废纸篓组 = 枚举子项彻底删除（勾选时已明示不可恢复）
            var protectedInTrash = 0
            var trashEmptied = false
            for it in fileList {
                if it.group == CG_TRASH {
                    let kids = (try? FileManager.default.contentsOfDirectory(atPath: it.path)) ?? []
                    for k in kids {
                        // 公司组件就算在废纸篓里也永不动（可能含 Lark/Defender 等被删数据）
                        if isProtected(k) { protectedInTrash += 1; continue }
                        do {
                            try FileManager.default.removeItem(atPath: it.path + "/" + k)
                            freedKB += it.kb / max(kids.count, 1)
                        } catch { failed += 1 }
                    }
                    let left = (try? FileManager.default.contentsOfDirectory(atPath: it.path)) ?? []
                    trashEmptied = left.isEmpty
                    continue
                }
                do {
                    _ = try FileManager.default.trashItem(at: URL(fileURLWithPath: it.path), resultingItemURL: nil)
                    freedKB += it.kb
                } catch { failed += 1 }
            }
            let stats = AppViewModel.gatherStats()
            await MainActor.run {
                guard let self else { return }
                self.sysCleaning = false
                self.sysStats = stats
                // 清掉已处理项，保留未勾/失败项
                var donePaths = Set(fileList.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
                if trashEmptied { donePaths.insert(NSHomeDirectory() + "/.Trash") }
                self.sysItems = self.sysItems.filter { !donePaths.contains($0.path) }
                let donePids = Set(killList.filter { Darwin.kill(pid_t($0.pid), 0) != 0 }.map(\.pid))
                self.sysProcs = self.sysProcs.filter { !donePids.contains($0.pid) }
                self.sysCheckedPids = []
                self.alertTitle = "清理完成"
                var msg = "已释放 \(fmtKB(freedKB)) 磁盘"
                if killed > 0 { msg += "，终止 \(killed) 个异常进程" }
                if failed > 0 || killFailed > 0 { msg += "\n\(failed + killFailed) 项未能处理（已跳过）" }
                if protectedInTrash > 0 { msg += "\n废纸篓中 \(protectedInTrash) 个公司组件项按保护策略保留" }
                msg += "\n建议过 1 分钟再点一次扫描查看最新状态。"
                self.alertMessage = msg
                self.showAlert = true
            }
        }
    }
}

// ==================== 系统清理：界面 ====================

struct SystemCleanMiddle: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("系统清理").font(.system(size: 19, weight: .bold))
                    Text("CPU · 内存 · 磁盘 一键体检").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.scanSystem() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(model.sysScanning || model.sysCleaning)
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 10)
            HSep()

            if let st = model.sysStats {
                VStack(spacing: 8) {
                    StatBar(icon: "cpu", label: "CPU", value: String(format: "%.0f%%", st.cpuBusy),
                            frac: st.cpuBusy / 100, tint: st.cpuBusy > 80 ? .red : (st.cpuBusy > 50 ? .orange : .green))
                    StatBar(icon: "memorychip", label: "内存",
                            value: String(format: "%.0f/%.0f GB", st.memUsedGB, st.memTotalGB),
                            frac: st.memTotalGB > 0 ? st.memUsedGB / st.memTotalGB : 0,
                            tint: st.memFreePct < 10 ? .red : (st.memFreePct < 20 ? .orange : .green))
                    StatBar(icon: "internaldrive", label: "磁盘可用",
                            value: String(format: "%.0f GB", st.diskFreeGB),
                            frac: st.diskTotalGB > 0 ? st.diskFreeGB / st.diskTotalGB : 0,
                            tint: st.diskFreeGB < 20 ? .red : .green)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(GROUP_BG, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            if model.sysScanning {
                Spacer()
                ProgressView("正在体检…（约 10 秒）").controlSize(.regular)
                Spacer()
            } else if !model.sysScannedOnce {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "speedometer").font(.system(size: 34)).foregroundStyle(ACCENT2)
                    Text("点击 ↻ 开始系统体检").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.sysGroups, id: \.self) { g in
                            CleanCatRow(group: g)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .onAppear {
            if !model.sysScannedOnce && !model.sysScanning { model.scanSystem() }
        }
    }
}

struct StatBar: View {
    let icon: String
    let label: String
    let value: String
    let frac: Double
    let tint: Color
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(ACCENT2).frame(width: 16)
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.08)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(tint)
                        .frame(width: max(4, geo.size.width * min(max(frac, 0), 1)), height: 6)
                }
            }
            .frame(height: 6)
            Text(value).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }
}

struct CleanCatRow: View {
    @EnvironmentObject var model: AppViewModel
    let group: String
    var body: some View {
        let isProc = group == CG_PROC
        let count = isProc ? model.sysProcs.count : model.sysGroupItems(group).count
        let kb = isProc ? 0 : model.sysGroupItems(group).reduce(0) { $0 + $1.kb }
        let icon = isProc ? "exclamationmark.triangle.fill"
            : group == CG_CACHE ? "archivebox.fill"
            : group == CG_LOG ? "doc.text.fill"
            : group == CG_DEV ? "hammer.fill"
            : group == CG_TRASH ? "trash.fill" : "doc.fill"
        let tint: Color = isProc ? .orange : (group == CG_TRASH || group == CG_BIG ? .red : FOLDER_BLUE)
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 20)
            Text(group).font(.system(size: 12.5, weight: .medium))
            Spacer()
            Text(isProc ? "\(count) 个" : "\(count) 项 · \(fmtKB(kb))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

// ---------- 详情栏 ----------

struct SystemCleanDetail: View {
    @EnvironmentObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.sysScanning {
                Spacer()
                ProgressView().controlSize(.large)
                Text("正在扫描系统…").font(.headline).padding(.top, 10)
                Spacer()
            } else if !model.sysScannedOnce {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 64)).foregroundStyle(ACCENT2)
                    Text("系统体检").font(.system(size: 22, weight: .bold))
                    Text("扫描异常进程（高 CPU / 高内存 / 孤儿 / 卡死）\n与磁盘赘肉（缓存 / 日志 / 开发缓存 / 大文件），\n确认后一键恢复最佳状态。")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button { model.scanSystem() } label: {
                        Label("开始体检", systemImage: "stethoscope")
                            .frame(width: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ACCENT2)
                    .controlSize(.large)
                }
                Spacer()
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("体检结果").font(.system(size: 19, weight: .bold))
                        Text("危险项默认不勾选 · 公司组件与系统进程不出现在清单"
                            + (model.sysSkipped > 0 ? " · \(model.sysSkipped) 项云占位读取超时已跳过" : ""))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("预计释放 \(fmtKB(model.sysCheckedKB))")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(ACCENT2)
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 10)
                HSep()
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.sysGroups, id: \.self) { g in
                            if g == CG_PROC {
                                CleanProcGroupView()
                            } else {
                                CleanFileGroupView(group: g)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                HSep()
                HStack {
                    Button("全不选") { model.sysUncheckedPaths = Set(model.sysItems.map(\.path)); model.sysCheckedPids = [] }
                        .buttonStyle(.borderless).font(.system(size: 12))
                    Spacer()
                    Button { model.confirmSysClean = true } label: {
                        Text("一键清理").frame(width: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ACCENT2)
                    .disabled(model.sysCheckedKB == 0 && model.sysCheckedPids.isEmpty || model.sysCleaning)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CleanFileGroupView: View {
    @EnvironmentObject var model: AppViewModel
    let group: String
    private var key: String { "sys:" + group }

    var body: some View {
        let items = model.sysGroupItems(group)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { model.sysGroupChecked(group) },
                    set: { _ in model.sysToggleGroup(group) }))
                .toggleStyle(.checkbox).labelsHidden()
                Image(systemName: model.isCollapsed(key) ? "chevron.right" : "chevron.down")
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
            .onTapGesture { model.toggleCollapsed(key) }
            if !model.isCollapsed(key) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { !model.sysUncheckedPaths.contains(item.path) },
                                set: { on in
                                    if on { model.sysUncheckedPaths.remove(item.path) }
                                    else { model.sysUncheckedPaths.insert(item.path) }
                                }))
                            .toggleStyle(.checkbox).labelsHidden()
                            Image(systemName: group == CG_TRASH ? "trash.fill" : (group == CG_BIG ? "doc.fill" : "folder.fill"))
                                .font(.system(size: 11))
                                .foregroundStyle(group == CG_TRASH || group == CG_BIG ? .red : FOLDER_BLUE)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                    .font(.system(size: 12)).lineLimit(1)
                                Text(item.note.isEmpty ? item.path : item.note + " · " + item.path)
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(fmtKB(item.kb)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        if item.id != items.last?.id { HSep().padding(.leading, 36) }
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

struct CleanProcGroupView: View {
    @EnvironmentObject var model: AppViewModel
    private let key = "sys:proc"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { model.sysGroupChecked(CG_PROC) },
                    set: { _ in model.sysToggleGroup(CG_PROC) }))
                .toggleStyle(.checkbox).labelsHidden()
                Image(systemName: model.isCollapsed(key) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text(CG_PROC).font(.system(size: 12.5, weight: .semibold))
                Text("默认不勾选 · 终止前请确认对应应用无未保存内容").font(.system(size: 9.5)).foregroundStyle(.orange)
                Spacer()
                Text("\(model.sysProcs.count) 个").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(GROUP_BG, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCollapsed(key) }
            if !model.isCollapsed(key) {
                VStack(spacing: 0) {
                    ForEach(model.sysProcs) { p in
                        HStack(spacing: 8) {
                            if p.killable {
                                Toggle("", isOn: Binding(
                                    get: { model.sysCheckedPids.contains(p.pid) },
                                    set: { on in
                                        if on { model.sysCheckedPids.insert(p.pid) }
                                        else { model.sysCheckedPids.remove(p.pid) }
                                    }))
                                .toggleStyle(.checkbox).labelsHidden()
                            } else {
                                Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                                    .frame(width: 14)
                            }
                            Image(systemName: p.killable ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(p.killable ? .orange : .blue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(p.name)  ·  pid \(p.pid)").font(.system(size: 12)).lineLimit(1)
                                Text(p.reason).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                if p.cpu > 1 { Text(String(format: "CPU %.0f%%", p.cpu)).font(.system(size: 10)).foregroundStyle(.secondary) }
                                if p.memMB > 1 { Text(String(format: "%.0f MB", p.memMB)).font(.system(size: 10)).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        if p.id != model.sysProcs.last?.id { HSep().padding(.leading, 36) }
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}
