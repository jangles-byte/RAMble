// Composites a transparent --snapshot PNG over a dark desktop-like backdrop
// so the render is viewable anywhere (the raw output is glow-on-transparent
// and looks blank on white). Used by CI and handy locally:
//   swift scripts/composite-snapshot.swift in.png out.png
import AppKit

let args = CommandLine.arguments
guard args.count > 2, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: composite-snapshot in.png out.png\n".utf8))
    exit(1)
}
let size = src.size
let img = NSImage(size: size)
img.lockFocus()
let grad = NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1),
                      ending: NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.06, alpha: 1))!
grad.draw(in: NSRect(origin: .zero, size: size), angle: -90)
src.draw(in: NSRect(origin: .zero, size: size))
img.unlockFocus()
guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
