// Renders the arc-reactor app icon: swift tools/make_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let c = CGPoint(x: size / 2, y: size / 2)
let cyan = NSColor(red: 0.25, green: 0.88, blue: 1.0, alpha: 1)

// Rounded-square dark background (macOS icon grid: 824pt body inside 1024).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.04, green: 0.10, blue: 0.15, alpha: 1), NSColor(red: 0.01, green: 0.03, blue: 0.05, alpha: 1)])!
    .draw(in: bg, angle: -90)
bg.addClip()

func ring(_ r: CGFloat, _ width: CGFloat, _ alpha: CGFloat, from: CGFloat = 0, to: CGFloat = 360, dash: [CGFloat]? = nil) {
    ctx.saveGState()
    ctx.setStrokeColor(cyan.withAlphaComponent(alpha).cgColor)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
    ctx.setShadow(offset: .zero, blur: 30, color: cyan.withAlphaComponent(0.8).cgColor)
    ctx.addArc(center: c, radius: r, startAngle: from * .pi / 180, endAngle: to * .pi / 180, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

ring(330, 4, 0.35)
ring(300, 26, 0.6, dash: [6, 22])
ring(240, 14, 1.0, from: 20, to: 280)
ring(185, 22, 0.85, from: 200, to: 330)
ring(185, 22, 0.85, from: 20, to: 120)

// Glowing core.
let core = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.cgColor, cyan.cgColor, cyan.withAlphaComponent(0).cgColor] as CFArray,
                      locations: [0, 0.35, 1])!
ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: 150, options: [])
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
