// 独立最小复现：MenuBarFadeIconView 的三段蒙版位移动画（临时诊断文件，用完即删）
// 验证点：1) CABasicAnimation 在 mask 层上是否按 duration 播放
//         2) presentation() 的取值时机（commit 后立刻读是否拿到旧值）
import AppKit

final class FadeIcon: NSImageView {
    let fadeMask = CAGradientLayer()
    let dur: CFTimeInterval = 0.6
    var usesFade = false { didSet { guard oldValue != usesFade else { return }; transition() } }
    var installed = false
    let h: CGFloat = 20

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        wantsLayer = true
        fadeMask.colors = [NSColor.white.cgColor, NSColor.white.cgColor,
                           NSColor.white.withAlphaComponent(0.25).cgColor,
                           NSColor.white.withAlphaComponent(0.8).cgColor,
                           NSColor.white.cgColor, NSColor.white.cgColor]
        let t = NSNumber(value: 1.0 / 3.0), u = NSNumber(value: 2.0 / 3.0)
        fadeMask.locations = [NSNumber(value: 0), t, t, u, u, NSNumber(value: 1)]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        contentTintColor = .systemGray
    }
    required init?(coder: NSCoder) { fatalError() }

    private func maskFrame(_ y: CGFloat) -> NSRect { NSRect(x: 0, y: y, width: h, height: h * 3) }
    private func transition() {
        guard installed else { return }
        if usesFade {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fadeMask.removeAnimation(forKey: "slide")
            fadeMask.frame = maskFrame(-h * 2)
            CATransaction.commit()
            slide(to: -h)
        } else {
            slide(to: 0)
        }
    }
    private func slide(to target: CGFloat) {
        let fromY = fadeMask.presentation()?.frame.minY ?? fadeMask.frame.minY
        print("[slide] from=\(fromY) to=\(target) modelBeforeSet=\(fadeMask.frame.minY)")
        let anim = CABasicAnimation(keyPath: "position.y")
        anim.fromValue = fromY + h * 1.5
        anim.toValue = target + h * 1.5
        anim.duration = dur
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = maskFrame(target)
        CATransaction.commit()
        fadeMask.add(anim, forKey: "slide")
        for delay in [0.05, 0.15, 0.3, 0.45, 0.65] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let animAlive = self.fadeMask.animation(forKey: "slide") != nil
                let pres = self.fadeMask.presentation()?.frame.minY
                print("  sample@\(delay)s alive=\(animAlive) presMinY=\(pres.map { String(format: "%.2f", $0) } ?? "nil") model=\(self.fadeMask.frame.minY)")
            }
        }
    }
    override func layout() {
        super.layout()
        guard bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !installed {
            layer?.mask = fadeMask
            installed = true
        }
        fadeMask.frame = maskFrame(usesFade ? -h : 0)
        CATransaction.commit()
    }
}

let app = NSApplication.shared
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 300),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
let icon = FadeIcon()
win.contentView?.addSubview(icon)
NSLayoutConstraint.activate([
    icon.widthAnchor.constraint(equalToConstant: 20),
    icon.heightAnchor.constraint(equalToConstant: 20),
    icon.centerXAnchor.constraint(equalTo: win.contentView!.centerXAnchor),
    icon.centerYAnchor.constraint(equalTo: win.contentView!.centerYAnchor),
])
win.makeKeyAndOrderFront(nil)

let seq: [(TimeInterval, () -> Void)] = [
    (0.5, { print("== toggle 1: fade ON"); icon.usesFade = true }),
    (1.6, { print("== toggle 2: fade OFF"); icon.usesFade = false }),
    (2.7, { print("== toggle 3: fade ON again"); icon.usesFade = true }),
    (4.0, { print("== toggle 4: fade OFF"); icon.usesFade = false }),
    (5.5, { print("done"); exit(0) }),
]
for (t, f) in seq { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
app.run()
