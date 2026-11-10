// Renders the DMG window background from the Figma frame "57 · Instalação DMG · escuro".
// The window content is 760 × 444 pt; Finder draws the real app and Applications icons on top.
//   swift script/dmg/background.swift <output-dir>   -> background.png (1x) and background@2x.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = NSSize(width: 760, height: 444)
func color(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
func font(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight) }

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color(0x171717).setFill(); NSRect(origin: .zero, size: size).fill()
    // Figma coordinates are top-left with the 48 pt title bar removed.
    func y(_ top: CGFloat, _ height: CGFloat) -> CGFloat { size.height - (top - 48) - height }
    func centered(_ text: String, _ font: NSFont, _ hex: UInt32, top: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(hex), .kern: 0]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (size.width - measured.width) / 2, y: y(top, measured.height)), withAttributes: attributes)
    }
    centered("Instale o Trelune", font("Inter-SemiBold", 26, .semibold), 0xEEEEEB, top: 95)
    centered("Arraste o Trelune para Aplicativos para começar.", font("Inter-Regular", 14, .regular), 0x999995, top: 137)
    // Arrow between the two icons (Figma "Direção de instalação", 68 × 20 at 345, 262).
    let arrow = NSBezierPath()
    let ox: CGFloat = 345, oy = y(262, 20)
    arrow.move(to: NSPoint(x: ox + 2, y: oy + 10)); arrow.line(to: NSPoint(x: ox + 60, y: oy + 10))
    arrow.move(to: NSPoint(x: ox + 52, y: oy + 3)); arrow.line(to: NSPoint(x: ox + 60, y: oy + 10)); arrow.line(to: NSPoint(x: ox + 52, y: oy + 17))
    arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    color(0x999995).setStroke(); arrow.stroke()
    color(0x363636).setFill(); NSRect(x: 44, y: y(401, 1), width: 670, height: 1).fill()
    centered("Depois de copiar, abra o Trelune em Aplicativos.", font("Inter-Regular", 12, .regular), 0x999995, top: 424)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: out).appendingPathComponent("background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: out).appendingPathComponent("background@2x.png"))
