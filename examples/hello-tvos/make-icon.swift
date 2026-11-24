// 生成 TSLTVDemo 的 tvOS 图标（与 TrollStore Lite TV 反色区分：亮色底 + 琥珀/深色电视轮廓）
//
//   swift examples/hello-tvos/make-icon.swift <输出 Assets.xcassets 目录>

import AppKit
import CoreGraphics
import Foundation

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "examples/hello-tvos/Assets.xcassets"
let brand = "\(root)/AppIcon.brandassets"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawDemoIcon(w: Int, h: Int, isFront: Bool) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)

    if !isFront {
        // 反色风格：高对比度浅薄荷/白灰斜向渐变底，一眼和深色主应用区分
        let grad = CGGradient(colorsSpace: cs,
                              colors: [color(0xF1F5F9), color(0xCCFBF1)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H),
                               end: CGPoint(x: W, y: 0), options: [])
        return ctx.makeImage()!
    }

    // 前景层（透明底，保留 tvOS 视差）：深色电视外框 + 琥珀色播放/测试三角
    let screenW = W * 0.58, screenH = screenW * 0.56
    let screen = CGRect(x: (W - screenW) / 2, y: H * 0.56 - screenH / 2,
                        width: screenW, height: screenH)
    let radius = screenW * 0.10
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: radius,
                       cornerHeight: radius, transform: nil))
    ctx.setFillColor(color(0x0F172A, 0.94))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: radius,
                       cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(color(0xF59E0B, 1.0))
    ctx.setLineWidth(max(2, W * 0.018))
    ctx.strokePath()

    // 屏幕内琥珀色播放/验证三角
    let cx = W / 2, cy = screen.midY
    let tw = screenH * 0.34, th = screenH * 0.42
    ctx.move(to: CGPoint(x: cx - tw * 0.40, y: cy - th / 2))
    ctx.addLine(to: CGPoint(x: cx - tw * 0.40, y: cy + th / 2))
    ctx.addLine(to: CGPoint(x: cx + tw * 0.65, y: cy))
    ctx.closePath()
    ctx.setFillColor(color(0xF59E0B, 1.0))
    ctx.fillPath()

    // 底座
    let baseW = screenW * 0.34, baseH = max(3, H * 0.032)
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - baseW / 2, y: screen.minY - H * 0.07,
                                           width: baseW, height: baseH),
                       cornerWidth: baseH / 2, cornerHeight: baseH / 2, transform: nil))
    ctx.setFillColor(color(0x0F172A, 0.85))
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func writeJSON(_ path: String, _ obj: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try! d.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
try? fm.removeItem(atPath: root)
try! fm.createDirectory(atPath: brand, withIntermediateDirectories: true)
writeJSON("\(root)/Contents.json", ["info": ["author": "xcode", "version": 1]])

let specs = [
    ("AppIconSmall", "primary-app-icon", "400x240", 400, 240),
    ("AppIconLarge", "primary-app-icon", "1280x768", 1280, 768),
]
var assets: [[String: String]] = []
for (name, role, sz, w, h) in specs {
    let stack = "\(brand)/\(name).imagestack"
    assets.append(["filename": "\(name).imagestack", "idiom": "tv", "role": role, "size": sz])
    try! fm.createDirectory(atPath: stack, withIntermediateDirectories: true)
    // tvOS imagestack 顺序：Front 在前（可透明），Back 在后（必须不透明）
    var layers: [[String: String]] = []
    for (layerName, isFront) in [("Front", true), ("Back", false)] {
        let ldir = "\(stack)/\(layerName).imagestacklayer"
        let content = "\(ldir)/Content.imageset"
        try! fm.createDirectory(atPath: content, withIntermediateDirectories: true)
        writePNG(drawDemoIcon(w: w, h: h, isFront: isFront), "\(content)/\(layerName).png")
        writeJSON("\(content)/Contents.json", [
            "images": [["filename": "\(layerName).png", "idiom": "tv", "scale": "1x"]],
            "info": ["author": "xcode", "version": 1],
        ])
        writeJSON("\(ldir)/Contents.json", ["content": ["filename": "Content.imageset"]])
        layers.append(["filename": "\(layerName).imagestacklayer"])
    }
    writeJSON("\(stack)/Contents.json", ["layers": layers, "info": ["author": "xcode", "version": 1]])
}
writeJSON("\(brand)/Contents.json", ["assets": assets, "info": ["author": "xcode", "version": 1]])
