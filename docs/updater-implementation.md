# iBalance 自更新方案（参照 Cockpit Tools 静态 Manifest 模式）

> 结论先行：照抄 cockpit 的「远程 manifest → 版本比较 → 下载 → 校验 → 自替换重启」四段式，用纯 AppKit + CryptoKit 自研（不引入 Sparkle）。核心难点只有一个——**私有仓库的远程源访问**，其余都有现成可搬的代码和实测过的命令。

---

## 1. 为什么不用 Sparkle

Sparkle 2 功能齐全（appcast / EdDSA 签名 / 跳过版本 / 进度 / 重启），但有两个与 iBalance 现状冲突的点：

1. iBalance 是 `swiftc` 单目录直编，无 Xcode 工程、无 SPM。引 Sparkle 要拉 framework 进仓库或重构构建链，打破 `build.sh` 现状。
2. cockpit 这套模式去掉 Tauri 壳之后，核心就是「检查 JSON + 下载 + 自替换」，Swift 里一个模块 + DialogShell 弹窗即可复刻，与全自研单文件结构、最小改动惯用法完全一致。cockpit 的 `linux_updater.rs` 正是绕开官方插件自己做的，证明这条路走得通。

版本号是日期式（`2026.8.13.1`，4 段），cockpit 的逐段版本比较逻辑通用，无需改。

---

## 2. Cockpit 机制回顾（参照物）

**流程图**

```
发布侧（CI）                           App 侧（运行时）
┌─────────────────────┐              ┌──────────────────────────────┐
│ build → 打包 .app     │              │ 启动/定时 → 拉 latest.json     │
│ → Ed25519 签名 zip    │  ──上传──▶   │  → 版本比较（旧<新才继续）       │
│ → 生成 latest.json     │  GitHub     │  → 是否到检查间隔 / 跳过该版本？ │
│ → gh release create   │  Releases   │  → 下载 zip → Ed25519 验签     │
└─────────────────────┘              │  → 解压 → spawn sh 搬运+重启   │
                                     └──────────────────────────────┘
```

**manifest 格式**（cockpit 的 `latest-target.json` 简化版，单个 `latest.json` 即可，iBalance 只有 macOS arm64 一个目标）：

```json
{
  "version": "2026.8.26.3",
  "notes": "## 新增\n- xxx\n\n## 修复\n- yyy",
  "pub_date": "2026-08-26T12:00:00Z",
  "url": "https://github.com/onerxxx/iBalance/releases/download/v2026.8.26.3/iBalance-v2026.8.26.3.zip",
  "signature": "base64(64字节 raw Ed25519)"
}
```

关键点：`signature` 是对 **下载的 zip 原文** 做 Ed25519 签名后的 base64（不是解压后内容）；`url` 指向 release 资产。App 拉 manifest 后先比版本号，确认更高再下载验签。

cockpit 的 `update_checker.rs` 额外做三件我们也要做的事：存 `last_check_time` 控制检查频率、存 `skipped_version` 支持「跳过此版本」、存 `last_run_version` 检测「本次启动是从旧版升上来的」以弹更新日志。

---

## 3. iBalance 的关键适配决策

### 3.1 远程源 & 私有仓库 token（最大障碍）

cockpit 是公开仓库，`releases/latest/download/...` 匿名可访问。iBalance 是私有仓库（`github.com/onerxxx/iBalance`），**匿名请求 release 资产会 404**。三条路：

| 方案 | 优点 | 缺点 |
|---|---|---|
| **A. 私有仓库 + 内嵌只读 PAT**（推荐） | 最小改动，接现有 GitHub 仓库 | token 嵌进二进制；若被泄露可读 release。用 fine-grained PAT 限制到**只读该仓库 release 权限**，走 `Authorization: Bearer <PAT>` 头 |
| B. 私有仓库 + 机器上 `gh` 认证 | token 不进 app | app 运行时依赖 `gh` 在 PATH + 已登录，菜单栏工具不可接受 |
| C. 拉到公开渠道（gist / 对象存储 / 公开托管 latest.json） | 匿名可读、无 token 风险 | 多维护一处静态托管 |

