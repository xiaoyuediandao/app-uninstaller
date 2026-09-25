import AppKit

// 欢迎页插画：抽屉里的文件 + 卸载符号 + 装饰点（1200x900 透明底）
let W: CGFloat = 1200, H: CGFloat = 900
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "illustration.png"
let blue = NSColor(srgbRed: 0.180, green: 0.420, blue: 0.910, alpha: 1)

let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()

let cx = W / 2

// 装饰点
func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: CGFloat) {
    blue.withAlphaComponent(a).setFill()
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
}
dot(cx - 420, 620, 16, 0.85)
dot(cx + 430, 600, 12, 0.6)
dot(cx + 350, 260, 9, 0.4)
dot(cx - 380, 300, 7, 0.35)
dot(cx + 480, 430, 6, 0.5)

// 抽屉背板（深色）
let backRect = NSRect(x: cx - 260, y: 300, width: 520, height: 300)
NSColor(srgbRed: 0.78, green: 0.83, blue: 0.90, alpha: 1).setFill()
NSBezierPath(roundedRect: backRect, xRadius: 28, yRadius: 28).fill()

// 文件（4 张，白色灰边，向上错位）
for i in 0..<4 {
    let fw: CGFloat = 380 - CGFloat(i) * 24
    let fx = cx - fw / 2
    let fy: CGFloat = 540 + CGFloat(i) * 46
    let fr = NSRect(x: fx, y: fy, width: fw, height: 190)
    NSColor.white.setFill()
    let sheet = NSBezierPath(roundedRect: fr, xRadius: 14, yRadius: 14)
    sheet.fill()
    NSColor(srgbRed: 0.82, green: 0.86, blue: 0.92, alpha: 1).setStroke()
    sheet.lineWidth = 3
    sheet.stroke()
    // 文件上的横线
    NSColor(srgbRed: 0.88, green: 0.91, blue: 0.95, alpha: 1).setFill()
    for j in 0..<3 {
        NSBezierPath(roundedRect: NSRect(x: fx + 34, y: fy + 130 - CGFloat(j) * 34, width: fw - 68 - CGFloat(j) * 40, height: 12), xRadius: 6, yRadius: 6).fill()
    }
}

// 抽屉前板（浅色，盖住文件下半部）
let frontRect = NSRect(x: cx - 300, y: 200, width: 600, height: 260)
NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1).setFill()
let front = NSBezierPath(roundedRect: frontRect, xRadius: 30, yRadius: 30)
front.fill()
NSColor(srgbRed: 0.80, green: 0.85, blue: 0.92, alpha: 1).setStroke()
front.lineWidth = 3
front.stroke()
// 抽屉把手
NSColor(srgbRed: 0.82, green: 0.86, blue: 0.92, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: cx - 70, y: 410, width: 140, height: 18), xRadius: 9, yRadius: 9).fill()

// 前板中央：卸载符号（蓝桶+白X，圆形底）
let badgeR: CGFloat = 86
let badgeRect = NSRect(x: cx - badgeR, y: 230 + (frontRect.height/2) - badgeR - 40, width: badgeR*2, height: badgeR*2)
blue.setFill()
NSBezierPath(ovalIn: badgeRect).fill()
if let base = NSImage(systemSymbolName: "xmark.bin.fill", accessibilityDescription: nil) {
    var conf = NSImage.SymbolConfiguration(pointSize: 96, weight: .medium)
    conf = conf.applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
    if let sym = base.withSymbolConfiguration(conf) {
        let sz = sym.size
        sym.draw(in: NSRect(x: badgeRect.midX - sz.width/2, y: badgeRect.midY - sz.height/2, width: sz.width, height: sz.height))
    }
}
image.unlockFocus()

if let tiff = image.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: outPath))
    print("written: \(outPath)")
} else { print("FAILED"); exit(1) }
