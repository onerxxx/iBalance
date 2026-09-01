// UpdateService.swift — GitHub Releases 自更新（连通性探测 + 多源回退 + 断点续传 + 校验 + 自替换重启）
//
// ─── 本文件速查（只写「去哪找」，不写行号——行号必漂移）─────────────────────────
// 进度模型   UpdateStage / UpdateStepState / UpdateProgress / UpdateReporter（含 isCancelled 轮询）
// 数据模型   ReleaseInfo（zipURLs = 按优先级排列的下载候选）/ DownloadCandidate / UpdateError
// 连通性     probeConnectivity()（NWPath 瞬时判定 + 真实 HEAD 探测取往返延迟）
// 版本检查   fetchLatestRelease(reporter:) → MetadataSource：先 .api（asset.digest + 两下载源）
//            失败回退 .atom（releases.atom 取 tag/正文 SHA256 + expanded_assets 取资产名）
// 下载       downloadTo(candidates:dest:reporter:) → DownloadBox（delegate + resumeData 断点续传）
// 校验暂存   prepareAndStage(rel:reporter:)（SHA256 → ditto 解压 → codesign → 暂存到应用同级）
// 替换重启   installAndRestart(stagedURL:)（spawn sh 等退出后 mv 互换 + open）
// 工具       sha256(ofFile:) / byteText() / runProcess() / stagedParentTmp() / cleanup()
//
// ⚠️ 回退链条：检查 API 源失败 → atom 源；下载单源失败 → resumeData 续传（≤3 次）→ 换备用 URL
//    （github.com 直链 → api.github.com 资产端点）→ 全部失败抛错，旧 bundle 原样不动。
//    UI 侧失败态给「重试 / 手动下载页 / 关闭」三个出口（见 UpdateProgressWindow.swift）。
//    URLSession 落盘文件不带 quarantine → 重启不触发 Gatekeeper；替换必须发生在退出之后。

import AppKit
import CryptoKit

// MARK: - 进度上报

enum UpdateStage: Hashable {
    case probe      // 网络连通性探测
    case fetch      // 拉取版本信息
    case download   // 下载安装包
    case verify     // 校验（SHA256 + 解压 + 签名）
    case stage      // 暂存到应用同级
    case install    // 替换并重启
}

enum UpdateStepState: Hashable {
    case pending, active, done, failed
}

struct UpdateProgress {
    var stage: UpdateStage
    var state: UpdateStepState
    /// 0…1；nil = 该阶段无量化进度（UI 走 indeterminate）
    var fraction: Double? = nil
    /// 明细文案（如 "1.4 MB / 2.2 MB · 380 KB/s"）
    var detail: String = ""
    var received: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0
}

/// 进度上报通道。report 由 URLSession delegate 队列调用（非主线程），消费方自行切主线程；
/// isCancelled 供下载循环轮询退出（跨线程读，实现方用锁保护）。
struct UpdateReporter {
    var report: (UpdateProgress) -> Void
    var isCancelled: () -> Bool
}

// MARK: - 数据模型

/// 一个下载候选源（同一份 zip 的不同取法，用于网络受阻时换路）
struct DownloadCandidate {
    var url: URL
    var headers: [String: String] = [:]
    /// 日志/UI 里区分当前用的哪个源
    var label: String { url.host ?? url.absoluteString }
}

struct ReleaseInfo {
    var tag: String
    var notes: String
    /// 按优先级排列的下载候选：前一个源彻底失败（重试耗尽）才切下一个
    var zipURLs: [DownloadCandidate]
    var assetName: String
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
    case offline
    case cancelled
    /// 落盘大小与 Content-Length 不符（续传拼接异常）→ 清掉重下
    case incomplete(expected: Int64, actual: Int64)
    /// 所有元数据源都失败（携带逐源失败原因）
    case allSourcesFailed([String])

