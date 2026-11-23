// 生成 tvOS 图标资源（Asset Catalog 的 brandassets 结构）并写入 src/gui/Assets.xcassets
//
//   swift src/gui/make-icon.swift
//
// tvOS 与 iOS 不同：主屏图标来自 "App Icon & Top Shelf Image.brandassets"，
// 里面是按尺寸分的 imagestack，每个 stack 又分 Back / Middle / Front 三层（视差用）。
// 这里三层都画：Back 是完整画面，Middle 放主体（同图稍亮），Front 全透明（留给高光）。
//
// 尺寸：Small 400x240（@2x 800x480）、Large 1280x768（@2x 2560x1536）。

import AppKit
import CoreGraphics
import Foundation

let root = "src/gui/Assets.xcassets"
let brand = "\(root)/App Icon & Top Shelf Image.brandassets"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// 画图标主体。transparent=true 时输出全透明（用作空图层）。
func drawIcon(w: Int, h: Int, transparent: Bool = false,
              glow: CGFloat = 1.0) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    if transparent { return ctx.makeImage()! }

    // 背景：深色 → 墨绿斜向渐变
    let grad = CGGradient(colorsSpace: cs,
                          colors: [color(0x0E1116), color(0x102A21)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H),
                           end: CGPoint(x: W, y: 0), options: [])

    // 电视机外框
    let screenW = W * 0.60, screenH = screenW * 0.56
    let screen = CGRect(x: (W - screenW) / 2, y: H * 0.56 - screenH / 2,
                        width: screenW, height: screenH)
    let radius = screenW * 0.10
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: radius,
                       cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(color(0x2EE59D, 0.95 * glow))
    ctx.setLineWidth(max(2, W * 0.016))
    ctx.strokePath()

    // 屏幕里的向下箭头（安装）
    let cx = W / 2
    let headW = screenW * 0.17
    let tipY = screen.minY + screenH * 0.26
    let topY = screen.maxY - screenH * 0.26
    ctx.move(to: CGPoint(x: cx, y: tipY))
    ctx.addLine(to: CGPoint(x: cx + headW, y: tipY + headW * 1.0))
    ctx.addLine(to: CGPoint(x: cx + headW * 0.40, y: tipY + headW * 1.0))
    ctx.addLine(to: CGPoint(x: cx + headW * 0.40, y: topY))
    ctx.addLine(to: CGPoint(x: cx - headW * 0.40, y: topY))
    ctx.addLine(to: CGPoint(x: cx - headW * 0.40, y: tipY + headW * 1.0))
    ctx.addLine(to: CGPoint(x: cx - headW, y: tipY + headW * 1.0))
    ctx.closePath()
    ctx.setFillColor(color(0x2EE59D, glow))
    ctx.fillPath()

    // 电视底座
    let baseW = screenW * 0.32, baseH = max(3, H * 0.028)
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - baseW / 2, y: screen.minY - H * 0.06,
                                           width: baseW, height: baseH),
                       cornerWidth: baseH / 2, cornerHeight: baseH / 2, transform: nil))
    ctx.setFillColor(color(0x2EE59D, 0.75 * glow))
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

func writeJSON(_ path: String, _ obj: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: obj,
                                        options: [.prettyPrinted, .sortedKeys])
    try! d.write(to: URL(fileURLWithPath: path))
}

try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
writeJSON("\(root)/Contents.json", ["info": ["author": "xcode", "version": 1]])

// brandassets 容器
let fm = FileManager.default
try? fm.createDirectory(atPath: brand, withIntermediateDirectories: true)

struct Size { let name: String; let w: Int; let h: Int }
let sizes = [Size(name: "App Icon - Small", w: 400, h: 240),
             Size(name: "App Icon - Large", w: 1280, h: 768)]

var brandAssets: [[String: String]] = []
for s in sizes {
    let stack = "\(brand)/\(s.name).imagestack"
    brandAssets.append(["filename": "\(s.name).imagestack", "idiom": "tv"])
    try? fm.createDirectory(atPath: stack, withIntermediateDirectories: true)

    var layers: [[String: String]] = []
    for layer in ["Back", "Middle"] {
        let layerDir = "\(stack)/\(layer).imagestacklayer"
        try? fm.createDirectory(atPath: layerDir, withIntermediateDirectories: true)
        layers.append(["filename": "\(layer).imagestacklayer"])

        // Back 画主体；Middle 只留主体（更亮一点，视差有层次）；Front 透明
        let img: CGImage
        // tvOS 要求至少 2 层，且最后一层必须不透明：
        // Back = 暗底，Middle = 主体（两者都是不透明整图，视差由系统做）
        img = drawIcon(w: s.w, h: s.h, glow: layer == "Back" ? 0.55 : 1.0)

        // 每层是一个 Content.imageset（这是 tvOS brandassets 的实际结构）
        let content = "\(layerDir)/Content.imageset"
        try? fm.createDirectory(atPath: content, withIntermediateDirectories: true)
        writePNG(img, "\(content)/\(layer).png")
        writeJSON("\(content)/Contents.json", [
            "images": [
                ["filename": "\(layer).png", "idiom": "tv", "scale": "1x"],
            ],
            "info": ["author": "xcode", "version": 1],
        ])
        writeJSON("\(layerDir)/Contents.json",
                  ["content": ["filename": "Content.imageset"]])
        print("  \(s.name)/\(layer)")
    }
    writeJSON("\(stack)/Contents.json", [
        "layers": layers.map { ["filename": $0["filename"]!] },
        "info": ["author": "xcode", "version": 1],
    ])
}

writeJSON("\(brand)/Contents.json", [
    "assets": brandAssets,
    "info": ["author": "xcode", "version": 1],
])

// Top Shelf（可选，但 tvOS 会找它；给一张同风格的宽图）
let shelf = "\(brand)/Top Shelf Image Wide.imageset"
try? fm.createDirectory(atPath: shelf, withIntermediateDirectories: true)
print("生成完成 → \(brand)")
