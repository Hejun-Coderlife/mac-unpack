// 画 App 图标（1024 画布）：靛蓝到紫的圆角底 + 半开的拉链盒子 + 向上飘出的箭头
// 用法：swift tools/icon.swift 输出.png
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let g = NSGraphicsContext.current!.cgContext

// 底：macOS 图标网格的圆角矩形（四边留 100）
let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
g.addPath(bgPath); g.setFillColor(NSColor.black.cgColor); g.fillPath()
g.restoreGState()
g.saveGState()
g.addPath(bgPath); g.clip()
let cs = CGColorSpaceCreateDeviceRGB()
let bgGrad = CGGradient(colorsSpace: cs, colors: [NSColor(srgbRed: 0.33, green: 0.30, blue: 0.98, alpha: 1).cgColor,
                                                  NSColor(srgbRed: 0.62, green: 0.25, blue: 0.93, alpha: 1).cgColor,
                                                  NSColor(srgbRed: 0.93, green: 0.36, blue: 0.62, alpha: 1).cgColor] as CFArray,
                        locations: [0, 0.6, 1])!
g.drawLinearGradient(bgGrad, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
// 顶部一层柔光
let glow = CGGradient(colorsSpace: cs, colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
g.drawRadialGradient(glow, startCenter: CGPoint(x: 360, y: 860), startRadius: 0, endCenter: CGPoint(x: 360, y: 860), endRadius: 620, options: [])
g.restoreGState()

// 盒子
let box = CGRect(x: 262, y: 230, width: 500, height: 380)
let boxPath = CGPath(roundedRect: box, cornerWidth: 54, cornerHeight: 54, transform: nil)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: NSColor(srgbRed: 0.15, green: 0.05, blue: 0.4, alpha: 0.45).cgColor)
g.addPath(boxPath); g.setFillColor(NSColor.white.cgColor); g.fillPath()
g.restoreGState()
g.saveGState()
g.addPath(boxPath); g.clip()
let boxGrad = CGGradient(colorsSpace: cs, colors: [NSColor.white.cgColor, NSColor(srgbRed: 0.88, green: 0.88, blue: 0.98, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
g.drawLinearGradient(boxGrad, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
// 盒口：深色的开口缝
g.setFillColor(NSColor(srgbRed: 0.30, green: 0.22, blue: 0.75, alpha: 1).cgColor)
g.fill(CGRect(x: box.minX, y: box.maxY - 70, width: box.width, height: 70))
g.restoreGState()

// 拉链：中间一条齿
let zx = box.midX
g.setFillColor(NSColor(srgbRed: 0.55, green: 0.45, blue: 0.95, alpha: 1).cgColor)
var y = box.minY + 40
var left = true
while y < box.maxY - 100 {
    g.fill(CGRect(x: left ? zx - 30 : zx, y: y, width: 30, height: 22).insetBy(dx: 1, dy: 0))
    y += 30; left.toggle()
}
// 拉头
let pull = CGPath(roundedRect: CGRect(x: zx - 26, y: box.minY + 4, width: 52, height: 66), cornerWidth: 14, cornerHeight: 14, transform: nil)
g.addPath(pull); g.setFillColor(NSColor(srgbRed: 0.42, green: 0.30, blue: 0.90, alpha: 1).cgColor); g.fillPath()

// 向上飘出的箭头
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor(srgbRed: 0.2, green: 0.0, blue: 0.4, alpha: 0.4).cgColor)
let arrow = CGMutablePath()
let ax = box.midX, top: CGFloat = 840
arrow.move(to: CGPoint(x: ax, y: top))
arrow.addLine(to: CGPoint(x: ax + 120, y: top - 130))
arrow.addLine(to: CGPoint(x: ax + 48, y: top - 130))
arrow.addLine(to: CGPoint(x: ax + 48, y: 560))
arrow.addLine(to: CGPoint(x: ax - 48, y: 560))
arrow.addLine(to: CGPoint(x: ax - 48, y: top - 130))
arrow.addLine(to: CGPoint(x: ax - 120, y: top - 130))
arrow.closeSubpath()
g.addPath(arrow); g.setFillColor(NSColor.white.cgColor); g.fillPath()
g.restoreGState()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