本文按 **方案 A** 写。token 从环境变量或编译期常量注入 `Updater.accessToken`，请求头带 `Authorization: Bearer`。若你决定公开托管，把 `Updater.manifestURL` 与 `url` 指向公开地址、`accessToken` 留空即可。

### 3.2 校验：Ed25519（已实测）

- 签名：`openssl pkeyutl -sign -rawin -inkey priv.pem -in 包 -out sig`，输出 64 字节 raw 签名。
- 验签：App 用 CryptoKit `Curve25519.Signing.PublicKey(rawRepresentation: 32字节)`.`isValidSignature(64字节签名, for: 包数据)`。CryptoKit 的原生 raw 表示与 openssl 的 Ed25519 raw 完全对齐，无需中间转换。
- 私钥只在发布机持有；公钥 32 字节以 base64 内置进 App，用于运行时验签。**私钥绝不入库**（放项目外，或加进 `.gitignore`）。

实测命令（已验证可用，openssl 3.6.3）：

```bash
# 生成密钥对（发布机一次性执行，私钥放项目外）
openssl genpkey -algorithm ed25519 -out /Users/onerchen/.ibalance/updater_priv.pem
openssl pkey -pubin -in /Users/onerchen/.ibalance/updater_pub.pem ... # 见下

# 导出公钥 raw 32 字节（从公钥 PEM → DER SPKI → 末尾 32 字节）
openssl pkey -in priv.pem -pubout -out pub.pem
openssl pkey -pubin -in pub.pem -pubout -outform DER | tail -c 32 | base64
# → 这段 base64 就是 PubKey，内置进 App

# 对 zip 签名（产出 64 字节 raw 签名 → base64）
openssl pkeyutl -sign -rawin -inkey priv.pem -in iBalance.zip -out sig.bin
base64 < sig.bin

# 验签（发布脚本自检用）
openssl pkeyutl -verify -rawin -pubin -inkey pub.pem -in iBalance.zip -sigfile sig.bin
# → "Signature Verified Successfully"
```

### 3.3 自替换流程

运行中的 app 不能替换自己。标准做法（linux_updater 思路）：**退出前 spawn 一个搬运脚本，脚本独立于本进程存活，sleep 后搬移并拉起新 app**。

iBalance 当前从项目根目录跑（`build.sh` 产物在 `iBalance.app`），用户目录可写。替换脚本核心：

```sh
#!/bin/sh
sleep 1                       # 给本进程退出留时间
src="<解压出 iBalance.app>"
dst="<Bundle.main.bundlePath>"   # 运行中 app 的完整路径
rm -rf "$dst"
mv "$src" "$dst"
open "$dst"
```

**脱离父进程存活**：用 `Process` 启动 `/bin/sh -c 'nohup sh <替换脚本> >/dev/null 2>&1 &'`。App 是 GUI 进程无控制终端，`nohup` + `&` 让 sh 被孤儿化后由 launchd 收养，不受 SIGHUP 影响。具体要真机验证（见 §8）。

### 3.4 签名身份必须保持

`build.sh` 已用固定自签证书 `iBalance Local Sign`（identifier `com.local.ibalance`）防 TCC 重置。**新包必须用同一身份签名**，否则升级后「完全磁盘访问」等授权会掉。发布链路沿用 `build.sh --release` 的签名命令即可，别换证书。

### 3.5 quarantine

app 用 URLSession 自己下载的 zip，**不会被系统加 quarantine 属性**（Gatekeeper 只拦外部应用下载的），解压出的 `.app` 直接可运行，无需 `xattr -dr com.apple.quarantine`。这点比浏览器下载省事。

---

## 4. App 侧实现：`swift/Updater.swift`

新增单文件，风格对齐现有代码（`@MainActor`、中文注释、复用 `HTTP` / `AppDataStore` / `Logger`）。构建脚本已自动收集 `swift/` 下所有 `.swift`，无需改 `build.sh` 的源文件清单。

