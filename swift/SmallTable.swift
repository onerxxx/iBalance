import AppKit

/// 小表格：主面板「用量」表与 Token 面板（总计/项目列表/词元活动）共用的紧凑表格样式口径。
/// 用户口语「小表格」即指这两张表（2026-08-29 定名）：排版参数、字体、颜色只认这里，
/// 两侧禁止各自硬编码，防样式漂移。渲染形态不同（用量表 = NSStackView 行视图；
/// Token 表 = 自绘 draw），本类型只统一「样式」，不统一渲染管线。
enum SmallTable {
    /// 行内容左右缩进（用量表 usageHorizontalInset；Token 面板内嵌态同值）
    static let horizontalInset: CGFloat = 8
    /// 行内上下缩进：行间墨迹空隙 = 2 × rowInset（两表行距节奏同源）
    static let rowInset: CGFloat = 3
    /// 数值列间距
    static let columnSpacing: CGFloat = 8
    /// 表头/区块标题字号（「平台 1H 1D 1W」与「总计/项目/词元活动」同款）
    static let titleSize: CGFloat = 10
    /// 数据行字号
    static let rowSize: CGFloat = 10
    /// 表头/标题/数据行常态色
    static let textColor: NSColor = .systemGray
    /// 表头/区块标题字重
    static let titleWeight: NSFont.Weight = .semibold
    /// 数据行字重
    static let rowWeight: NSFont.Weight = .medium

    /// 按字体开关取小表格字体（Mono > 系统；monoDigits 仅系统态生效，与 Panel.uiFont 同逻辑）
    static func font(size: CGFloat, weight: NSFont.Weight, monoDigits: Bool = false, mono: Bool) -> NSFont {
        if mono { return MonoFontProvider.font(size: size, weight: weight) }
        return monoDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }
    /// 表头/区块标题字体
    static func titleFont(mono: Bool) -> NSFont {
        font(size: titleSize, weight: titleWeight, mono: mono)
    }
    /// 数据行字体
    static func rowFont(mono: Bool, monoDigits: Bool = false) -> NSFont {
        font(size: rowSize, weight: rowWeight, monoDigits: monoDigits, mono: mono)
    }
}
