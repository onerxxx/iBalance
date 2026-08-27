// UpdateService.swift — GitHub Releases 自更新（检查 + 下载 + 校验 + 退出前 spawn sh 替换重启）
//
// 链路（照抄 cockpit 模式自研，非 Sparkle）：
//   GET api.github.com/.../releases/latest → 比对版本 → URLSession 下载 zip
//   → SHA256 校验 → codesign --verify 校验 → ditto 解压并把新 app 放到目标同卷同级的隐藏目录
//   → spawn 独立 sh（sleep 等待退出 → mv 新旧互换 → open）→ NSApp.terminate
//
// 关键约束：
//   • URLSession 落盘的文件不带 quarantine 属性 → 重启的新 app 不触发 Gatekeeper，
//     固定自签（iBalance Local Sign）保证 TCC 授权与登录项跨版本不重置。
//   • 替换必须发生在「退出之后」：运行中的 bundle 可被改名/删除但不可原地覆盖写。
//   • sha256 来源：release asset 的 digest 字段（GitHub 服务端计算），缺失则拒绝安装。

import AppKit
import CryptoKit

// MARK: - 数据模型

struct ReleaseInfo {
    /// tag 名（如 "v2026.8.27.1"）
    var tag: String
    /// release 正文（弹窗展示更新说明用）
    var notes: String
    /// 唯一 .zip asset 的下载地址
    var zipURL: URL
    /// 发布端写入的 zip SHA256（hex 小写；来自 asset.digest 或正文 "SHA256:" 行）
    var expectedSHA256: String

    var version: String { Self.version(ofTag: tag) }

    static func version(ofTag tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}

enum UpdateError: LocalizedError {
    case http(Int)
    case noZipAsset
    case noChecksum
    case checksumMismatch(expected: String, actual: String)
    case codeSignFailed(String)
    case stageCopyFailed

    var errorDescription: String? {
        switch self {
        case .http(let code):
            if code == 0 { return "网络连接失败，请稍后重试。" }
            return code == 404
                ? "Releases 不可访问（HTTP 404）。私有仓库需先转为公开，否则无法匿名拉取。"
                : "网络请求失败（HTTP \(code)）"
        case .noZipAsset:
            return "Release 中没有找到 .zip 安装包"
        case .noChecksum:
            return "发布包缺少 SHA256 校验值"
        case .checksumMismatch(let e, let a):
            return "下载包校验失败\n期望 \(e.prefix(16))…\n实际 \(a.prefix(16))…"
        case .codeSignFailed(let detail):
            return "新版签名校验未通过：\(detail)"
        case .stageCopyFailed:
            return "无法将新版暂存到应用同级目录（权限不足）"
        }
    }
}

// MARK: - 服务

enum UpdateService {

    private static let repoAPI = "https://api.github.com/repos/onerxxx/iBalance/releases/latest"

    /// 自更新专用会话：默认配置的资源级超时约等于无限（idle 计时对 CDN 滴流不断重置），
    /// 必须给硬顶，否则下载环节悬挂时 UI 侧表现为「点了没反应、无窗口无进程反馈」
    private static let updateSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30      // 单次请求空闲上限（连接建立/两段数据间隔）
        cfg.timeoutIntervalForResource = 120    // 整个传输总时长硬顶：到点抛 URLError.timedOut
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: 版本

    /// 当前完整版本号（CFBundleVersion = YYYY.M.D.N；dev 直跑无 plist 时返回 "0" 恒小于远端）
    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// 数值逐段比较（"2026.8.27.2" > "2026.8.27.1"；段数不等时短段补 0）
    static func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    // MARK: 检查