    var errorDescription: String? {
        switch self {
        case .http(let code):
            if code == 0 { return "网络连接失败，请稍后重试。" }
            if code == 403 { return "GitHub 接口限流（HTTP 403）。请稍后重试。" }
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
        case .offline:
            return "网络不可用，无法连接 GitHub。请检查网络后重试。"
        case .cancelled:
            return "已取消更新"
        case .incomplete(let e, let a):
            return "下载不完整（期望 \(UpdateService.byteText(e))，实际 \(UpdateService.byteText(a))）"
        case .allSourcesFailed(let reasons):
            return "所有更新源均不可用：\n" + reasons.map { "• \($0)" }.joined(separator: "\n")
        }
    }
}

/// 下载被中断且可能带续传数据（内部错误，供重试循环取 resumeData）
private struct DownloadInterrupted: Error {
    let underlying: Error
    let resumeData: Data?
}

// MARK: - 服务

enum UpdateService {

    private static let repo = "onerxxx/iBalance"
    private static let apiLatest = "https://api.github.com/repos/\(repo)/releases/latest"
    private static let atomURL = "https://github.com/\(repo)/releases.atom"
    private static let webRoot = "https://github.com/\(repo)"

    /// GitHub API 对无 User-Agent 的请求按 administrative rules 直接 403；
    /// 走系统代理时出口 IP 若为共享节点还可能撞匿名限流（atom 兜底即为此设计）
    private static let userAgent = "iBalance-Updater"

    /// Releases 页面（失败态「手动下载」出口）
    static let releasesPage = "https://github.com/\(repo)/releases/latest"

    /// 单个下载源的最大尝试次数（含首次）；失败优先用 resumeData 续传
    private static let maxAttemptsPerSource = 3
    /// 退避基数：第 n 次重试等待 n × 基数 秒
    private static let retryBackoff: TimeInterval = 1.5
    /// 空闲上限（两段数据之间）：到点 URLSession 抛 timedOut → 走续传重试
    private static let idleTimeout: TimeInterval = 20
    /// 整个传输总时长硬顶
    private static let totalTimeout: TimeInterval = 300

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

    // MARK: 连通性

    /// 真实探测：依次 HEAD api.github.com / github.com，返回首个连通者的往返延迟(ms)。
    /// NWPath 只能说明「有网」，说明不了 GitHub 是否可达（代理/墙场景必须真发一次请求）。
    static func probeConnectivity(timeout: TimeInterval = 6) async -> (online: Bool, latencyMs: Int) {
        for host in ["https://api.github.com/", "https://github.com/"] {
            guard let url = URL(string: host) else { continue }
            let t0 = Date()
            let (_, code) = await HTTP.request(url: url, method: "HEAD",
                                               headers: ["User-Agent": userAgent], timeout: timeout)
            if code != 0 { return (true, Int(Date().timeIntervalSince(t0) * 1000)) }
            Logger.log(.refresh, "[update] probe \(host) unreachable")
        }
        return (false, 0)
    }

    // MARK: 检查

    /// 拉取最新 Release 信息。链路：连通性探测 → 元数据源（API → atom 回退）→ 组装下载候选
    static func fetchLatestRelease(reporter: UpdateReporter? = nil) async throws -> ReleaseInfo {
        // ① 网络连通性：先 NWPath 瞬时判定（离线立即反馈，不必白等超时），再真实探测取延迟
        reporter?.report(UpdateProgress(stage: .probe, state: .active, detail: "正在检测网络…"))
        let pathOnline = await MainActor.run { NetworkMonitor.shared.isOnline }
        let (online, latency) = pathOnline ? await probeConnectivity() : (false, 0)
        guard online else {
            reporter?.report(UpdateProgress(stage: .probe, state: .failed, detail: "网络不可用"))
            throw UpdateError.offline
        }
        reporter?.report(UpdateProgress(stage: .probe, state: .done, detail: "已连通 · 延迟 \(latency)ms"))

        // ② 版本信息：API 源优先，失败回退 atom（仍走 github.com，不引入第三方镜像）
        reporter?.report(UpdateProgress(stage: .fetch, state: .active, detail: "正在获取版本信息…"))
        var failures: [String] = []
        var rel: ReleaseInfo?
        for source in MetadataSource.allCases {
            do {
                rel = try await source.fetch()
                break
            } catch {
                Logger.log(.refresh, "[update] metadata via \(source.label) failed: \(error.localizedDescription)")
                failures.append("\(source.label)：\(error.localizedDescription)")
            }
        }
        guard let rel else {
            reporter?.report(UpdateProgress(stage: .fetch, state: .failed, detail: "所有源均不可用"))
            throw UpdateError.allSourcesFailed(failures)
        }
        reporter?.report(UpdateProgress(stage: .fetch, state: .done, detail: "v\(rel.version)"))
        Logger.log(.refresh, "[update] latest=\(rel.tag) sha=\(rel.expectedSHA256.prefix(12))… "
                   + "sources=\(rel.zipURLs.map(\.label).joined(separator: ","))")
        return rel
    }

