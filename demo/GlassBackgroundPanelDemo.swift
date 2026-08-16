import AppKit

// ============================================================
// 浅色 Liquid Glass 面板 Demo（macOS 26+）
//
// 结构：
//   NSPanel（全透明 + 系统阴影，960×540 16:9）
//     └─ NSGlassEffectContainerView（窗口 contentView）
//         └─ NSGlassEffectView（.regular，铺满 = 玻璃折射层）
//             └─ contentView（透明宿主）
//                 ├─ SkyGradientView（天空蓝垂直渐变·半透明）
//                 ├─ InnerHighlightView（内高亮：真高斯模糊 + 顶部更亮）
//                 ├─ 居中文本组
//                 └─ 亮/暗主题切换按钮（右上角）
//
// 内高亮实现（drawRect，公开 API）：
//   1) NSShadow(blur≈5) + 白描边 → 高斯柔化的整圈内发光；
//   2) replacePathWithStrokedPath + 线性渐变填充 → 亮度自顶部向底部衰减，
//      形成"光从上方来"的玻璃内缘亮边。
//
// 注意：不要用 panel.contentViewController —— AppKit 会按视图
// fittingSize 重设窗口大小，纯相对约束会把它缩没；直接赋 contentView。
//
// 编译运行：
//   cd demo && swiftc -O -framework AppKit \
//     -o GlassBackgroundPanelDemo GlassBackgroundPanelDemo.swift
//   ./GlassBackgroundPanelDemo
// ============================================================

/// 面板视觉参数（单一来源，渐变/高亮/玻璃共用）
enum GlassStyle {
    static let cardRadius: CGFloat = 28
    /// 内高亮描边相对卡片边缘的内缩量
    static let highlightInset: CGFloat = 2
}

// MARK: - 面板窗口

final class GlassPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false                       // 窗口本体不铺底色
        backgroundColor = .clear
        hasShadow = true                       // 阴影跟随玻璃轮廓，强化"凸出"
        isMovableByWindowBackground = true     // 无内容区域可直接拖动
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    // Esc 退出 Demo
    override func cancelOperation(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

// MARK: - 天空蓝渐变背景

/// 半透明天空蓝垂直渐变，垫在最底层透出玻璃折射。
final class SkyGradientView: NSView {
    /// 渐变作为 backing layer 的子图层（新 SDK 的 NSView 已不可覆写 layerClass）
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        gradient.cornerRadius = GlassStyle.cardRadius
        // macOS 图层坐标 y=0 在底部：起点=底（深蓝）→ 终点=顶（亮天空蓝）
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // 窗口缩放时禁止隐式动画
        gradient.frame = bounds
        CATransaction.commit()
    }

    /// 亮色=白天天空蓝，暗色=夜空深蓝
    func applyTheme(isLight: Bool) {
        if isLight {
            gradient.colors = [
                NSColor(srgbRed: 0.302, green: 0.639, blue: 1.000, alpha: 0.32).cgColor, // 底：晴空蓝
                NSColor(srgbRed: 0.498, green: 0.753, blue: 1.000, alpha: 0.42).cgColor, // 中
                NSColor(srgbRed: 0.769, green: 0.898, blue: 1.000, alpha: 0.52).cgColor, // 顶：天际亮蓝
            ]
        } else {
            gradient.colors = [
                NSColor(srgbRed: 0.086, green: 0.196, blue: 0.431, alpha: 0.45).cgColor, // 底：夜空深蓝
                NSColor(srgbRed: 0.180, green: 0.361, blue: 0.769, alpha: 0.38).cgColor, // 中
                NSColor(srgbRed: 0.435, green: 0.639, blue: 0.949, alpha: 0.30).cgColor, // 顶：晨昏蓝
            ]
        }
    }
}

// MARK: - 内高亮（多层同心 · 大范围真高斯模糊 · 顶部更亮）

/// 画在渐变之上：多圈同心内缩描边，每圈用 NSShadow 高斯模糊晕出
/// 30–50pt 的大范围柔光；顶部再叠一条更亮的半圆弧，保持"光从上方来"。
final class InnerHighlightView: NSView {
    /// 单圈内高亮参数：内缩量 / 模糊半径 / 描边强度 / 光晕强度
    private struct RingSpec {
        let inset: CGFloat
        let blur: CGFloat
        let strokeAlpha: CGFloat
        let glowAlpha: CGFloat
    }

    /// 亮色主题：三圈同心，模糊范围 35–50pt
    private static let lightRings: [RingSpec] = [
        RingSpec(inset: 2,  blur: 50, strokeAlpha: 0.35, glowAlpha: 0.55),
        RingSpec(inset: 14, blur: 40, strokeAlpha: 0.22, glowAlpha: 0.32),
        RingSpec(inset: 30, blur: 35, strokeAlpha: 0.16, glowAlpha: 0.22),
    ]

