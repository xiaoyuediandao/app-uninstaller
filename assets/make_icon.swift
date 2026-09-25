import AppKit

// 彻底卸载.app 图标渲染器：1024x1024 macOS 风格 squircle 图标
// 用法: swift make_icon.swift <输出.png>
let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// --- squircle 底板 ---
let inset: CGFloat = size * 0.018
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = size * 0.2237
let plate = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// 底色：上 靛蓝 #6A6AF4 -> 下 深靛 #2E5BFF
let topColor    = NSColor(srgbRed: 0.427, green: 0.435, blue: 0.965, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.153, green: 0.337, blue: 0.941, alpha: 1)
plate.addClip()
NSGradient(starting: topColor, ending: bottomColor)!.draw(in: rect, angle: -90)

// 顶部柔和高光
let glossRect = NSRect(x: inset, y: size * 0.52, width: size - inset * 2, height: size * 0.46 - inset)
NSGradient(starting: NSColor.white.withAlphaComponent(0.22),
           ending:   NSColor.white.withAlphaComponent(0.0))!.draw(in: glossRect, angle: -90)

// 边缘描线
NSColor.black.withAlphaComponent(0.22).setStroke()
plate.lineWidth = size * 0.004
plate.stroke()

// --- 中央符号：bin.fill（白色）+ xmark（靛蓝），手动分层保证对比 ---
func symbol(_ name: String, point: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    var conf = NSImage.SymbolConfiguration(pointSize: point, weight: .medium)
    conf = conf.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return base.withSymbolConfiguration(conf)
}

let binPt  = size * 0.46
if let bin = symbol("xmark.bin.fill", point: binPt, color: .white) {
    let sz = bin.size
    let r = NSRect(x: (size - sz.width) / 2,
                   y: (size - sz.height) / 2 - size * 0.008,
                   width: sz.width, height: sz.height)
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.30)
    sh.shadowBlurRadius = size * 0.022
    sh.shadowOffset = NSSize(width: 0, height: -size * 0.010)
    sh.set()
    bin.draw(in: r)
    NSShadow().set()  // 复位阴影

    // X 画在桶身中央（桶身约在符号中线偏下 12% 处）
    if let x = symbol("xmark", point: binPt * 0.34, color: bottomColor) {
        let xs = x.size
        let xr = NSRect(x: (size - xs.width) / 2,
                        y: (size - xs.height) / 2 - binPt * 0.145,
                        width: xs.width, height: xs.height)
        x.draw(in: xr)
    }
}
image.unlockFocus()

if let tiff = image.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: outPath))
    print("written: \(outPath)")
} else {
    print("FAILED to write png")
    exit(1)
}