```swift
// Updater.swift — 自更新：拉 manifest → 版本比较 → 下载 zip → Ed25519 验签 → 自替换重启
// 参照 cockpit-tools 的 update_checker + linux_updater 思路，纯 AppKit + CryptoKit 自研
import Foundation
import CryptoKit

// MARK: - 更新设置（存 UserDefaults，键走 UDKey 收口）

extension UDKey {
    static var updateAutoCheck: String { "updater_auto_check" }
    static var updateLastCheckTime: String { "updater_last_check_time" }     // Double: 上次检查时间戳
    static var updateSkippedVersion: String { "updater_skipped_version" }    // 用户跳过的版本
    static var updateLastRunVersion: String { "updater_last_run_version" }   // 上次成功运行版本
    static var updatePendingNotesVersion: String { "updater_pending_notes_version" }
    static var updatePendingNotes: String { "updater_pending_notes" }        // 下载时存下，升级后弹 changelog
    static var updateIntervalHours: String { "updater_interval_hours" }      // 检查间隔，默认 1h
}

// MARK: - Manifest 与设置结构

/// 远程 manifest（与 cockpit 的 latest.json 同构）
struct UpdateManifest: Decodable {
    let version: String
    let notes: String
    let pub_date: String
    let url: String
    let signature: String      // base64(64 字节 raw Ed25519 签名)
}

/// 更新结果，供 Panel/弹窗展示
struct UpdateCheckResult {
    let hasUpdate: Bool
    let latestVersion: String?
    let notes: String?
    let downloadURL: String?
    let signature: String?
}

// MARK: - 更新器主逻辑

enum Updater {
    // ⚠️ 私有仓库 release 资产匿名 404，需带只读 PAT。空串走公开源（方案 C）。
    // 可从环境变量覆盖，便于调试：IB_UPDATER_TOKEN
    static var accessToken: String {
        ProcessInfo.processInfo.environment["IB_UPDATER_TOKEN"]
            ?? ""   // ← 发布时改成编译期注入的只读 fine-grained PAT
    }

    // 远程 manifest 地址。私有仓库方案 A：latest 指向 release 最新资产。
    static var manifestURL: URL {
        URL(string: "https://github.com/onerxxx/iBalance/releases/latest/download/latest.json")!
    }

    /// App 内置的公钥 raw（32 字节 base64）——与发布机私钥配对，绝不改。
    static let pubKeyBase64 = ""
    // ← 填入发布脚本输出的 `base64(openssl ... | tail -c 32)`

    /// 当前运行版本（与 build.sh 写的 CFBundleVersion 一致）
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    // MARK: 版本比较（支持任意段数，如 2026.8.13.1）
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").compactMap { Int($0) } }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x > y { return true }
            if x < y { return false }
        }
        return false
    }

    // MARK: 设置读写
    static func autoCheck() -> Bool {
        UserDefaults.standard.bool(forKey: UDKey.updateAutoCheck)
    }
    static func skippedVersion() -> String {
        UserDefaults.standard.string(forKey: UDKey.updateSkippedVersion) ?? ""
    }

    /// 是否该检查：开启自动检查 + 距上次检查超过间隔
    static func shouldCheck() -> Bool {
        if !autoCheck() { return false }
        let last = UserDefaults.standard.double(forKey: UDKey.updateLastCheckTime)
        let intervalHours = UserDefaults.standard.double(forKey: UDKey.updateIntervalHours)
        let interval = intervalHours > 0 ? intervalHours : 1
        return Date().timeIntervalSince1970 - last >= interval * 3600
    }

    /// 检查完更新 timestamp（由 UI 节点调用，避免手动 + 自动叠加轰炸）
    static func recordCheck() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UDKey.updateLastCheckTime)
    }

    // MARK: 检查更新（async）
    /// 拉 manifest → 比较版本。旧版或跳过版本返回 hasUpdate=false。
    static func check() async -> UpdateCheckResult {
        var headers: [String: String] = [:]
        if !accessToken.isEmpty {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        let (data, code) = await HTTP.request(url: manifestURL,
                                              method: "GET",
                                              headers: headers,
                                              timeout: 10)
        guard code == 200, let data, let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
            Logger.log(.network, "Updater.check: manifest 拉取失败 code=\(code)")
            return UpdateCheckResult(hasUpdate: false, latestVersion: nil,
                                     notes: nil, downloadURL: nil, signature: nil)
        }
        // 跳过该版本 → 忽略
        if !skippedVersion().isEmpty && skippedVersion() == manifest.version {
            return UpdateCheckResult(hasUpdate: false, latestVersion: manifest.version,
                                     notes: nil, downloadURL: nil, signature: nil)
        }
        guard isNewer(manifest.version, than: currentVersion) else {
            return UpdateCheckResult(hasUpdate: false, latestVersion: manifest.version,
                                     notes: nil, downloadURL: nil, signature: nil)
        }
        // 下载前先把 notes 存起来，升级成功后再弹 changelog
        UserDefaults.standard.set(manifest.version, forKey: UDKey.updatePendingNotesVersion)
        UserDefaults.standard.set(manifest.notes, forKey: UDKey.updatePendingNotes)
        return UpdateCheckResult(hasUpdate: true, latestVersion: manifest.version,
                                 notes: manifest.notes,
                                 downloadURL: manifest.url, signature: manifest.signature)
    }

    // MARK: 下载 + 验签 + 自替换
    /// 下载 zip → Ed25519 验签 → 解压 → spawn 搬运脚本 → 退出本进程。
    /// 返回 true 表示已退出；返回 false 表示需 UI 提示失败。
    static func downloadAndInstall(version: String, downloadURL: String, signature: String) async -> Bool {
        var headers: [String: String] = [:]
        if !accessToken.isEmpty {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        guard let url = URL(string: downloadURL) else { return false }
        let (data, code) = await HTTP.request(url: url, method: "GET", headers: headers, timeout: 300)
        guard code == 200, let data else {
            Logger.log(.network, "Updater.download: 下载包失败 code=\(code)")
            return false
        }

        // 1. 验签（对 zip 原文）。公钥/签名均为 raw base64 → CryptoKit
        guard let sigData = Data(base64Encoded: signature),
              let pubData = Data(base64Encoded: pubKeyBase64),
              !pubData.isEmpty,
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
              pubKey.isValidSignature(sigData, for: data) else {
            Logger.log(.error, "Updater.verify: Ed25519 验签失败")
            return false
        }

        // 2. 写到临时目录 + 解压
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ibalance_update_\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let zipPath = tmpDir.appendingPathComponent("iBalance.zip")
        do {
            try data.write(to: zipPath)
        } catch {
            Logger.log(.error, "Updater.write: 写 zip 失败 \(error)")
            return false
        }
        guard unpack(zipPath, to: tmpDir) else {
            Logger.log(.error, "Updater.unpack: 解压失败")
            return false
        }
        // 解压产物是 iBalance.app
        let newApp = tmpDir.appendingPathComponent("iBalance.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            Logger.log(.error, "Updater.unpack: 未找到 iBalance.app")
            return false
        }

        // 3. 生成搬运脚本 + spawn
        let script = replaceScript(newAppPath: newApp.path, currentAppPath: Bundle.main.bundlePath)
        let scriptPath = tmpDir.appendingPathComponent("replace.sh")
        try? script.write(to: scriptPath, atomically: true, encoding: .utf8)

        if !launchReplacement(scriptPath: scriptPath) {
            Logger.log(.error, "Updater.launch: 无法启动搬运脚本")
            return false
        }

        // 4. 退出
        NSApp.terminate(nil)
        return true
    }

    // MARK: 解压（zip → dir）
    private static func unpack(_ zip: URL, to dir: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    // MARK: 搬运脚本（nohup + & 脱离父进程存活）
    private static func replaceScript(newAppPath: String, currentAppPath: String) -> String {
        // 双引号内的 path 用单引号包裹，避免空格破坏 sh
        let src = "'\(newAppPath)'"
        let dst = "'\(currentAppPath)'"
        return """
        #!/bin/sh
        sleep 1
        src=\(src)
        dst=\(dst)
        [ -d "$src" ] || exit 1
        rm -rf "$dst"
        mv "$src" "$dst"
        open "$dst"
        """
    }

    private static func launchReplacement(scriptPath: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup + & + 重定向：保证父进程退出后仍继续执行
        p.arguments = ["-c", "nohup sh '\(scriptPath.path)' >/dev/null 2>&1 &"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.terminationHandler = nil   // 不等待，脚本立即返回让本进程退出
        return true
    }
}
```