    /// 暗色主题：整体减弱，避免大范围光晕在深色玻璃上发灰
    private static let darkRings: [RingSpec] = [
        RingSpec(inset: 2,  blur: 50, strokeAlpha: 0.25, glowAlpha: 0.38),
        RingSpec(inset: 14, blur: 40, strokeAlpha: 0.14, glowAlpha: 0.20),
        RingSpec(inset: 30, blur: 35, strokeAlpha: 0.10, glowAlpha: 0.14),
    ]

    private var rings: [RingSpec] = InnerHighlightView.lightRings
    /// 顶部加亮弧的模糊与亮度（叠在最内圈上）
    private var topArcBlur: CGFloat = 30
    private var topArcGlowAlpha: CGFloat = 0.75

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 纯 draw(_:) 绘制的透明视图
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    /// 内缩同心圆角矩形路径
    private func ringPath(inset: CGFloat) -> NSBezierPath {
        let r = GlassStyle.cardRadius
        return NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                            xRadius: max(r - inset, 0), yRadius: max(r - inset, 0))
    }

    /// 上半圈弧路径（左侧中点 → 左上圆角 → 顶边 → 右上圆角 → 右侧中点）
    private func topArcPath(inset: CGFloat) -> NSBezierPath {
        let rad = max(GlassStyle.cardRadius - inset, 0)
        let rr = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rr.minX, y: rr.midY))
        path.line(to: NSPoint(x: rr.minX, y: rr.maxY - rad))
        // AppKit 角度逆时针为正；180°→90° 取顺时针短弧（左上象限）
        path.appendArc(withCenter: NSPoint(x: rr.minX + rad, y: rr.maxY - rad),
                       radius: rad, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rr.maxX - rad, y: rr.maxY))
        path.appendArc(withCenter: NSPoint(x: rr.maxX - rad, y: rr.maxY - rad),
                       radius: rad, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: rr.maxX, y: rr.midY))
        return path
    }

    /// 一遍"描边 + 高斯光晕"：描边本体偏淡，柔光由 NSShadow 晕开
    private func stroke(_ path: NSBezierPath, lineWidth: CGFloat,
                        strokeAlpha: CGFloat, glowAlpha: CGFloat, blur: CGFloat) {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blur
        shadow.shadowColor = NSColor.white.withAlphaComponent(glowAlpha)
        shadow.shadowOffset = .zero
        shadow.set()
        path.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(strokeAlpha).setStroke()
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 60, bounds.height > 60 else { return }

        // 高亮只允许画在卡片圆角以内
        NSBezierPath(roundedRect: bounds,
                     xRadius: GlassStyle.cardRadius,
                     yRadius: GlassStyle.cardRadius).addClip()

        // 多圈同心光晕：由内缘向深处逐圈变淡
        for spec in rings {
            stroke(ringPath(inset: spec.inset), lineWidth: 2,
                   strokeAlpha: spec.strokeAlpha,
                   glowAlpha: spec.glowAlpha,
                   blur: spec.blur)
        }

        // 顶部加亮弧：叠在最内圈上，让上缘明显更亮
        stroke(topArcPath(inset: GlassStyle.highlightInset), lineWidth: 3,
               strokeAlpha: 0.45,
               glowAlpha: topArcGlowAlpha,
               blur: topArcBlur)
    }

    /// 亮/暗主题切换光环强度
    func applyTheme(isLight: Bool) {
        rings = isLight ? Self.lightRings : Self.darkRings
        topArcBlur = isLight ? 30 : 24
        topArcGlowAlpha = isLight ? 0.75 : 0.50
        needsDisplay = true
    }
}

// MARK: - 面板内容

final class GlassPanelViewController: NSViewController {
    /// 合并/批量渲染后代玻璃，减少渲染 passes
    private let glassContainer = NSGlassEffectContainerView()
    /// 玻璃折射层：采样窗后内容做模糊/折射
    private let glassBackground = NSGlassEffectView()
    /// 玻璃 contentView 的透明宿主，控件都放这里
    private let contentHost = NSView()
    /// 天空蓝渐变（垫在最底，透出玻璃折射）
    private let skyBackdrop = SkyGradientView()
    /// 内高亮（叠在渐变上）
    private let highlightOverlay = InnerHighlightView()
    private let themeButton = NSButton()
    private let textStack = NSStackView()

    /// 玻璃自身的 tint：带一点天空蓝，与渐变呼应
    private static let lightGlassTint = NSColor(srgbRed: 0.55, green: 0.78, blue: 1.0, alpha: 0.15)
    private static let darkGlassTint = NSColor(srgbRed: 0.44, green: 0.64, blue: 0.95, alpha: 0.10)

