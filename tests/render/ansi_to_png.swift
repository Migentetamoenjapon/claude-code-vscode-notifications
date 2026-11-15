// Renders text with ANSI SGR escape codes (read from stdin) as a PNG of a terminal-like panel.
// No dependencies beyond AppKit. Used by render_statusline.sh to make the status line images.
//
// Usage: ansi_to_png --out <file.png> --theme light|dark [--width <pt>] [--scale <n>]
//
// Supported SGR: 0 reset, 1 bold, 2 dim, 22 normal intensity, 30-37, 90-97, 39, 38;5;n, 38;2;r;g;b.
// Background codes are accepted and ignored. Any other escape sequence is dropped.
import AppKit

// ---------------------------------------------------------------- arguments

var outPath: String?
var themeName = "dark"
var widthPt: CGFloat = 760
var scale: CGFloat = 2

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func value() -> String {
        i += 1
        if i >= args.count { fail("missing value for \(args[i - 1])") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--out": outPath = value()
        case "--theme": themeName = value()
        case "--width":
            guard let v = Double(value()), v > 0 else { fail("bad --width") }
            widthPt = CGFloat(v)
        case "--scale":
            guard let v = Double(value()), v > 0 else { fail("bad --scale") }
            scale = CGFloat(v)
        default: fail("unknown argument \(args[i])")
        }
        i += 1
    }
}
guard let outFile = outPath else { fail("usage: ansi_to_png --out <file.png> --theme light|dark [--width <pt>] [--scale <n>]") }
guard themeName == "light" || themeName == "dark" else { fail("--theme must be light or dark") }
let dark = themeName == "dark"

// ---------------------------------------------------------------- colors

struct RGB { var r: Double; var g: Double; var b: Double }   // 0...1

func hex(_ v: Int) -> RGB {
    RGB(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255)
}