> **注意**：`CryptoKit` 在 `-target arm64-apple-macos26` 下可用，无需额外 framework 参数。若真机验签发现 `rawRepresentation` 长度不符，确认发布侧导出的是 **32 字节 raw**（`tail -c 32`）而非 SPKI 全长的 44 字节。

### UDKey 扩展

在 `Config.swift` 的 `UDKey` enum 末尾追加（这段已在上方代码里用 `extension` 给出，也可直接写进 enum）：

```swift
// 更新器（见 Updater.swift）
static var updateAutoCheck: String { "updater_auto_check" }
static var updateLastCheckTime: String { "updater_last_check_time" }
static var updateSkippedVersion: String { "updater_skipped_version" }
static var updateLastRunVersion: String { "updater_last_run_version" }
static var updatePendingNotesVersion: String { "updater_pending_notes_version" }
static var updatePendingNotes: String { "updater_pending_notes" }
static var updateIntervalHours: String { "updater_interval_hours" }
```

---

## 5. 发布侧：`build.sh` 集成 + 上传脚本

### 5.1 `build.sh` 加打包 zip（`--release` 才执行）

在 `build.sh` 末尾（已完成签名、`open` 重启之前）追加 release 分发包生成。避免干扰日常 fast 构建：

```bash
# ---- release 分发包（仅 --release）----
if [[ "$BUILD_MODE" == "release" ]]; then
    echo "==> 生成分发包 iBalance-v${FULL_VER}.zip"
    # 打包整个 .app（含已签名 bundle）；zip 名带上版本号保证 release 资产唯一
    ( cd "$(dirname "$APP_DIR")" && zip -qry "$SCRIPT_DIR/iBalance-v${FULL_VER}.zip" "iBalance.app" )
fi
```

