// swift-tools-version:5.9
// SwiftPM 只负责编译产物（跨调用增量：日常小修改只重编受影响文件）；
// .app bundle 组装、资源拷贝、代码签名、重启验证仍由 build.sh 完成。
import PackageDescription

let package = Package(
    name: "iBalance",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "iBalance",
            path: ".",
            exclude: [
                "Info.plist", "config.json", "build.sh", "AppIcon.icns",
                "icons", "fonts",
                "scratch_mask_anim_test.swift", "scratch_tmp_render_test.swift",
                "RollingNumberView.swift.orig", "RollingNumberView.swift.tmp_orig",
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