    override func loadView() {
        view = glassContainer

        // —— 玻璃折射层：Regular Liquid Glass ——
        glassBackground.translatesAutoresizingMaskIntoConstraints = false
        glassBackground.style = .regular
        glassBackground.cornerRadius = GlassStyle.cardRadius
        if #available(macOS 27, *) {
            // 指针交互时玻璃给出视觉反馈（该 API 为 macOS 27+）
            glassBackground.effectIsInteractive = true
        }

        // 玻璃内容宿主：透明，不抢玻璃自身的光影
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = NSColor.clear.cgColor
        glassBackground.contentView = contentHost

        glassContainer.contentView = glassBackground

        // —— 天空蓝渐变 → 内高亮 → 文本 → 按钮（从底到顶）——
        skyBackdrop.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(skyBackdrop)
        highlightOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(highlightOverlay)

        // —— 居中文本组 ——
        let title = NSTextField(labelWithString: "浅色 Liquid Glass 面板")
        title.font = .systemFont(ofSize: 30, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "天空蓝渐变 × 同心光晕 blur 35–50pt × 玻璃折射")
        subtitle.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor

        let body1 = NSTextField(labelWithString: "父级窗口与容器完全透明，不叠加 NSVisualEffectView。")
        let body2 = NSTextField(labelWithString: "天空蓝半透明渐变叠在系统玻璃上，折射仍然透出。")
        let body3 = NSTextField(labelWithString: "内缘高光为真实高斯模糊，且自顶部向下衰减。")
        for line in [body1, body2, body3] {
            line.font = .systemFont(ofSize: 13)
            line.textColor = .secondaryLabelColor
        }

        let sizeTag = NSTextField(labelWithString: "960 × 540 · 16:9")
        sizeTag.font = .systemFont(ofSize: 11)
        sizeTag.textColor = .tertiaryLabelColor

        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 10
        textStack.setHuggingPriority(.required, for: .horizontal)
        for item in [title, subtitle, body1, body2, body3, sizeTag] {
            textStack.addArrangedSubview(item)
        }
        // 副标题与正文之间留出呼吸感
        textStack.setCustomSpacing(20, after: subtitle)
        textStack.setCustomSpacing(24, after: body3)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(textStack)

        // —— 右上角主题切换按钮 ——
        themeButton.bezelStyle = .accessoryBar
        themeButton.imagePosition = .imageOnly
        themeButton.target = self
        themeButton.action = #selector(toggleAppearance(_:))
        themeButton.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(themeButton)

        NSLayoutConstraint.activate([
            // 玻璃铺满面板
            glassBackground.leadingAnchor.constraint(equalTo: glassContainer.leadingAnchor),
            glassBackground.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor),
            glassBackground.topAnchor.constraint(equalTo: glassContainer.topAnchor),
            glassBackground.bottomAnchor.constraint(equalTo: glassContainer.bottomAnchor),

            // 宿主贴满玻璃（contentView 的实际布局由 AppKit 接管，这里补约束兜底）
            contentHost.leadingAnchor.constraint(equalTo: glassBackground.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: glassBackground.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: glassBackground.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: glassBackground.bottomAnchor),

            // 渐变与内高亮铺满宿主
            skyBackdrop.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            skyBackdrop.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            skyBackdrop.topAnchor.constraint(equalTo: contentHost.topAnchor),
            skyBackdrop.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            highlightOverlay.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            highlightOverlay.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            highlightOverlay.topAnchor.constraint(equalTo: contentHost.topAnchor),
            highlightOverlay.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),

            // 文本组居中
            textStack.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
            textStack.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),

            // 按钮固定右上角
            themeButton.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 16),
            themeButton.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -16),
        ])

        applyTheme()
    }

    // MARK: 亮/暗主题

    private func isCurrentlyLight() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }

    @objc private func toggleAppearance(_ sender: NSButton) {
        let next: NSAppearance.Name = isCurrentlyLight() ? .darkAqua : .aqua
        NSApp.appearance = NSAppearance(named: next)
        applyTheme()
    }

    private func applyTheme() {
        let isLight = isCurrentlyLight()
        glassBackground.tintColor = isLight ? Self.lightGlassTint : Self.darkGlassTint
        skyBackdrop.applyTheme(isLight: isLight)
        highlightOverlay.applyTheme(isLight: isLight)
        let symbol = isLight ? "moon.stars.fill" : "sun.max.fill"
        themeButton.image = NSImage(systemSymbolName: symbol,
                                    accessibilityDescription: "切换亮暗主题")
    }
}

// MARK: - App 引导

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: GlassPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540))
        let viewController = GlassPanelViewController()
        // 直接赋 contentView 而非 contentViewController，避免窗口被 fittingSize 缩放
        panel.contentView = viewController.view
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
