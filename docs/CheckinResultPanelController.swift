// ============================================================
// [存档] 手动签到结果子面板（已弃用）
// ============================================================
// v2026.8.16.23 起，手动签到结果改用 DialogShell 原生 NSAlert 弹窗模板，
// 本类（锚定主面板右侧的无边框玻璃子面板）从 Panel.swift 移除，另存于此备查。
//
// ⚠️ 本文件不参与编译（build.sh 只收集 swift/ 目录下的源文件）。
// 依赖 Panel.swift 中的 CheckinRowState / CheckinResultRow（仍保留）与
// TintedVisualEffectView / Palette。
//
// 完整性说明：删除前大部分代码有完整记录，仅「玻璃效果容器配置」一段
// （原 725-747 行，wrapper 发丝边框 + TintedVisualEffectView 创建）按
// 主面板父容器同款配置（BalancePanelViewController.loadView）重构恢复，
// 其余均为原文。

import AppKit

/// 手动签到结果子面板：独立无边框 NSPanel（TintedVisualEffectView 玻璃质感，
/// 与主面板父容器同款配置），锚定在主面板 popover 窗口右侧、顶部对齐。
/// 主面板关闭（popoverDidClose）或点击两个面板之外的区域时一并关闭。
final class CheckinResultPanelController: NSObject {
    private var window: NSPanel?
    private var globalMonitor: Any?
    private weak var popover: NSPopover?

    /// 显示子面板：attachedTo 主面板 popover（定位锚点 + 防误关）
    func show(attachedTo popover: NSPopover, okCount: Int, failCount: Int, rows: [CheckinResultRow]) {
        close()
        guard let popWin = popover.contentViewController?.view.window, !rows.isEmpty else { return }
        self.popover = popover
        // 子面板在 popover 外：期间禁止 popover 因「点击面板外」误关（点击「完成」按钮时会先关掉主面板）
        popover.behavior = .applicationDefined

        // ── 标题行：「手动签到完成」 + 右侧「成功 x · 失败 x」──
        let title = NSTextField(labelWithString: "手动签到完成")
        title.font = .systemFont(ofSize: 12, weight: .bold)
        title.textColor = .systemGray
        let summary = NSTextField(labelWithString: "成功\u{2009}\(okCount) · 失败\u{2009}\(failCount)")
        summary.font = .systemFont(ofSize: 10)
        summary.textColor = failCount > 0 ? .systemOrange : .systemGray
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [title, spacer, summary])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.heightAnchor.constraint(equalToConstant: 18).isActive = true

        // ── 分割线 ──
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.dividerColor.cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        // ── 结果行列表 ──
        let list = NSStackView(views: [titleRow, divider])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.setCustomSpacing(6, after: titleRow)
        for row in rows {
            let (iconName, tint): (String, NSColor)
            switch row.state {
            case .ok: (iconName, tint) = ("checkmark.circle.fill", .systemGreen)
            case .fail: (iconName, tint) = ("xmark.circle.fill", .systemOrange)
            case .skipped: (iconName, tint) = ("minus.circle", .systemGray)
            }
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            icon.contentTintColor = tint
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 12).isActive = true
            let label = NSTextField(labelWithString: row.text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = row.state == .fail ? .systemOrange : Palette.cardForeground
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            label.cell?.wraps = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let r = NSStackView(views: [icon, label])
            r.orientation = .horizontal
            r.alignment = .centerY
            r.spacing = 6
            r.heightAnchor.constraint(equalToConstant: 16).isActive = true
            list.addArrangedSubview(r)
        }

        // ── 完成按钮（recessed 风格，同主面板 Footer 退出按钮）──
        let doneBtn = NSButton(title: "完成", target: self, action: #selector(doneTapped))
        doneBtn.bezelStyle = .recessed
        doneBtn.controlSize = .small
        doneBtn.showsBorderOnlyWhileMouseInside = true
        doneBtn.contentTintColor = .systemGray

        let content = NSStackView(views: [list, doneBtn])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false

        // ── 窗口：无边框 + 透明底，玻璃内容自定义圆角 ──
        let padding: CGFloat = 12
        // 宽高随内容缩放：不加固定宽度约束，fittingSize 解出自然尺寸；
        // 仅设上限 320pt 防超长文本把面板撑得过宽（超出时 label 截断）
        content.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        let fit = content.fittingSize
        let size = NSSize(width: ceil(fit.width) + padding * 2, height: ceil(fit.height) + padding * 2)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // 略高于主面板 popover 窗口层级，保证并排显示不被遮挡
        panel.level = NSWindow.Level(rawValue: popWin.level.rawValue + 1)
        panel.collectionBehavior = popWin.collectionBehavior

        // wrapper：layer 圆角裁剪出无边框窗口的玻璃圆角 + 发丝边框
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = Palette.cardCornerRadius
        // ——以下「玻璃效果容器配置」一段为按主面板同款配置重构恢复（原文佚失）——
        wrapper.layer?.borderWidth = 1
        wrapper.layer?.borderColor = Palette.dividerColor.cgColor
        let effect = TintedVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = false
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.tintColor = Palette.containerTint
        effect.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(effect)
        panel.contentView = wrapper
        // ——重构段结束——

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -padding),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -padding),
        ])

        // 定位：主面板右侧（间距 8pt）、顶部对齐主面板内容区顶边。
        // popover 窗口顶部有锚点箭头（高度 = 窗口高 − 内容高，兜底 12pt），需下移避开
        let popFrame = popWin.frame
        let arrowH = max(12, popFrame.height - popover.contentSize.height)
        panel.setFrameOrigin(NSPoint(x: popFrame.maxX + 8, y: popFrame.maxY - arrowH - size.height))

        window = panel
        // 淡入：0.22s easeInEaseOut（项目统一过渡时长）
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.22
        NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()

        // 全局监听：点击两个面板之外 → 关闭子面板 + 主面板（还原 transient「点击外关闭」行为）。
        // applicationDefined 期间主面板不会自动关，需要手动补齐。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let sub = self.window else { return }
            let p = NSEvent.mouseLocation
            if !sub.frame.contains(p) && !popWin.frame.contains(p) {
                // 先取引用再 close（close 会清空 self.popover）
                let pop = self.popover
                self.close()
                pop?.performClose(nil)
            }
        }
    }

    /// 关闭子面板：移除全局监听、恢复主面板 transient 行为
    func close() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        window?.orderOut(nil)
        window = nil
        if let pop = popover, pop.isShown { pop.behavior = .transient }
        popover = nil
    }

    @objc private func doneTapped() {
        close()
    }
}