    /// 元数据源：API 带结构化 asset.digest 与资产 id（可构造第二个下载源）；
    /// atom 是 API 被限流/不可达时的同源兜底。
    private enum MetadataSource: CaseIterable {
        case api, atom

        var label: String {
            switch self { case .api: return "GitHub API"; case .atom: return "Releases 订阅源" }
        }

        func fetch() async throws -> ReleaseInfo {
            switch self {
            case .api:  return try await fetchFromAPI()
            case .atom: return try await fetchFromAtom()
            }
        }
    }

    private static func fetchFromAPI() async throws -> ReleaseInfo {
        guard let url = URL(string: apiLatest) else { throw UpdateError.http(0) }
        let (data, code) = await HTTP.request(url: url,
                                              headers: ["Accept": "application/vnd.github+json",
                                                        "User-Agent": userAgent],
                                              timeout: 15)
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] else {
            throw UpdateError.http(code == 0 ? 0 : code)
        }
        guard let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]],
              let zip = assets.first(where: { (($0["name"] as? String)?.hasSuffix(".zip") ?? false)
                                            || (($0["browser_download_url"] as? String)?.hasSuffix(".zip") ?? false) }),
              let name = zip["name"] as? String,
              let zipStr = zip["browser_download_url"] as? String,
              let zipURL = URL(string: zipStr) else {
            throw UpdateError.noZipAsset
        }

        // 候选 1：browser_download_url（github.com → 302 到 release-assets CDN）
        // 候选 2：API 资产端点（api.github.com + octet-stream 才返回二进制）——与候选 1 不同主机，
        //         DNS/代理只挡其中一路时仍可下载
        var candidates = [DownloadCandidate(url: zipURL)]
        let assetID = zip["id"] as? Int ?? (zip["id"] as? NSNumber)?.intValue
        if let assetID,
           let apiAsset = URL(string: "https://api.github.com/repos/\(repo)/releases/assets/\(assetID)") {
            candidates.append(DownloadCandidate(url: apiAsset,
                                                headers: ["Accept": "application/octet-stream"]))
        }

        // 校验和优先取 GitHub 服务端计算的 asset.digest（"sha256:hex"），回退正文 "SHA256:" 行
        var expected = ((zip["digest"] as? String)?.split(separator: ":").last).map(String.init)
        if expected?.count != 64 { expected = findSHA(in: (obj["body"] as? String) ?? "") }
        guard var sha = expected, sha.count == 64 else { throw UpdateError.noChecksum }
        sha = sha.lowercased()
        return ReleaseInfo(tag: tag,
                           notes: (obj["body"] as? String) ?? "",
                           zipURLs: candidates,
                           assetName: name,
                           expectedSHA256: sha)
    }

    /// atom 兜底：releases.atom 拿最新 tag 与正文（含 SHA256 行），
    /// expanded_assets 页面拿资产名，再拼出 github.com 直链。
    /// ⚠️ 走系统代理时 API 源可能撞共享出口 IP 的匿名限流（403）——atom 走 github.com
    ///    网页端不受 API 限流影响，正是为此设计的兜底。
    private static func fetchFromAtom() async throws -> ReleaseInfo {
        guard let atom = URL(string: atomURL) else { throw UpdateError.http(0) }
        let (data, code) = await HTTP.request(url: atom,
                                              headers: ["User-Agent": userAgent],
                                              timeout: 15)
        guard code == 200, let xml = String(data: data ?? Data(), encoding: .utf8) else {
            throw UpdateError.http(code == 0 ? 0 : code)
        }
        // ⚠️ capture() 默认取第 1 捕获组——pattern 必须带括号，否则恒 nil（历史 bug：
        //    无组导致 atom 兜底永远抛 noZipAsset，API 限流时两源全灭）
        guard let entry = capture(in: xml, pattern: "(<entry>.*?</entry>)") else { throw UpdateError.noZipAsset }
        let tag = capture(in: entry, pattern: #"<id>tag:github\.com,2008:Repository/\d+/([^<]+)</id>"#)
            ?? capture(in: entry, pattern: "<title>([^<]+)</title>")
        guard let tag else { throw UpdateError.noZipAsset }

        let content = capture(in: entry, pattern: "<content[^>]*>(.*?)</content>") ?? ""
        guard let sha = capture(in: content, pattern: #"(?i)sha256[^A-Fa-f0-9]{0,12}([A-Fa-f0-9]{64})"#) else {
            throw UpdateError.noChecksum
        }

        guard let listURL = URL(string: "\(webRoot)/releases/expanded_assets/\(tag)") else { throw UpdateError.noZipAsset }
        let (listData, listCode) = await HTTP.request(url: listURL,
                                                      headers: ["User-Agent": userAgent],
                                                      timeout: 15)
        guard listCode == 200, let html = String(data: listData ?? Data(), encoding: .utf8) else {
            throw UpdateError.http(listCode == 0 ? 0 : listCode)
        }
        // 注意：expanded_assets 同时含源码归档（/archive/refs/tags/…zip），只认 releases/download
        guard let path = capture(in: html, pattern: #"href="(/[^"]*?/releases/download/[^"]+\.zip)""#),
              let zipURL = URL(string: webRoot + path) else { throw UpdateError.noZipAsset }
        let name = (path as NSString).lastPathComponent
        return ReleaseInfo(tag: tag,
                           notes: plainText(fromHTML: content),
                           zipURLs: [DownloadCandidate(url: zipURL)],
                           assetName: name,
                           expectedSHA256: sha.lowercased())
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

    // MARK: 下载（多源 + 断点续传）

    /// 依次尝试每个下载源；单源内失败优先用 resumeData 续传，次数耗尽才换源。
    /// 换源时丢弃上一源的续传数据与半成品（resumeData 与目标响应绑定，跨源无效）。
    static func downloadTo(candidates: [DownloadCandidate],
                           destURL: URL,
                           reporter: UpdateReporter?) async throws {
        var lastError: Error = UpdateError.http(0)
        for cand in candidates {
            var resume: Data? = nil
            for attempt in 0..<maxAttemptsPerSource {
                if reporter?.isCancelled() == true { throw UpdateError.cancelled }
                if attempt > 0 {
                    let wait = retryBackoff * Double(attempt)
                    Logger.log(.refresh, "[update] retry #\(attempt) via \(cand.label) after \(wait)s"
                               + (resume != nil ? " (resume \(resume!.count)B)" : ""))
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                do {
                    try await downloadOnce(cand, resumeData: resume, destURL: destURL, reporter: reporter)
                    let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                    Logger.log(.refresh, "[update] downloaded \(byteText(size)) from \(cand.label)")
                    return
                } catch UpdateError.cancelled {
                    throw UpdateError.cancelled
                } catch let di as DownloadInterrupted {
                    lastError = di.underlying
                    resume = di.resumeData
                    Logger.log(.refresh, "[update] \(cand.label) attempt \(attempt + 1) failed: "
                               + "\(di.underlying.localizedDescription) resume=\(di.resumeData?.count ?? 0)B")
                    if case UpdateError.incomplete = di.underlying {
                        // 续传拼接出了残缺文件：清掉从头再来，避免带着坏数据反复续
                        resume = nil
                        try? FileManager.default.removeItem(at: destURL)
                    }
                } catch {
                    lastError = error
                }
            }
            resume = nil
            try? FileManager.default.removeItem(at: destURL)
        }
        throw lastError
    }

    private static func downloadOnce(_ cand: DownloadCandidate,
                                     resumeData: Data?,
                                     destURL: URL,
                                     reporter: UpdateReporter?) async throws {
        var req = URLRequest(url: cand.url, timeoutInterval: idleTimeout)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in cand.headers { req.setValue(v, forHTTPHeaderField: k) }

        let box = DownloadBox(destURL: destURL,
                              isCancelled: { reporter?.isCancelled() ?? false }) { written, total, speed in
            reporter?.report(UpdateProgress(
                stage: .download,
                state: .active,
                fraction: total > 0 ? min(1, Double(written) / Double(total)) : nil,
                detail: total > 0
                    ? "\(byteText(written)) / \(byteText(total)) · \(byteText(Int64(speed)))/s"
                    : "已下载 \(byteText(written))",
                received: written,
                total: total,
                bytesPerSecond: speed))
        }
        let session = URLSession(configuration: makeDownloadConfig(), delegate: box, delegateQueue: nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            box.continuation = c
            let task = resumeData != nil
                ? session.downloadTask(withResumeData: resumeData!)
                : session.downloadTask(with: req)
            box.task = task
            task.resume()
        }
        session.finishTasksAndInvalidate()
    }

    private static func makeDownloadConfig() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = idleTimeout
        cfg.timeoutIntervalForResource = totalTimeout
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpMaximumConnectionsPerHost = 1
        return cfg
    }

    /// 下载任务委托：进度节流上报 + 落盘 + 抓取 resumeData（供后续尝试续传）+ 取消响应
    private final class DownloadBox: NSObject, URLSessionDownloadDelegate {
        let destURL: URL
        let isCancelled: () -> Bool
        let onProgress: (Int64, Int64, Double) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        var task: URLSessionDownloadTask?
        var resumeData: Data?
        var moveError: Error?
        var resumeOffset: Int64 = 0
        var expectedTotal: Int64 = 0
        var lastSample = (time: Date(), bytes: Int64(0))
        var lastReport = Date.distantPast
        var speed: Double = 0

        init(destURL: URL,
             isCancelled: @escaping () -> Bool,
             onProgress: @escaping (Int64, Int64, Double) -> Void) {
            self.destURL = destURL
            self.isCancelled = isCancelled
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { expectedTotal = totalBytesExpectedToWrite }
            let now = Date()
            let dt = now.timeIntervalSince(lastSample.time)
            if dt >= 0.5 {
                speed = Double(totalBytesWritten - lastSample.bytes) / dt
                lastSample = (now, totalBytesWritten)
            }
            if isCancelled() { downloadTask.cancel(); return }
            // 节流：delegate 回调可达每秒上百次，UI 只需 ~12Hz
            guard now.timeIntervalSince(lastReport) >= 0.08
                    || (expectedTotal > 0 && resumeOffset + totalBytesWritten >= expectedTotal) else { return }
            lastReport = now
            onProgress(resumeOffset + totalBytesWritten, expectedTotal, speed)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
            resumeOffset = fileOffset
            expectedTotal = max(expectedTotalBytes, fileOffset)
            lastSample = (Date(), 0)
            Logger.log(.refresh, "[update] resumed at \(byteText(fileOffset)) / \(byteText(expectedTotalBytes))")
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                let attrs = try? FileManager.default.attributesOfItem(atPath: location.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                // 续传拼接异常会产出大小不符的文件：就地判定，交给重试循环清掉重下
                if expectedTotal > 0 && size != expectedTotal {
                    moveError = UpdateError.incomplete(expected: expectedTotal, actual: size)
                    return
                }
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: destURL)
                resumeData = nil
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let ns = error as NSError? {
                if let rd = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData = rd }
                if isCancelled() { finish(.failure(UpdateError.cancelled)); return }
            }
            if let moveError { finish(.failure(moveError)); return }
            if let error { finish(.failure(DownloadInterrupted(underlying: error, resumeData: resumeData))); return }
            finish(.success(()))
        }

        private func finish(_ result: Result<Void, Error>) {
            let c = continuation
            continuation = nil
            switch result {
            case .success:        c?.resume()
            case .failure(let e): c?.resume(throwing: e)
            }
        }
    }

    // MARK: 校验 + 暂存

    /// 把新版暂存到「目标 bundle 同级」的隐藏目录（与旧 app 同卷，后续纯 rename 原子互换）。
    /// 返回暂存后的新 app URL。全流程任一校验失败即抛错并清理现场（旧 bundle 不受影响）。
    @discardableResult
    static func prepareAndStage(_ rel: ReleaseInfo,
                                reporter: UpdateReporter? = nil) async throws -> URL {
        let dstDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let dstName = Bundle.main.bundleURL.lastPathComponent          // "iBalance.app"
        let stagedURL = dstDir.appendingPathComponent("." + dstName + ".update.new")
        let tmpRoot = stagedParentTmp()

        try cleanup([stagedURL])
        defer { try? cleanup([tmpRoot]) }

        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let zipFile = tmpRoot.appendingPathComponent("ibalance.zip")

        // 1) 下载（多源 + 续传 + 重试）
        try await downloadTo(candidates: rel.zipURLs, destURL: zipFile, reporter: reporter)
        try throwIfCancelled(reporter, cleanup: [stagedURL])

        // 2) 完整性校验（流式读文件，不整包进内存）
        reporter?.report(UpdateProgress(stage: .verify, state: .active, detail: "正在校验安装包…"))
        let actual = try sha256(ofFile: zipFile)
        guard actual == rel.expectedSHA256.lowercased() else {
            Logger.log(.refresh, "[update] checksum mismatch: expect=\(rel.expectedSHA256.prefix(12))… "
                       + "actual=\(actual.prefix(12))…")
            try? FileManager.default.removeItem(at: zipFile)
            reporter?.report(UpdateProgress(stage: .verify, state: .failed, detail: "校验未通过"))
            throw UpdateError.checksumMismatch(expected: rel.expectedSHA256, actual: actual)
        }
        let zipSize = (try? FileManager.default.attributesOfItem(atPath: zipFile.path)[.size] as? NSNumber)?.int64Value ?? 0
        reporter?.report(UpdateProgress(stage: .verify, state: .active,
                                        detail: "校验通过 · \(byteText(zipSize))，正在解压…"))

        // 3) 解压
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
            try runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw UpdateError.codeSignFailed(error.localizedDescription)
        }
        reporter?.report(UpdateProgress(stage: .verify, state: .done, detail: "签名校验通过"))

        // 5) 校验通过 → 复制到目标同卷同级（ditto 保留扩展属性/结构）
        reporter?.report(UpdateProgress(stage: .stage, state: .active, detail: "正在准备替换…"))
        do {
            try runProcess("/usr/bin/ditto", [newApp.path, stagedURL.path])
        } catch {
            try? cleanup([stagedURL])   // 半成品残留会挡住下次 mv，就地清理
            Logger.log(.refresh, "[update] stage copy failed: \(error.localizedDescription)")
            throw UpdateError.stageCopyFailed
        }
        reporter?.report(UpdateProgress(stage: .stage, state: .done, detail: "已就绪"))
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

    private static func throwIfCancelled(_ reporter: UpdateReporter?, cleanup urls: [URL]) throws {
        if reporter?.isCancelled() == true {
            try? cleanup(urls)
            throw UpdateError.cancelled
        }
    }

    private static func sha256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func byteText(_ bytes: Int64) -> String {
        let v = Double(max(0, bytes))
        if v < 1024 { return "\(max(0, bytes)) B" }
        if v < 1024 * 1024 { return String(format: "%.0f KB", v / 1024) }
        return String(format: "%.1f MB", v / 1024 / 1024)
    }

    /// 正则取捕获组（默认第 1 组）
    private static func capture(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    /// atom 正文是 HTML 转义串，去标签转纯文本后供弹窗展示更新说明
    private static func plainText(fromHTML html: String) -> String {
        var s = html
        // &amp; 必须最后替换，否则会二次解码出新的实体
        for (from, to) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                           ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
