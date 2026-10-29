// 画压缩包的文件图标（1024 画布）：一张右上角折角的白纸 + 和 App 图标同款的拉链。Windows 安装版注册文件类型时用
// 用法：swift tools/doc-icon.swift 输出.png [simple]   —— simple 是给 16/24/32 小尺寸的：线条更粗，不画小齿
import AppKit

let S: CGFloat = 1024
let simple = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "simple"
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let g = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

// 纸：竖长方形，右上角切掉一个三角做折角
let L: CGFloat = 176, R: CGFloat = 848, B: CGFloat = 40, T: CGFloat = 984, fold: CGFloat = 230, r: CGFloat = 44
let page = CGMutablePath()
page.move(to: CGPoint(x: L + r, y: B))
page.addLine(to: CGPoint(x: R - r, y: B)); page.addQuadCurve(to: CGPoint(x: R, y: B + r), control: CGPoint(x: R, y: B))
page.addLine(to: CGPoint(x: R, y: T - fold))
page.addLine(to: CGPoint(x: R - fold, y: T))
page.addLine(to: CGPoint(x: L + r, y: T)); page.addQuadCurve(to: CGPoint(x: L, y: T - r), control: CGPoint(x: L, y: T))
page.addLine(to: CGPoint(x: L, y: B + r)); page.addQuadCurve(to: CGPoint(x: L + r, y: B), control: CGPoint(x: L, y: B))
page.closeSubpath()
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -8), blur: simple ? 0 : 24, color: NSColor.black.withAlphaComponent(simple ? 0 : 0.22).cgColor)
g.addPath(page); g.setFillColor(NSColor.white.cgColor); g.fillPath()
g.restoreGState()
g.saveGState()
g.addPath(page); g.clip()
let paper = CGGradient(colorsSpace: cs, colors: [NSColor.white.cgColor, NSColor(white: 0.95, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
g.drawLinearGradient(paper, start: CGPoint(x: 0, y: T), end: CGPoint(x: 0, y: B), options: [])
g.restoreGState()
g.addPath(page); g.setStrokeColor(NSColor(white: simple ? 0.55 : 0.74, alpha: 1).cgColor); g.setLineWidth(simple ? 36 : 8); g.strokePath()
// 折角：浅灰三角
let flap = CGMutablePath()
flap.move(to: CGPoint(x: R - fold, y: T)); flap.addLine(to: CGPoint(x: R - fold, y: T - fold + r))
flap.addQuadCurve(to: CGPoint(x: R - fold + r, y: T - fold), control: CGPoint(x: R - fold, y: T - fold))
flap.addLine(to: CGPoint(x: R, y: T - fold)); flap.closeSubpath()
g.addPath(flap); g.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor); g.fillPath()
g.addPath(flap); g.setStrokeColor(NSColor(white: simple ? 0.55 : 0.74, alpha: 1).cgColor); g.setLineWidth(simple ? 36 : 8); g.setLineJoin(.round); g.strokePath()

// 拉链：和 tools/icon.swift 同一个造型，整体缩小放在纸的中间偏下
let cx: CGFloat = 512, k: CGFloat = 1.0, pullY: CGFloat = 560
func y(_ v: CGFloat) -> CGFloat { pullY + (v - 600) * k }
if !simple {
    g.setFillColor(NSColor(white: 0.70, alpha: 1).cgColor)
    var ty = y(250); var side = true
    while ty < y(480) {
        g.addPath(CGPath(roundedRect: CGRect(x: side ? cx - 26 : cx, y: ty, width: 26, height: 10), cornerWidth: 4, cornerHeight: 4, transform: nil)); g.fillPath()
        ty += 18; side.toggle()
    }
    g.setStrokeColor(NSColor(white: 0.72, alpha: 1).cgColor); g.setLineWidth(3)
    g.move(to: CGPoint(x: cx, y: y(244))); g.addLine(to: CGPoint(x: cx, y: y(500))); g.strokePath()
} else {
    g.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor); g.setLineWidth(40)
    g.move(to: CGPoint(x: cx, y: y(200))); g.addLine(to: CGPoint(x: cx, y: y(500))); g.strokePath()
}
let w: CGFloat = simple ? 110 : 74
let gap = CGMutablePath()
gap.move(to: CGPoint(x: cx, y: y(560)))
gap.addCurve(to: CGPoint(x: cx - w, y: y(790)), control1: CGPoint(x: cx - 20, y: y(670)), control2: CGPoint(x: cx - w, y: y(700)))
gap.addQuadCurve(to: CGPoint(x: cx + w, y: y(790)), control: CGPoint(x: cx, y: y(806)))
gap.addCurve(to: CGPoint(x: cx, y: y(560)), control1: CGPoint(x: cx + w, y: y(700)), control2: CGPoint(x: cx + 20, y: y(670)))
g.saveGState()
g.addPath(gap); g.clip()
let inside = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0.30, alpha: 1).cgColor, NSColor(white: 0.07, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
g.drawLinearGradient(inside, start: CGPoint(x: 0, y: y(600)), end: CGPoint(x: 0, y: y(810)), options: [])
g.restoreGState()
if !simple { g.addPath(gap); g.setStrokeColor(NSColor(white: 0.70, alpha: 1).cgColor); g.setLineWidth(4); g.strokePath() }
let pw: CGFloat = simple ? 110 : 68
let pull = CGRect(x: cx - pw / 2, y: y(450), width: pw, height: simple ? 170 : 150)
let pullPath = CGPath(roundedRect: pull, cornerWidth: pw * 0.44, cornerHeight: pw * 0.44, transform: nil)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -10), blur: simple ? 0 : 22, color: NSColor.black.withAlphaComponent(simple ? 0 : 0.28).cgColor)
g.addPath(pullPath); g.setFillColor(NSColor.white.cgColor); g.fillPath()
g.restoreGState()
g.saveGState()
g.addPath(pullPath); g.clip()
let metal = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0.99, alpha: 1).cgColor, NSColor(white: 0.86, alpha: 1).cgColor, NSColor(white: 0.74, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
g.drawLinearGradient(metal, start: CGPoint(x: pull.minX, y: pull.maxY), end: CGPoint(x: pull.maxX, y: pull.minY), options: [])
g.restoreGState()
g.addPath(pullPath); g.setStrokeColor(NSColor(white: simple ? 0.40 : 0.62, alpha: 1).cgColor); g.setLineWidth(simple ? 24 : 2.5); g.strokePath()
if !simple {
    g.addPath(CGPath(roundedRect: CGRect(x: cx - 11, y: pull.minY + 24, width: 22, height: 54), cornerWidth: 11, cornerHeight: 11, transform: nil))
    g.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor); g.fillPath()
}

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