func lum(_ c: RGB) -> Double {
    func ch(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
}

func contrast(_ a: RGB, _ b: RGB) -> Double {
    let la = lum(a), lb = lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
}

let panelBG = dark ? hex(0x1e1e1e) : hex(0xffffff)
let panelBorder = dark ? hex(0x3a3a3a) : hex(0xd9d9d9)
let defaultFG = dark ? hex(0x9aa0a6) : hex(0x5f6368)
let minContrast = 4.5

// The 16 base colors: calm, slightly desaturated, readable on each background.
let base16: [RGB] = (dark
    ? [0x45474a, 0xd07878, 0x8cb98c, 0xcfae6c, 0x7fa8d1, 0xb593c9, 0x7bbdbd, 0xc4c7ca,
       0x6c6f73, 0xe08c8c, 0xa0cda0, 0xe0c283, 0x95bce3, 0xc8a8da, 0x93d0d0, 0xe8eaed]
    : [0x3c4043, 0xb03a3a, 0x2e7d46, 0x8a6100, 0x2f65a8, 0x7b4fa0, 0x137a83, 0x5f6368,
       0x5f6368, 0xc0392b, 0x1e8a3c, 0x8f5f00, 0x1f5fb0, 0x86489e, 0x0e7c86, 0x3c4043]
).map(hex)

// Grays of the 256-color ramp are remapped so the script's hierarchy (value > secondary > label >
// separator) keeps its order on both backgrounds while staying readable. Anchors are input gray
// levels (xterm 237, 241, 245, 250) mapped to output levels.
let grayIn: [Double] = [0x3a, 0x62, 0x8a, 0xbc]
let grayOut: [Double] = dark ? [0x55, 0x80, 0x9a, 0xc8] : [0xc4, 0x74, 0x55, 0x30]

func remapGray(_ v: Double) -> Double {
    if v <= grayIn[0] { return grayOut[0] + (v - grayIn[0]) * (grayOut[1] - grayOut[0]) / (grayIn[1] - grayIn[0]) }
    for k in 0..<(grayIn.count - 1) where v <= grayIn[k + 1] {
        let t = (v - grayIn[k]) / (grayIn[k + 1] - grayIn[k])
        return grayOut[k] + t * (grayOut[k + 1] - grayOut[k])
    }
    let n = grayIn.count - 1
    return grayOut[n] + (v - grayIn[n]) * (grayOut[n] - grayOut[n - 1]) / (grayIn[n] - grayIn[n - 1])
}

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

// Moves a color toward the text-extreme (white on dark, black on light) until it reads on the panel.
func ensureContrast(_ c: RGB, floor: Double = minContrast) -> RGB {
    var out = c
    let target = dark ? RGB(r: 1, g: 1, b: 1) : RGB(r: 0, g: 0, b: 0)
    var t = 0.0
    while contrast(out, panelBG) < floor && t < 1 {
        t += 0.02
        out = mix(c, target, t)
    }
    return out
}

func xterm256(_ n: Int) -> RGB {
    if n < 16 { return base16[n] }
    var raw: RGB
    if n >= 232 {
        let v = Double(8 + (n - 232) * 10) / 255
        raw = RGB(r: v, g: v, b: v)
    } else {
        let m = n - 16
        let levels: [Double] = [0, 95, 135, 175, 215, 255]
        raw = RGB(r: levels[(m / 36) % 6] / 255, g: levels[(m / 6) % 6] / 255, b: levels[m % 6] / 255)
    }
    return adapt(raw)
}

// Colors from 38;5;n and 38;2;r;g;b: grays are remapped, colored values are slightly desaturated
// and then pushed to a readable contrast.
func adapt(_ raw: RGB) -> RGB {
    if abs(raw.r - raw.g) < 0.01 && abs(raw.g - raw.b) < 0.01 {
        let v = clamp01(remapGray(raw.r * 255) / 255)
        return RGB(r: v, g: v, b: v)
    }
    let gray = (raw.r + raw.g + raw.b) / 3
    let soft = mix(raw, RGB(r: gray, g: gray, b: gray), 0.12)
    return ensureContrast(soft)
}

// ---------------------------------------------------------------- ANSI parsing

struct Style {
    var fg: RGB? = nil      // nil = default foreground
    var bold = false
    var dim = false
}

struct Run { var text: String; var style: Style }

func parseANSI(_ input: String) -> [[Run]] {
    var lines: [[Run]] = [[]]
    var style = Style()
    var buf = ""
    func flush() {
        if !buf.isEmpty { lines[lines.count - 1].append(Run(text: buf, style: style)); buf = "" }
    }
    let s = Array(input.unicodeScalars)
    var i = 0
    while i < s.count {
        let ch = s[i]
        if ch == "\u{1B}" {
            flush()
            i += 1
            if i < s.count, s[i] == "[" {
                i += 1
                var params = ""
                while i < s.count, !(s[i].value >= 0x40 && s[i].value <= 0x7E) {
                    params.unicodeScalars.append(s[i]); i += 1
                }
                let final = i < s.count ? s[i] : "m"
                i += 1
                if final == "m" { applySGR(params, &style) }
            }
            continue
        }
        if ch == "\n" { flush(); lines.append([]); i += 1; continue }
        if ch == "\r" { i += 1; continue }
        buf.unicodeScalars.append(ch)
        i += 1
    }
    flush()
    return lines
}

func applySGR(_ params: String, _ style: inout Style) {
    let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    let list = codes.isEmpty ? [0] : codes
    var i = 0
    while i < list.count {
        let c = list[i]
        switch c {
        case 0: style = Style()
        case 1: style.bold = true
        case 2: style.dim = true
        case 22: style.bold = false; style.dim = false
        case 30...37: style.fg = base16[c - 30]
        case 90...97: style.fg = base16[c - 90 + 8]
        case 39: style.fg = nil
        case 38, 48:
            var color: RGB? = nil
            if i + 2 < list.count, list[i + 1] == 5 {
                if c == 38 { color = xterm256(min(255, max(0, list[i + 2]))) }
                i += 2
            } else if i + 4 < list.count, list[i + 1] == 2 {
                if c == 38 {
                    color = adapt(RGB(r: Double(min(255, list[i + 2])) / 255,
                                      g: Double(min(255, list[i + 3])) / 255,
                                      b: Double(min(255, list[i + 4])) / 255))
                }
                i += 4
            }
            if c == 38, let col = color { style.fg = col }
        default: break
        }
        i += 1
    }
}

// ---------------------------------------------------------------- drawing

let data = FileHandle.standardInput.readDataToEndOfFile()
var text = String(decoding: data, as: UTF8.self)
while text.hasSuffix("\n") { text.removeLast() }
let lines = parseANSI(text)

let padX: CGFloat = 14
let padY: CGFloat = 12
let radius: CGFloat = 10

func makeFont(size: CGFloat, bold: Bool) -> NSFont {
    let weight: NSFont.Weight = bold ? .semibold : .regular
    // The system monospaced font is SF Mono; fall back to Menlo if it is not a fixed-pitch font.
    let system = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    if system.isFixedPitch { return system }
    return NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size) ?? system
}

