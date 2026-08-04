import AppKit

// Renders the Harbor HomeKit Setup disk-image background: brand logo on top,
// an arrow between the app-icon and Applications-folder drop positions, and an
// install instruction. Drawn at 2x and tagged with point dimensions so Finder
// shows it crisp on Retina displays.
//
// Usage: swift RenderDMGBackground.swift <HarborLogo.svg> <output.png>

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: RenderDMGBackground <logo.svg> <output.png>\n".utf8))
    exit(1)
}
let logoPath = arguments[1]
let outputPath = arguments[2]

// Must match the window bounds and icon positions in build-macos-setup-dmg.sh.
let pointSize = NSSize(width: 600, height: 400)
let scale: CGFloat = 2
let appIconCenter = NSPoint(x: 150, y: pointSize.height - 190)
let applicationsCenter = NSPoint(x: 450, y: pointSize.height - 190)

let brand = NSColor(calibratedRed: 168 / 255, green: 94 / 255, blue: 138 / 255, alpha: 1)
let highlight = NSColor(calibratedRed: 237 / 255, green: 244 / 255, blue: 249 / 255, alpha: 1)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(pointSize.width * scale),
    pixelsHigh: Int(pointSize.height * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Could not create drawing context.\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let transform = NSAffineTransform()
transform.scale(by: scale)
transform.concat()

let canvas = NSRect(origin: .zero, size: pointSize)
NSColor.white.setFill()
canvas.fill()
NSGradient(starting: highlight, ending: .white)?.draw(in: canvas, angle: -90)

if let logo = NSImage(contentsOf: URL(fileURLWithPath: logoPath)) {
    let logoSize = NSSize(width: 174, height: 42)
    logo.draw(in: NSRect(
        x: (pointSize.width - logoSize.width) / 2,
        y: pointSize.height - logoSize.height - 30,
        width: logoSize.width,
        height: logoSize.height
    ))
}

// Arrow from the app icon toward the Applications folder.
let arrowY = appIconCenter.y
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: appIconCenter.x + 88, y: arrowY))
shaft.line(to: NSPoint(x: applicationsCenter.x - 120, y: arrowY))
shaft.lineWidth = 10
shaft.lineCapStyle = .round
brand.setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: applicationsCenter.x - 122, y: arrowY + 20))
head.line(to: NSPoint(x: applicationsCenter.x - 92, y: arrowY))
head.line(to: NSPoint(x: applicationsCenter.x - 122, y: arrowY - 20))
head.close()
brand.setFill()
head.fill()

let caption = "Drag Harbor HomeKit Setup into Applications to install" as NSString
let captionAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor.darkGray,
]
let captionSize = caption.size(withAttributes: captionAttributes)
caption.draw(
    at: NSPoint(x: (pointSize.width - captionSize.width) / 2, y: 52),
    withAttributes: captionAttributes
)

NSGraphicsContext.restoreGraphicsState()

// Point size below pixel size marks the PNG as 144 DPI for Finder.
bitmap.size = pointSize
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the background PNG.\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("Could not write \(outputPath): \(error)\n".utf8))
    exit(1)
}
