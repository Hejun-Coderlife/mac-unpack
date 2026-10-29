// 画 App 图标（1024 画布），仿 Typora：白底圆角方块 + 细灰边 + 柔和阴影，中间一条黑色的拉链（不用文字）
// 用法：swift tools/icon.swift 输出.png
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let g = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
let ink = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).cgColor

// 底：macOS 图标网格的圆角方块（四边留 100），白到极浅灰
let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
g.addPath(bgPath); g.setFillColor(NSColor.white.cgColor); g.fillPath()
g.restoreGState()
g.saveGState()
g.addPath(bgPath); g.clip()
let paper = CGGradient(colorsSpace: cs, colors: [NSColor.white.cgColor, NSColor(white: 0.94, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
g.drawLinearGradient(paper, start: CGPoint(x: 0, y: bg.maxY), end: CGPoint(x: 0, y: bg.minY), options: [])
g.restoreGState()
g.addPath(bgPath); g.setStrokeColor(NSColor(white: 0.82, alpha: 1).cgColor); g.setLineWidth(3); g.strokePath()

// 拉开了一半的拉链，做成精致的质感：下半截是一条细接缝和浅灰的小齿，上半截拉开成一道深色的口子，交汇处是带金属光泽的小拉头
let cx: CGFloat = 512, pullY: CGFloat = 600   // 拉头所在高度（口子从这里往上张开）
// 接缝和齿
g.setFillColor(NSColor(white: 0.70, alpha: 1).cgColor)
var ty: CGFloat = 250
var side = true
while ty < pullY - 120 {
    g.addPath(CGPath(roundedRect: CGRect(x: side ? cx - 26 : cx, y: ty, width: 26, height: 10), cornerWidth: 4, cornerHeight: 4, transform: nil)); g.fillPath()
    ty += 18; side.toggle()
}
g.setStrokeColor(NSColor(white: 0.72, alpha: 1).cgColor); g.setLineWidth(3)
g.move(to: CGPoint(x: cx, y: 244)); g.addLine(to: CGPoint(x: cx, y: pullY - 100)); g.strokePath()
// 口子：底尖顶宽的杏仁形，里面是深色渐变，像布面被拉开露出的里层
let gap = CGMutablePath()
gap.move(to: CGPoint(x: cx, y: pullY - 40))
gap.addCurve(to: CGPoint(x: cx - 74, y: 790), control1: CGPoint(x: cx - 20, y: pullY + 70), control2: CGPoint(x: cx - 74, y: 700))
gap.addQuadCurve(to: CGPoint(x: cx + 74, y: 790), control: CGPoint(x: cx, y: 806))
gap.addCurve(to: CGPoint(x: cx, y: pullY - 40), control1: CGPoint(x: cx + 74, y: 700), control2: CGPoint(x: cx + 20, y: pullY + 70))
g.saveGState()
g.addPath(gap); g.clip()
let inside = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0.30, alpha: 1).cgColor, NSColor(white: 0.07, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
g.drawLinearGradient(inside, start: CGPoint(x: 0, y: pullY), end: CGPoint(x: 0, y: 810), options: [])
g.restoreGState()
// 口子两边的齿边：细细一圈浅灰描边
g.addPath(gap); g.setStrokeColor(NSColor(white: 0.70, alpha: 1).cgColor); g.setLineWidth(4); g.strokePath()
// 拉头：浅金属渐变的圆角块 + 投影 + 中间一个小孔
let pull = CGRect(x: cx - 34, y: pullY - 150, width: 68, height: 150)
let pullPath = CGPath(roundedRect: pull, cornerWidth: 30, cornerHeight: 30, transform: nil)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor.black.withAlphaComponent(0.28).cgColor)
g.addPath(pullPath); g.setFillColor(NSColor.white.cgColor); g.fillPath()
g.restoreGState()
g.saveGState()
g.addPath(pullPath); g.clip()
let metal = CGGradient(colorsSpace: cs, colors: [NSColor(white: 0.99, alpha: 1).cgColor, NSColor(white: 0.86, alpha: 1).cgColor, NSColor(white: 0.74, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
g.drawLinearGradient(metal, start: CGPoint(x: pull.minX, y: pull.maxY), end: CGPoint(x: pull.maxX, y: pull.minY), options: [])
g.restoreGState()
g.addPath(pullPath); g.setStrokeColor(NSColor(white: 0.62, alpha: 1).cgColor); g.setLineWidth(2.5); g.strokePath()
g.addPath(CGPath(roundedRect: CGRect(x: cx - 11, y: pull.minY + 24, width: 22, height: 54), cornerWidth: 11, cornerHeight: 11, transform: nil))
g.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor); g.fillPath()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
