// swift-tools-version:5.9
// SwiftPM 只负责编译产物（跨调用增量：日常小修改只重编受影响文件）；
// .app bundle 组装、资源拷贝、代码签名、重启验证仍由 build.sh 完成。
import PackageDescription

let package = Package(
    name: "iBalance",
    platforms: [.macOS("26.0")],
    targets: [
        // SwiftUI 设置窗口独立库 target：可执行 target 不支持 Xcode Previews，
        // 纯 SwiftUI（模型 + 视图）放 SettingsUI/，Xcode 打开 Package.swift 即可预览。
        .target(
            name: "SettingsUI",
            path: "SettingsUI"
        ),
        // zstd 解压端单文件库（Vendor/zstd/zstddeclib.c）：Codex 把已结束会话压成
        // rollout-*.jsonl.zst，而 macOS 无系统级 zstd 解码（libarchive/compression_tool
        // 均不支持），只能自带。见 Vendor/zstd/README.md。
        // -O2 固定：debug 构建默认 -Onone，解压 ~100MB rollout 会慢一个量级
        .target(
            name: "CZstd",
            path: "Vendor/zstd",
            exclude: ["README.md", "LICENSE"],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-O2"])]
        ),
        .executableTarget(
            name: "iBalance",
            dependencies: ["SettingsUI", "CZstd"],
            path: ".",
            exclude: [
                "Info.plist", "config.json", "build.sh", "AppIcon.icns",
                "icons", "fonts",
                "scratch_tmp_render_test.swift",
                "RollingNumberView.swift.orig", "RollingNumberView.swift.tmp_orig",
                "SettingsUI",   // 已独立成库 target，勿重复编进可执行目标
                "Vendor",       // CZstd 独立 target
            ],
            // main.swift 保留 @main 入口（swiftc 时代同参数）：SPM 对 main.swift 默认
            // 按「顶层代码」语义处理，与 @main 冲突报错，显式按库语义编译即解
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
