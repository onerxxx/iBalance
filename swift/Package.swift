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
        .executableTarget(
            name: "iBalance",
            dependencies: ["SettingsUI"],
            path: ".",
            exclude: [
                "Info.plist", "config.json", "build.sh", "AppIcon.icns",
                "icons", "fonts",
                "scratch_tmp_render_test.swift",
                "RollingNumberView.swift.orig", "RollingNumberView.swift.tmp_orig",
                "SettingsUI",   // 已独立成库 target，勿重复编进可执行目标
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