func foreground(_ st: Style) -> NSColor {
    var c = st.fg ?? defaultFG
    if st.dim {
        c = ensureContrast(mix(c, panelBG, 0.25), floor: 4.0)
    }
    return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
}

func attributed(_ line: [Run], size: CGFloat) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for run in line {
        out.append(NSAttributedString(string: run.text, attributes: [
            .font: makeFont(size: size, bold: run.style.bold),
            .foregroundColor: foreground(run.style),
        ]))
    }
    return out
}

// Pick the largest font size (12 down to 11 pt, 0.5 pt steps) whose widest line fits the panel.
var fontSize: CGFloat = 12
func widest(_ size: CGFloat) -> CGFloat {
    lines.map { ceil(attributed($0, size: size).size().width) }.max() ?? 0
}
while widest(fontSize) > widthPt - 2 * padX && fontSize > 11 { fontSize -= 0.5 }
if widest(fontSize) > widthPt - 2 * padX {
    fail("line does not fit in \(widthPt) pt even at \(fontSize) pt")
}

let strings = lines.map { attributed($0, size: fontSize) }
let lineHeight = ceil(strings.map { $0.size().height }.max() ?? fontSize * 1.2)
let heightPt = lineHeight * CGFloat(max(1, strings.count)) + 2 * padY

let pxW = Int((widthPt * scale).rounded()), pxH = Int((heightPt * scale).rounded())
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fail("cannot create bitmap") }
rep.size = NSSize(width: widthPt, height: heightPt)   // set first: drawing below is in points
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fail("cannot create context") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.cgContext.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
ctx.shouldAntialias = true
ctx.imageInterpolation = .high

func ns(_ c: RGB) -> NSColor { NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1) }

// Panel: filled rounded rectangle, then a 1 px border drawn fully inside it on all four sides.
let full = NSRect(x: 0, y: 0, width: widthPt, height: heightPt)
ns(panelBG).setFill()
NSBezierPath(roundedRect: full, xRadius: radius, yRadius: radius).fill()
let border = 1 / scale
let inner = full.insetBy(dx: border / 2, dy: border / 2)
let borderPath = NSBezierPath(roundedRect: inner, xRadius: radius - border / 2, yRadius: radius - border / 2)
borderPath.lineWidth = border
ns(panelBorder).setStroke()
borderPath.stroke()

// Text, vertically centered. AppKit's origin is bottom-left, so the first line is the topmost.
for (n, str) in strings.enumerated() {
    let top = heightPt - padY - lineHeight * CGFloat(n)
    str.draw(in: NSRect(x: padX, y: top - lineHeight, width: widthPt - padX, height: lineHeight))
}
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fail("cannot encode PNG") }
do { try png.write(to: URL(fileURLWithPath: outFile)) } catch { fail("cannot write \(outFile): \(error)") }
FileHandle.standardError.write("ansi_to_png: \(outFile) \(pxW)x\(pxH) px, font \(fontSize) pt\n".data(using: .utf8)!)