此时 `swift/` 下会多出 `iBalance-v<ver>.zip`（注意别让它被当源文件编译——它非 `.swift`，无影响）。

### 5.2 上传脚本 `swift/release.sh`

独立脚本，发布时执行（保留 `build.sh` 快速循环的干净）：

```bash
#!/bin/bash
# release.sh — 发布新版到 GitHub Releases：
#   build --release → Ed25519 签名 → 生成 latest.json → gh release create
# 用法：./swift/release.sh <可选的 release 说明文件.md>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="onerxxx/iBalance"
PRIV_KEY="/Users/onerchen/.ibalance/updater_priv.pem"   # 项目外，勿入库
NOTES_FILE="${1:-$SCRIPT_DIR/../docs/release-notes.md}"

# 1. 构建
bash "$SCRIPT_DIR/build.sh" --release

# 2. 找产物
ZIP=$(ls -t "$SCRIPT_DIR"/iBalance-v*.zip | head -1)
VER=$(basename "$ZIP" | sed -E 's/iBalance-v(.*)\.zip/\1/')
# 导出公钥 PEM，再读 DER 取 raw 32 字节 → base64
openssl pkey -in "$PRIV_KEY" -pubout -out "$SCRIPT_DIR/pub.pem" 2>/dev/null
pubraw=$(openssl pkey -pubin -in "$SCRIPT_DIR/pub.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
rm -f "$SCRIPT_DIR/pub.pem"   # 公钥本身不敏感，但保持目录干净
echo "==> 版本 v$VER"
echo "    公钥 raw32 = $pubraw"
# 🔴 每次发布后把 pubraw 更新到 Updater.swift 的 pubKeyBase64（首次生成后理论上不变）

# 3. 对 zip 签名（raw Ed25519, 64 字节 → base64）
SIG=$(openssl pkeyutl -sign -rawin -inkey "$PRIV_KEY" -in "$ZIP" 2>/dev/null | base64)

# 4. 写 manifest
NOTES=$(cat "$NOTES_FILE")
URL="https://github.com/$REPO/releases/download/v${VER}/$(basename "$ZIP")"
PUB_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT="$SCRIPT_DIR/latest.json"
python3 - "$VER" "$NOTES" "$PUB_DATE" "$URL" "$SIG" "$OUT" <<'PY'
import json, sys
m = {"version": sys.argv[1], "notes": sys.argv[2],
     "pub_date": sys.argv[3], "url": sys.argv[4], "signature": sys.argv[5]}
json.dump(m, open(sys.argv[6], "w"), indent=2, ensure_ascii=False)
PY
echo "==> 已生成 $OUT"

# 5. 上传（.zip 作 download 资产；latest.json 作更新源资产。私有仓库均匿名 404，靠 App 带 token 读）
gh release create "v$VER" "$ZIP" "$OUT" \
    --repo "$REPO" --title "iBalance v$VER" --notes-file "$NOTES_FILE"
echo "==> 发布完成"
```