    /// 拉取最新 Release 信息；404 报 .http(404)（提示仓库转公开）
    static func fetchLatestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: repoAPI) else { throw UpdateError.http(0) }
        let (data, code) = await HTTP.request(
            url: url,
            headers: ["Accept": "application/vnd.github+json"],
            timeout: 15)
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] else {
            throw UpdateError.http(code == 0 ? 0 : code)
        }
        guard let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]],
              let zip = assets.first(where: { (($0["name"] as? String)?.hasSuffix(".zip") ?? false)
                                            || (($0["browser_download_url"] as? String)?.hasSuffix(".zip") ?? false) }),
              let zipStr = zip["browser_download_url"] as? String,
              let zipURL = URL(string: zipStr) else {
            throw UpdateError.noZipAsset
        }
        // 校验和优先取 GitHub 服务端计算的 asset.digest（"sha256:hex"），回退发布时写进正文的行
        var expected = ((zip["digest"] as? String)?.split(separator: ":").last).map(String.init)
        if expected?.count != 64 {
            expected = findSHA(in: (obj["body"] as? String) ?? "")
        }
        guard var sha = expected, sha.count == 64 else { throw UpdateError.noChecksum }
        sha = sha.lowercased()
        Logger.log(.refresh, "[update] latest=\(tag) sha=\(sha.prefix(12))…")
        return ReleaseInfo(tag: tag,
                           notes: (obj["body"] as? String) ?? "",
                           zipURL: zipURL,
                           expectedSHA256: sha)
    }

    /// 从 release 正文中提取 "SHA256: <64位hex>" 行的哈希
    private static func findSHA(in body: String) -> String? {
        for line in body.split(separator: "\n") where line.lowercased().contains("sha256") {
            if let range = line.range(of: #"[A-Fa-f0-9]{64}"#, options: .regularExpression) {
                return String(line[range])
            }
        }
        return nil
    }

    // MARK: 下载 + 校验 + 暂存

    /// 把新版暂存到「目标 bundle 同级」的隐藏目录（与旧 app 同卷，后续纯 rename 原子互换）。
    /// 返回暂存后的新 app URL。全流程任一校验失败即抛错并清理现场。
    @discardableResult
    static func prepareAndStage(_ rel: ReleaseInfo,
                                progress: ((Double) -> Void)? = nil) async throws -> URL {
        // 目标位置：当前 bundle 所在目录（兼容 /Applications 与任意用户目录安装）
        let dstDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let dstName = Bundle.main.bundleURL.lastPathComponent          // "iBalance.app"
        let stagedURL = dstDir.appendingPathComponent("." + dstName + ".update.new")

        try cleanup([stagedURL])
        defer { try? cleanup([stagedParentTmp()]) }

        // 1) 下载（流式累计回调进度）
        let data = try await download(rel.zipURL, progress: progress)

        // 2) 完整性校验
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == rel.expectedSHA256.lowercased() else {
            Logger.log(.refresh, "[update] checksum mismatch: expect=\(rel.expectedSHA256.prefix(12))… actual=\(actual.prefix(12))…")
            throw UpdateError.checksumMismatch(expected: rel.expectedSHA256, actual: actual)
        }

        // 3) 写临时目录并解压
        let tmpRoot = stagedParentTmp()
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let zipFile = tmpRoot.appendingPathComponent("ibalance.zip")
        try data.write(to: zipFile, options: .atomic)
        let extractDir = tmpRoot.appendingPathComponent("extracted")
        try runProcess("/usr/bin/ditto", ["-x", "-k", zipFile.path, extractDir.path])
        var newApp = extractDir.appendingPathComponent(dstName)
        if !FileManager.default.fileExists(atPath: newApp.path) {
            // 兼容 zip 根下不是直接放 iBalance.app 的打包方式：找唯一 .app
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: extractDir.path)) ?? []
            guard let first = contents.first(where: { $0.hasSuffix(".app") }) else { throw UpdateError.noZipAsset }
            newApp = extractDir.appendingPathComponent(first)
        }

        // 4) 签名有效性校验（bundle 完整、结构未被篡改）；身份一致性由发版流水线固定同一张证书保证
        do {
            try runProcess("/usr/bin/codesign",
                           ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw UpdateError.codeSignFailed(error.localizedDescription)
        }

        // 5) 校验通过 → 复制到目标同卷同级（ditto 保留扩展属性/结构；cp -c APFS clone 秒级）
        do {
            try runProcess("/usr/bin/ditto", [newApp.path, stagedURL.path])
        } catch {
            try? cleanup([stagedURL])   // 半成品残留会挡住下次 mv，就地清理
            Logger.log(.refresh, "[update] stage copy failed: \(error.localizedDescription)")
            throw UpdateError.stageCopyFailed
        }
        try? cleanup([tmpRoot])
        Logger.log(.refresh, "[update] staged at \(stagedURL.path)")
        return stagedURL
    }

    // MARK: 替换重启

    /// 写独立 sh 并 spawn 后调用 terminate：sh sleep 等进程退净 → mv 新旧互换 → open。
    /// 同卷 rename 保证即使失败也能把 PREV 还原回去。
    static func installAndRestart(stagedURL: URL) throws {
        let dst = Bundle.main.bundleURL
        let prevURL = dst.deletingLastPathComponent().appendingPathComponent("." + dst.lastPathComponent + ".update.prev")
        // 等待循环 + 兜底强杀（借鉴 build.sh）：open 同名 bundle 若遇存活旧实例只会激活它，
        // 导致看似升级成功实则跑旧二进制；先确保 pgrep 干净再 open。
        let script = """
        #!/bin/sh
        DST='\(dst.path)'
        STAGED='\(stagedURL.path)'
        PREV='\(prevURL.path)'
        sleep 1
        rm -rf "$PREV"
        mv "$DST" "$PREV" || exit 1
        mv "$STAGED" "$DST" || { mv "$PREV" "$DST"; exit 1; }
        i=0
        while pgrep -x iBalance >/dev/null 2>&1; do
            [ $i -ge 8 ] && break
            sleep 0.5
            i=$((i+1))
        done
        pkill -9 -x iBalance 2>/dev/null || true
        sleep 0.3
        rm -rf "$PREV"
        open "$DST"
        """
        let shFile = NSTemporaryDirectory().appending("ibalance_update.sh")
        try script.write(toFile: shFile, atomically: true, encoding: .utf8)
        // sh 进程在父进程 terminate 后继续存活（posix_spawn 独立进程，无需 daemon）
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [shFile]
        Logger.log(.refresh, "[update] spawning swap script, restarting…")
        try p.run()
        NSApp.terminate(nil)
    }

    // MARK: 私有工具

    private static func download(_ url: URL, progress: ((Double) -> Void)?) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        let (bytes, resp) = try await updateSession.bytes(for: req)
        let total = resp.expectedContentLength   // GitHub 附件带 Content-Length
        var data = Data(capacity: total > 0 ? Int(total) : 1 << 20)
        var lastReported = 0.0
        for try await byte in bytes {
            data.append(byte)
            if total > 0, let cb = progress {
                let frac = Double(data.count) / Double(total)
                if frac - lastReported >= 0.05 {   // 每 5% 回调一次，避免高频跨线程调度
                    lastReported = frac
                    cb(frac)
                }
            }
        }
        progress?(1.0)
        Logger.log(.refresh, "[update] downloaded \(data.count / 1024)KB from \(url.host ?? "")")
        return data
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: out, encoding: .utf8) ?? ""
            throw NSError(domain: "UpdateService.process", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(launchPath) exit \(p.terminationStatus): \(msg.suffix(300))"])
        }
        return String(data: out, encoding: .utf8) ?? ""
    }

    /// 暂存工作区固定挂在目标同级（保证同卷 rename），zip 解压等中间产物再套一层
    private static func stagedParentTmp() -> URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".ibalance.update.work")
    }

    private static func cleanup(_ urls: [URL]) throws {
        for u in urls where FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }
}