**最新指针问题**：`releases/latest/download/latest.json` 始终指向最新非 draft release 的 `latest.json` 资产。每次发新版都上传同名 `latest.json`，旧版覆盖，天然等于「最新」指针。

> 说明：`latest.json` 只需一个目标（macOS arm64）。若日后要 Intel 版，可仿 cockpit 拆 `latest-darwin-aarch64.json` / `latest-darwin-x64.json`，App 侧按 `Bundle.main` 架构选 URL。

---

## 6. 弹窗 UX：复用 DialogShell + 更新日志

新增「检查更新」入口与结果弹窗。**推荐**放「关于 iBalance」弹窗里加一个「检查更新」按钮，或右下菜单加菜单项，避免改面板布局。

```swift
// 检查更新（菜单/按钮调用入口）
func checkForUpdate(_ source: String) {
    log("Updater: 手动检查更新 source=\(source)")
    Task { @MainActor in
        let r = await Updater.check()
        guard r.hasUpdate, let ver = r.latestVersion,
              let url = r.downloadURL, let sig = r.signature else {
            let shell = DialogShell()
            shell.addTitle("已是最新版本")
            shell.addInfo("当前版本 v\(Updater.currentVersion)")
            shell.addButton("知道了", keyEquivalent: "\r")
            _ = keepPanelAliveDuring { shell.present() }
            return
        }
        let shell = DialogShell()
        shell.addTitle("发现新版本 v\(ver)")
        shell.addIcon(NSApplication.shared.applicationIconImage)
        // notes 为 Markdown，这里简化为纯文本；可仿 cockpit 做粗体/列表渲染
        shell.addInfo("当前 v\(Updater.currentVersion)\n\n\(r.notes ?? "")")
        shell.addButton("稍后", keyEquivalent: "\u{1b}")
        let downloadIdx = shell.addButton("下载更新", keyEquivalent: "\r")
        let idx = keepPanelAliveDuring { shell.present() }
        if idx == downloadIdx {
            Task { @MainActor in
                let ok = await Updater.downloadAndInstall(version: ver, downloadURL: url, signature: sig)
                if !ok {
                    let err = DialogShell()
                    err.addTitle("更新失败")
                    err.addInfo("下载或校验失败，请稍后重试，或到 GitHub Releases 手动下载。")
                    err.addButton("知道了", keyEquivalent: "\r")
                    _ = keepPanelAliveDuring { err.present() }
                }
            }
        }
    }
}
```

**跳版本日志**（启动时检测是否刚从旧版升上来）：

```swift
func checkVersionJumpOnLaunch() {
    let current = Updater.currentVersion
    let last = UserDefaults.standard.string(forKey: UDKey.updateLastRunVersion) ?? ""
    if !last.isEmpty, last != current, Updater.isNewer(current, than: last) {
        // 刚升级成功：弹一次更新日志
        let notes = UserDefaults.standard.string(forKey: UDKey.updatePendingNotes) ?? ""
        let vSaved = UserDefaults.standard.string(forKey: UDKey.updatePendingNotesVersion) ?? ""
        let shell = DialogShell()
        shell.addTitle("已更新到 v\(current)")
        shell.addIcon(NSApplication.shared.applicationIconImage)
        shell.addInfo(vSaved == current ? notes : "本次更新完成。")
        shell.addButton("知道了", keyEquivalent: "\r")
        Task { @MainActor in _ = shell.present() }
    }
    UserDefaults.standard.set(current, forKey: UDKey.updateLastRunVersion)
}
```

**设置项**（`config.json` 或 UserDefaults）：`updateAutoCheck` 默认 true，`updateIntervalHours` 默认 1。可在「关于」弹窗加一个「自动检查更新」开关，或沿用现有设置卡片风格加一键。

### 定时检查接线

在 `AppDelegate.applicationDidFinishLaunching` 末尾（参照现有签到定时器）加一个每小时轮询：

```swift
// 定时检查更新：启动延迟 1 分钟，之后每小时
Task { @MainActor in
    try? await Task.sleep(nanoseconds: 60_000_000_000)
    if Updater.shouldCheck() {
        Updater.recordCheck()
        checkForUpdate("startup")
    }
}
```

（或用现有 `refreshInterval` 的 `Timer` 频道加一个每小时 tick。**别在每 1/3/5 分钟余额刷新里同步跑**，避免频繁打 release 接口。）

---

## 7. 完整打通顺序

1. **发布机一次性**生成密钥对，私钥放 `~/.ibalance/`（项目外），公钥 `tail -c 32` 得 base64，填入 `Updater.pubKeyBase64`。
2. `build.sh` 加 `--release` 打 zip 分支（§5.1）。
3. 首次发布：`./swift/release.sh` 生成 `latest.json` + 上传。
4. App 侧落地 `Updater.swift` + UDKey 扩展 + 弹窗函数 + 启动定时接线。
5. 真机验证（§8）。

---

## 8. 验证清单（按序）

| # | 验证项 | 方法 | 预期 |
|---|---|---|---|
| 1 | Ed25519 验签通过 | 用发布侧 `pub.pem` 对同 zip 跑 `pkeyutl -verify` | Verified Successfully |
| 2 | app 验签逻辑 | 本地用 Updater 对示例 manifest+zip 调 `downloadAndInstall` 到验签前暂停 | sig 通过 |
| 3 | 版本比较 | 单测 `isNewer("2026.8.26.3","2026.8.13.1")` | true |
| 4 | 手动检查弹窗 | 菜单触发，设一个较高远端版本 | 弹「发现新版本」，notes 显示 |
| 5 | **自替换**（重点） | 真机跑 `downloadAndInstall` 完整链路，看搬运脚本是否在退出后仍执行 | 旧 app 被替换，新 app 自动打开，版本漂移 |
| 6 | TCC 保持 | 升级前授予磁盘访问，升级后检查是否还在 | 授权保留（同签名身份） |
| 7 | 跳过版本 | 跳过 vX，重启后不再提示 vX | 提示消失 |

---

## 9. 风险与待办

- **token 泄露面**（方案 A）：内嵌只读 PAT。最坏情况是别人能读你 release 的 zip（含 app，不含用户凭据——用户数据在 Application Support，不在包内）。可接受；如果你要绝对安全选方案 C。
- **自替换脚本真机行为**：`nohup + &` 理论上能脱离父进程，但 macOS 无 `setsid`，需真机确认（验证项 5）。失败则改「改用 `launchctl submit` 常驻任务执行脚本」。
- **签名身份**：两个包都用 `iBalance Local Sign`，否则 TCC 掉（验证项 6）。
- **notes 渲染**：当前简单纯文本。要更精致可仿 cockpit 解析 `###`/`- ` 做 Markdown 列表，但非必须（YAGNI）。
- **公钥生成一次即可**：私钥不变则公钥不变。发布脚本里每次打 `pubraw` 仅供在 `Updater.swift` 首次写入核对，后续稳定不必每次改。

---

## 附：为何不需要 mock manifest

iBalance 只有 macOS arm64 一个分发目标，无需 multi-target 的 `latest.json` 路由；版本号 4 段日期式，`isNewer` 逐段比较通用。整套逻辑就是对 cockpit 做减法——把 Tauri 插件壳去掉，`latest-{{target}}.json` 简化为一个 `latest.json`，`tauri-plugin-updater` 的下载装替换换成 AppsKit 自研 4 步。核心创新点为零，可靠迁移即可。
