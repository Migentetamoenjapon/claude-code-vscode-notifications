// CCNotify popup: a small translucent card (top-right of the screen) that shows Claude Code's last
// message rendered as Markdown (bold, italics, `code`, lists, headings, real tables, code fences,
// scrolling for long messages) when Claude finishes or needs you.
//
// Usage:  ccnotify-popup <input.json>     (the app deletes the file after reading it)
// Input:  see docs/ARCHITECTURE.md ("Popup input JSON"). Only title, kind and text are needed.
//
// Behaviour in short
//   * Click anywhere -> jump to the conversation (focus_session.py, run with argv, never a shell).
//     The X appears on hover. Hovering pauses the auto-dismiss timer.
//   * "done" popups close by themselves after `seconds` (the timer also pauses while you are idle).
//     "Needs you" kinds (permission, question, agent) are sticky: they close when the conversation
//     moves on, on click, or on X.
//   * Stacking: newest on top and fully open; older ones collapse to 3 lines (expand on hover).
//     Each popup registers itself in state/active/<id>__<pid>.
//   * Test hooks: CCNOTIFY_CAPTURE=<file.png>, CCNOTIFY_THEME=light|dark, CCNOTIFY_COMPACT=1.
import Cocoa
import Darwin

// MARK: - Paths and environment

let env = ProcessInfo.processInfo.environment

let ccHome: String = {
    if let h = env["CCNOTIFY_HOME"], !h.isEmpty { return (h as NSString).expandingTildeInPath }
    let claudeDir = (env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.claude")
    return (claudeDir as NSString).expandingTildeInPath + "/ccnotify"
}()
let stateDir = ccHome + "/state"
let activeDir = stateDir + "/active"
let seenDir = stateDir + "/seen"
let lastSoundFile = stateDir + "/last-sound"
let focusScript = ccHome + "/bin/focus_session.py"
let captureTarget: String? = env["CCNOTIFY_CAPTURE"]
let compactTest = env["CCNOTIFY_COMPACT"] == "1"

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
}

func writePrivate(_ text: String, to path: String) {
    guard let data = text.data(using: .utf8) else { return }
    let tmp = path + ".tmp\(getpid())"
    if FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) {
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp) }
    }
}

func safeName(_ s: String) -> String {
    // Same rule as notify.py: only [A-Za-z0-9._-], at most 128 chars, no leading dots
    let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    var cleaned = String(String(s.prefix(128)).map { ok.contains($0) ? $0 : "_" })
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    return cleaned.isEmpty ? "unknown" : cleaned
}

@_silgen_name("proc_pidpath")
func c_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: UInt32) -> Int32

/// Full path of the executable running as `pid`, or nil if there is no such process.
func executablePath(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let n = c_proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard n > 0 else { return nil }
    return String(cString: buffer)
}

// MARK: - Input

enum Kind: String {
    case done, permission, question, agent

    var needsYou: Bool { self != .done }

    /// SF Symbol candidates, first one that exists wins. `filled` (style "mono", needs-you kinds)
    /// prefers the filled variants.
    func symbols(filled: Bool) -> [String] {
        switch self {
        case .done: return ["checkmark.circle"]
        case .permission: return filled ? ["hand.raised.fill", "hand.raised"] : ["hand.raised"]
        case .question:
            return filled ? ["questionmark.bubble.fill", "questionmark.circle.fill", "questionmark.circle"]
                          : ["questionmark.bubble", "questionmark.circle"]
        case .agent:
            return filled ? ["person.crop.circle.badge.questionmark.fill", "questionmark.circle.fill", "questionmark.circle"]
                          : ["person.crop.circle.badge.questionmark", "questionmark.circle"]
        }
    }

    /// Hue per kind for style "color" (a validated categorical set): done green, permission
    /// orange, question blue, agent violet.
    var hue: (light: UInt32, dark: UInt32) {
        switch self {
        case .done: return (0x1BAF7A, 0x199E70)
        case .permission: return (0xEB6834, 0xD95926)
        case .question: return (0x2A78D6, 0x3987E5)
        case .agent: return (0x6250D6, 0x9085E9)
        }
    }

    /// Darker (light mode) / lighter (dark mode) step of the hue for text and symbols: at least
    /// 4.5:1 on the card in both themes.
    var hueText: (light: UInt32, dark: UInt32) {
        switch self {
        case .done: return (0x11704E, 0x39AC84)
        case .permission: return (0xA04723, 0xE17E56)
        case .question: return (0x2260AB, 0x5D9DEA)
        case .agent: return (0x5C4BC9, 0x9B91EB)
        }
    }

    var defaultSound: String {
        switch self {
        case .done: return "Glass"
        case .permission: return "Submarine"
        case .question: return "Ping"
        case .agent: return "Purr"
        }
    }

    var defaultVolume: Double {
        switch self {
        case .done: return 0.5
        case .permission, .question: return 0.8
        case .agent: return 0.7
        }
    }
}

struct FocusTarget {
    var host = ""
    var cwd = ""
    var pid: Int?
    var job = ""   // background session id (claude --bg)
}

struct Input {
    var title = "Claude"
    var kind = Kind.done
    var text = ""
    var id = ""
    var session = ""
    var host = ""
    var transcript = ""
    var language = "auto"
    var sound: String?
    var volume: Double?
    var onlyWhenAway: Bool?
    var seconds = 60.0
    var width = 460.0
    var maxHeightRatio = 0.6
    var maxStacked = 4
    var fontSize = 13.0
    var stickyNeedsYou = true
    var isPrivate = false
    var style = Style.standard
    var compactLines = 2
    var focus = FocusTarget()
    var transcriptSize: UInt64?
    var eventAt = 0.0
}

func number(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

func readInput() -> Input {
    var d = Input()
    let args = CommandLine.arguments
    guard args.count > 1,
          let data = FileManager.default.contents(atPath: args[1]),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return d }
    if captureTarget == nil { try? FileManager.default.removeItem(atPath: args[1]) }

    if let v = o["title"] as? String, !v.isEmpty { d.title = v }
    if let v = o["kind"] as? String {
        let k = v.lowercased()
        d.kind = Kind(rawValue: k) ?? (k == "input" ? .question : .done)
    }
    if let v = o["text"] as? String { d.text = v }
    if let v = o["id"] as? String { d.id = v }
    if let v = o["session"] as? String { d.session = v }
    if let v = o["host"] as? String { d.host = v }
    if let v = o["transcript"] as? String { d.transcript = v }
    if let v = o["language"] as? String { d.language = v }
    if let v = o["sound"] as? String { d.sound = v }
    d.volume = number(o["volume"])
    if let v = o["only_when_away"] as? Bool { d.onlyWhenAway = v }
    if let v = number(o["seconds"]), v > 0 { d.seconds = v }
    if let v = number(o["width"]) { d.width = min(max(v, 320), 900) }
    if let v = number(o["max_height_ratio"]) { d.maxHeightRatio = min(max(v, 0.2), 0.95) }
    if let v = number(o["max_stacked"]) { d.maxStacked = max(1, Int(v)) }
    if let v = number(o["font_size"]) { d.fontSize = min(max(v, 10), 24) }
    if let v = o["sticky_needs_you"] as? Bool { d.stickyNeedsYou = v }
    if let v = o["private"] as? Bool { d.isPrivate = v }
    if let v = o["style"] as? String, let st = Style(rawValue: v.lowercased()) { d.style = st }
    if let v = number(o["compact_lines"]) { d.compactLines = min(max(Int(v), 1), 8) }
    if let f = o["focus"] as? [String: Any] {
        d.focus.host = (f["host"] as? String) ?? ""
        d.focus.cwd = (f["cwd"] as? String) ?? ""
        if let p = number(f["pid"]), p > 0 { d.focus.pid = Int(p) }
        d.focus.job = (f["job"] as? String) ?? ""
    }
    if d.focus.host.isEmpty { d.focus.host = d.host }
    if let v = number(o["transcript_size"]), v >= 0 { d.transcriptSize = UInt64(v) }
    d.eventAt = number(o["event_at"]) ?? 0
    if d.id.isEmpty { d.id = d.session.isEmpty ? "ccnotify" : String(d.session.prefix(12)) }
    return d
}

// MARK: - Localization

struct Strings {
    let es: Bool

    init(language: String) {
        switch language.lowercased() {
        case "es": es = true
        case "en": es = false
        default: es = (Locale.preferredLanguages.first ?? "en").hasPrefix("es")
        }
    }

    func label(_ k: Kind) -> String {
        switch k {
        case .done: return es ? "Terminó" : "Done"
        case .permission: return es ? "Pide permiso" : "Needs permission"
        case .question: return es ? "Pregunta" : "Question"
        case .agent: return es ? "Un agente pregunta" : "Agent asks"
        }
    }

    var close: String { es ? "Cerrar" : "Close" }
    var open: String { es ? "Abrir la conversación" : "Open the conversation" }
}

// MARK: - Colors (dynamic: they follow light/dark live)

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

let accessibility = NSWorkspace.shared
let reduceTransparency = accessibility.accessibilityDisplayShouldReduceTransparency
let increaseContrast = accessibility.accessibilityDisplayShouldIncreaseContrast
let reduceMotion = accessibility.accessibilityDisplayShouldReduceMotion

enum Style: String {
    case standard = "default", color, mono
}

struct Palette {
    let tint, border, divider, cardBorder, kindTint, ink, text, gray, code, codeBackground, link, stand: NSColor
    /// Optional hue laid over the whole card surface (style "color").
    let overlay: NSColor?
    let cardBorderWidth: CGFloat

    static func make(style: Style, kind: Kind) -> Palette {
        let veilAlphaLight: CGFloat = reduceTransparency ? 1 : 0.58
        let veilAlphaDark: CGFloat = reduceTransparency ? 1 : 0.62
        let extra: CGFloat = increaseContrast ? 0.5 : 0
        let divider = dynamic(light: NSColor(hex: 0x000000, alpha: increaseContrast ? 0.28 : 0.10),
                              dark: NSColor(hex: 0xFFFFFF, alpha: increaseContrast ? 0.35 : 0.12))
        let borderAlpha: CGFloat = increaseContrast ? 0.45 : 0.10
        let borderAlphaDark: CGFloat = increaseContrast ? 0.60 : 0.12

        switch style {
        case .mono:
            // Grayscale only: no hue anywhere. Needs-you kinds get a stronger, darker full border.
            let border = dynamic(light: NSColor(hex: 0x000000, alpha: borderAlpha),
                                 dark: NSColor(hex: 0xFFFFFF, alpha: borderAlphaDark))
            let strong = dynamic(light: NSColor(hex: 0x4A4A4A), dark: NSColor(hex: 0xBDBDBD))
            let ink = dynamic(light: NSColor(hex: 0x111111), dark: NSColor(hex: 0xF2F2F2))
            return Palette(
                tint: dynamic(light: NSColor(hex: 0xF7F7F7, alpha: veilAlphaLight),
                              dark: NSColor(hex: 0x262626, alpha: veilAlphaDark)),
                border: border, divider: divider,
                cardBorder: kind.needsYou ? strong : border,
                kindTint: kind.needsYou ? ink : dynamic(light: NSColor(hex: 0x6E6E6E), dark: NSColor(hex: 0x9A9A9A)),
                ink: ink,
                text: dynamic(light: NSColor(hex: increaseContrast ? 0x111111 : 0x3A3A3A),
                              dark: NSColor(hex: increaseContrast ? 0xF2F2F2 : 0xDDDDDD)),
                gray: dynamic(light: NSColor(hex: increaseContrast ? 0x4A4A4A : 0x6E6E6E),
                              dark: NSColor(hex: increaseContrast ? 0xC8C8C8 : 0x9A9A9A)),
                code: ink,
                codeBackground: dynamic(light: NSColor(hex: 0x000000, alpha: 0.08),
                                        dark: NSColor(hex: 0xFFFFFF, alpha: 0.12)),
                link: ink,
                stand: dynamic(light: NSColor(hex: 0xEDEDED), dark: NSColor(hex: 0x1E1E1E)),
                overlay: nil,
                cardBorderWidth: (kind.needsYou ? 1.5 : 1) + extra)

        case .color:
            // One hue per kind. Label and symbol use a darker (light mode) or lighter (dark mode)
            // step of the hue so their contrast on the card is at least 4.5:1.
            let hueText = dynamic(light: NSColor(hex: kind.hueText.light), dark: NSColor(hex: kind.hueText.dark))
            let borderStrength: CGFloat = kind.needsYou ? 0.95 : 0.45
            return Palette(
                tint: dynamic(light: NSColor(hex: 0xFAF9F5, alpha: veilAlphaLight),
                              dark: NSColor(hex: 0x262624, alpha: veilAlphaDark)),
                border: dynamic(light: NSColor(hex: 0x000000, alpha: borderAlpha),
                                dark: NSColor(hex: 0xFFFFFF, alpha: borderAlphaDark)),
                divider: dynamic(light: NSColor(hex: kind.hue.light, alpha: 0.28),
                                 dark: NSColor(hex: kind.hue.dark, alpha: 0.32)),
                cardBorder: dynamic(light: NSColor(hex: kind.hue.light, alpha: borderStrength),
                                    dark: NSColor(hex: kind.hue.dark, alpha: borderStrength)),
                kindTint: hueText,
                ink: dynamic(light: NSColor(hex: 0x141413), dark: NSColor(hex: 0xF5F4EF)),
                text: dynamic(light: increaseContrast ? NSColor(hex: 0x141413) : NSColor(hex: 0x3D3D3A),
                              dark: increaseContrast ? NSColor(hex: 0xF5F4EF) : NSColor(hex: 0xDCDAD2)),
                gray: dynamic(light: increaseContrast ? NSColor(hex: 0x4A4944) : NSColor(hex: 0x73726C),
                              dark: increaseContrast ? NSColor(hex: 0xC4C2BA) : NSColor(hex: 0x9C9A92)),
                code: hueText,
                codeBackground: dynamic(light: NSColor(hex: kind.hue.light, alpha: 0.10),
                                        dark: NSColor(hex: kind.hue.dark, alpha: 0.16)),
                link: dynamic(light: NSColor(hex: 0x2F62B5), dark: NSColor(hex: 0x8DB4F0)),
                stand: dynamic(light: NSColor(hex: 0xEFEDE6), dark: NSColor(hex: 0x1E1E1D)),
                overlay: dynamic(light: NSColor(hex: kind.hue.light, alpha: 0.07),
                                 dark: NSColor(hex: kind.hue.dark, alpha: 0.08)),
                cardBorderWidth: (kind.needsYou ? 1.25 : 1) + extra)

        case .standard:
            let attentionLight = NSColor(hex: 0xB8532F)
            let attentionDark = NSColor(hex: 0xE8977A)
            let border = dynamic(light: NSColor(hex: 0x000000, alpha: borderAlpha),
                                 dark: NSColor(hex: 0xFFFFFF, alpha: borderAlphaDark))
            let attention = dynamic(light: attentionLight, dark: attentionDark)
            let attentionBorder = dynamic(light: attentionLight.withAlphaComponent(increaseContrast ? 1 : 0.65),
                                          dark: attentionDark.withAlphaComponent(increaseContrast ? 1 : 0.65))
            let gray = dynamic(light: increaseContrast ? NSColor(hex: 0x4A4944) : NSColor(hex: 0x73726C),
                               dark: increaseContrast ? NSColor(hex: 0xC4C2BA) : NSColor(hex: 0x9C9A92))
            return Palette(
                tint: dynamic(light: NSColor(hex: 0xFAF9F5, alpha: veilAlphaLight),
                              dark: NSColor(hex: 0x262624, alpha: veilAlphaDark)),
                border: border, divider: divider,
                cardBorder: kind.needsYou ? attentionBorder : border,
                kindTint: kind.needsYou ? attention : gray,
                ink: dynamic(light: NSColor(hex: 0x141413), dark: NSColor(hex: 0xF5F4EF)),
                text: dynamic(light: increaseContrast ? NSColor(hex: 0x141413) : NSColor(hex: 0x3D3D3A),
                              dark: increaseContrast ? NSColor(hex: 0xF5F4EF) : NSColor(hex: 0xDCDAD2)),
                gray: gray,
                code: dynamic(light: NSColor(hex: 0xB4532F), dark: NSColor(hex: 0xE59A80)),
                codeBackground: dynamic(light: NSColor(hex: 0x000000, alpha: 0.05),
                                        dark: NSColor(hex: 0xFFFFFF, alpha: 0.07)),
                link: dynamic(light: NSColor(hex: 0x2F62B5), dark: NSColor(hex: 0x8DB4F0)),
                stand: dynamic(light: NSColor(hex: 0xEFEDE6), dark: NSColor(hex: 0x1E1E1D)),
                overlay: nil,
                cardBorderWidth: 1 + extra)
        }
    }
}

/// Stretchable rounded-corner mask for the blur view.
func roundedMask(_ r: CGFloat) -> NSImage {
    let side = r * 2 + 1
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

// MARK: - Markdown -> attributed text

extension String {
    /// Groups of the first regex match (0 = whole match), or nil.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }
}

struct Formatter {
    let p: Palette
    let size: CGFloat

    var body: NSFont { .systemFont(ofSize: size) }
    var mono: NSFont { .monospacedSystemFont(ofSize: size - 1.5, weight: .regular) }

    func with(_ f: NSFont, _ trait: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(f, toHaveTrait: trait)
    }

    /// Bold, italics, `code`, ~~strike~~ and [links](url) inside one line.
    func inline(_ s: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let res = NSMutableAttributedString(attributedString:
            (try? NSAttributedString(markdown: s, options: options, baseURL: nil)) ?? NSAttributedString(string: s))
        let all = NSRange(location: 0, length: res.length)
        res.addAttributes([.font: font, .foregroundColor: color], range: all)
        res.enumerateAttribute(.inlinePresentationIntent, in: all) { value, range, _ in
            let raw = (value as? NSNumber)?.uintValue ?? (value as? InlinePresentationIntent)?.rawValue ?? 0
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                res.addAttributes([.font: mono, .foregroundColor: p.code, .backgroundColor: p.codeBackground],
                                  range: range)
                return
            }
            var f = font
            if intent.contains(.stronglyEmphasized) { f = with(f, .boldFontMask) }
            if intent.contains(.emphasized) { f = with(f, .italicFontMask) }
            res.addAttribute(.font, value: f, range: range)
            if intent.contains(.stronglyEmphasized) { res.addAttribute(.foregroundColor, value: p.ink, range: range) }
            if intent.contains(.strikethrough) {
                res.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        res.enumerateAttribute(.link, in: all) { value, range, _ in
            guard value != nil else { return }
            res.removeAttribute(.link, range: range)   // a click goes to the conversation, not to the link
            res.addAttributes([.foregroundColor: p.link, .underlineStyle: NSUnderlineStyle.single.rawValue],
                              range: range)
        }
        return res
    }

    /// Cells of a Markdown table row ("| a | | c |" -> ["a", "", "c"]), keeping empty ones.
    func cells(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A numeric cell ($1,099 · -15.4 % · ~ $865 · 1.23 kg): right-aligned.
    func isNumeric(_ cell: String) -> Bool {
        let clean = cell.replacingOccurrences(of: "*", with: "")
        return clean.firstMatch(#"^[~≈±+\-−]?\s?[$€£]?\d[\d.,]*\s?(%|ms|s|h|kg|lb|cm|mm|in|KB|MB|GB|TB|W|Wh|nits)?$"#) != nil
    }

    /// A real table (NSTextTable): aligned columns, bold header on a soft background, thin full grid.
    /// Long cells wrap inside their own column. A column is right-aligned only when every body cell
    /// is numeric.
    func table(_ rows: [[String]], before: CGFloat) -> NSAttributedString {
        let res = NSMutableAttributedString()
        let n = max(rows.map(\.count).max() ?? 1, 1)
        let t = NSTextTable()
        t.numberOfColumns = n
        t.layoutAlgorithm = .fixedLayoutAlgorithm
        t.setContentWidth(100, type: .percentageValueType)
        t.collapsesBorders = true
        t.hidesEmptyCells = false
        t.setWidth(before, type: .absoluteValueType, for: .margin, edge: .minY)
        t.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        let small = NSFont.systemFont(ofSize: size - 1)
        let bodyRows = rows.count > 1 ? Array(rows.dropFirst()) : rows
        let right = (0..<n).map { col -> Bool in
            let values = bodyRows.map { col < $0.count ? $0[col] : "" }.filter { !$0.isEmpty }
            return !values.isEmpty && values.allSatisfy(isNumeric)
        }
        // Column widths proportional to their longest cell (capped, so one long cell does not take
        // the whole table). Short cells such as `batch_charge()` stay on one line; long ones wrap.
        let weights = (0..<n).map { col -> CGFloat in
            let longest = rows.map { col < $0.count ? $0[col].replacingOccurrences(of: "`", with: "").count : 0 }.max() ?? 0
            return CGFloat(min(max(longest, 4), 42)) * (size * 0.58) + 14
        }
        let totalWeight = weights.reduce(0, +)
        for (i, row) in rows.enumerated() {
            let header = i == 0 && rows.count > 1
            for col in 0..<n {
                let text = col < row.count ? row[col] : ""
                let b = NSTextTableBlock(table: t, startingRow: i, rowSpan: 1, startingColumn: col, columnSpan: 1)
                b.setValue(weights[col] / totalWeight * 100, type: .percentageValueType, for: .width)
                b.setWidth(0.5, type: .absoluteValueType, for: .border)
                b.setBorderColor(p.border)
                b.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
                b.setWidth(3, type: .absoluteValueType, for: .padding, edge: .maxY)
                b.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minX)
                b.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxX)
                if header { b.backgroundColor = p.codeBackground }
                let ps = NSMutableParagraphStyle()
                ps.textBlocks = [b]
                ps.lineSpacing = 1
                ps.alignment = right[col] ? .right : .left
                let cell = inline(text.isEmpty ? " " : text,
                                  font: header ? with(small, .boldFontMask) : small,
                                  color: header ? p.ink : p.text)
                cell.append(NSAttributedString(string: "\n", attributes: [.font: small]))
                cell.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: cell.length))
                res.append(cell)
            }
        }
        return res
    }

    /// The whole message, block by block: headings, bullets, numbered lists, quotes, tables, code.
    /// Spacing: headings get air above and stick to their content; a blank line is a small pause
    /// and `---` a bigger one.
    func blocks(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var inCode = false
        var air: CGFloat = 0
        let lines = md.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let l = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if l.hasPrefix("```") { inCode.toggle(); air = max(air, 6); continue }

            if !inCode && l.hasPrefix("|") {
                var rows: [[String]] = [cells(l)]
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    if t.firstMatch(#"^[|:\-\s]+$"#) == nil { rows.append(cells(t)) }   // skip the |---| row
                    i += 1
                }
                if out.length > 0 && !out.mutableString.hasSuffix("\n") {
                    out.append(NSAttributedString(string: "\n"))
                }
                out.append(table(rows, before: out.length > 0 ? 6 : 0))
                air = 4
                continue
            }

            let para = NSMutableParagraphStyle()
            para.lineSpacing = 2
            para.paragraphSpacing = 4
            var before: CGFloat = 0
            var line: NSMutableAttributedString

            if inCode {
                line = NSMutableAttributedString(string: raw.isEmpty ? " " : raw, attributes: [
                    .font: mono, .foregroundColor: p.code])
                para.lineSpacing = 1
                para.paragraphSpacing = 0
                para.firstLineHeadIndent = 8
                para.headIndent = 8
            } else if l.isEmpty {
                air = max(air, 6)
                continue
            } else if l.firstMatch(#"^(-{3,}|\*{3,}|_{3,})$"#) != nil {
                air = max(air, 12)
                continue
            } else if let m = l.firstMatch(#"^(#{1,6})\s+(.*)$"#) {
                let level = m[1].count
                line = inline(m[2], font: with(.systemFont(ofSize: size + (level <= 2 ? 2 : 1)), .boldFontMask),
                              color: p.ink)
                before = 10
                para.paragraphSpacing = 2
            } else if let m = raw.firstMatch(#"^(\s*)[-*+•]\s+(.*)$"#) {
                let indent = CGFloat(min(m[1].count / 2, 3)) * 14
                line = NSMutableAttributedString(string: "•\t", attributes: [.font: body, .foregroundColor: p.gray])
                line.append(inline(m[2], font: body, color: p.text))
                para.paragraphSpacing = 2
                para.tabStops = [NSTextTab(textAlignment: .left, location: indent + 12)]
                para.firstLineHeadIndent = indent
                para.headIndent = indent + 12
            } else if let m = raw.firstMatch(#"^(\s*)(\d+[.)])\s+(.*)$"#) {
                let indent = CGFloat(min(m[1].count / 2, 3)) * 14
                line = NSMutableAttributedString(string: "\(m[2])\t", attributes: [
                    .font: body, .foregroundColor: p.gray])
                line.append(inline(m[3], font: body, color: p.text))
                para.paragraphSpacing = 2
                para.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
                para.firstLineHeadIndent = indent
                para.headIndent = indent + 18
            } else if let m = l.firstMatch(#"^>\s?(.*)$"#) {
                line = inline(m[1], font: with(body, .italicFontMask), color: p.gray)
                para.firstLineHeadIndent = 10
                para.headIndent = 10
            } else {
                line = inline(l, font: body, color: p.text)
            }

            if out.length > 0 { para.paragraphSpacingBefore = max(before, air) }
            air = 0
            if out.length > 0 && !out.mutableString.hasSuffix("\n") {
                out.append(NSAttributedString(string: "\n"))
            }
            line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        // A message that ends in a table has a trailing newline that would leave an empty row below
        if out.mutableString.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    /// Compact version: everything on running lines (later cut to 3 lines).
    func running(_ md: String) -> NSAttributedString {
        let r = NSMutableAttributedString(attributedString: blocks(md))
        r.mutableString.replaceOccurrences(of: "\t", with: " ", options: [], range: NSRange(location: 0, length: r.length))
        r.mutableString.replaceOccurrences(of: "\n", with: "  ", options: [], range: NSRange(location: 0, length: r.length))
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        para.lineBreakMode = .byWordWrapping
        r.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: r.length))
        return r
    }
}

/// One-line plain text from Markdown, for the VoiceOver announcement.
func plainFirstLine(_ md: String) -> String {
    for raw in md.components(separatedBy: "\n") {
        var l = raw.trimmingCharacters(in: .whitespaces)
        if l.isEmpty || l.hasPrefix("```") || l.firstMatch(#"^[|:\-\s]+$"#) != nil { continue }
        l = l.replacingOccurrences(of: #"[*_`#>|]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if l.isEmpty { continue }
        return l.count > 140 ? String(l.prefix(140)) + "…" : l
    }
    return ""
}

// MARK: - Views

/// Draws the card chrome (tint, full thin border) with `draw(_:)` so it follows light/dark live and
/// also shows up in `cacheDisplay` (test captures). `stand` is an opaque layer under the tint, used
/// only for captures, where the blur behind the window does not exist.
final class ChromeView: NSView {
    var fill = NSColor.clear
    var stroke = NSColor.clear
    var strokeWidth: CGFloat = 1
    var radius: CGFloat = 14
    var stand: NSColor?
    var overlay: NSColor?
    /// Hairline between header and body: y position (flipped) and horizontal inset.
    var dividerY: CGFloat?
    var dividerInset: CGFloat = 12
    var dividerColor = NSColor.clear

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let inset = strokeWidth / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                xRadius: radius - inset, yRadius: radius - inset)
        if let s = stand { s.setFill(); path.fill() }
        fill.setFill()
        path.fill()
        if let o = overlay { o.setFill(); path.fill() }
        if let y = dividerY {
            dividerColor.setFill()
            NSRect(x: dividerInset, y: y, width: bounds.width - 2 * dividerInset, height: 1).fill()
        }
        stroke.setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }
}

/// The whole card: reports hover, and any click that is not on a button counts as "go to the
/// conversation".
final class CardView: NSView {
    override var isFlipped: Bool { true }
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?
    /// Long text lives in a scroll view; the wheel / trackpad is forwarded to it.
    weak var scroller: NSScrollView?

    override func scrollWheel(with event: NSEvent) {
        if let s = scroller, !s.isHidden { s.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        return (v is NSButton || v is NSScroller) ? v : self   // the scroll bar can be dragged
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// Button that reacts to the first click even if the panel is not key.
final class ClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Panel that never steals focus from the app you are working in.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func symbolImage(_ names: [String], description: String? = nil) -> NSImage? {
    for n in names {
        if let img = NSImage(systemSymbolName: n, accessibilityDescription: description) { return img }
    }
    return nil
}

// MARK: - Capture helpers (test hooks only)

func makeRep(_ w: CGFloat, _ h: CGFloat, scale: CGFloat) -> NSBitmapImageRep? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    rep?.size = NSSize(width: w, height: h)
    return rep
}

/// Draws one or more card images (top to bottom, `gap` points apart) over a soft backdrop with
/// shadows and returns a PNG. Uses the current NSApp appearance for the backdrop colors.
func composeOnBackdrop(_ cards: [NSBitmapImageRep], gap: CGFloat, scale: CGFloat, radius: CGFloat) -> Data? {
    let margin: CGFloat = 40
    let cardW = cards.map { $0.size.width }.max() ?? 0
    let cardsH = cards.reduce(0) { $0 + $1.size.height } + gap * CGFloat(max(cards.count - 1, 0))
    let w = cardW + 2 * margin, h = cardsH + 2 * margin
    guard let out = makeRep(w, h, scale: scale), let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c1 = dark ? NSColor(hex: 0x4A4743) : NSColor(hex: 0xE6DDCF)
        let c2 = dark ? NSColor(hex: 0x2B2927) : NSColor(hex: 0xCFC4B2)
        NSGradient(starting: c1, ending: c2)?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -60)
        var top = h - margin
        for rep in cards {
            let size = rep.size
            let rect = NSRect(x: margin, y: top - size.height, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
            shadow.shadowBlurRadius = 20
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            rep.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            top -= size.height + gap
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return out.representation(using: .png, properties: [:])
}

// MARK: - The popup

final class Popup: NSObject, NSApplicationDelegate {
    let d = readInput()
    lazy var L = Strings(language: d.language)
    let created = Date().timeIntervalSince1970

    // Geometry
    var W: CGFloat { CGFloat(d.width) }
    let pad: CGFloat = 12
    let radius: CGFloat = 14
    let gap: CGFloat = 8
    let margin: CGFloat = 12
    var k: CGFloat { CGFloat(d.fontSize) / 13 }
    var iconSide: CGFloat { round(19 * k) }
    var headerHeight: CGFloat { max(iconSide, ceil(CGFloat(d.fontSize) * 1.3)) }
    /// The body is full width, from the left padding.
    var xText: CGFloat { pad }
    var dividerY: CGFloat { pad + headerHeight + 8 }
    var yText: CGFloat { dividerY + 1 + 9 }

    var screen: NSScreen!
    var screenID = 0
    var palette = Palette.make(style: .standard, kind: .done)
    var panel: Panel!
    var card: CardView!
    var summary: NSTextField!
    var fullText: NSTextView!
    var fullView: NSView!
    var closeButton: ClickButton!

    var compactHeight: CGFloat = 0
    var openHeight: CGFloat = 0
    var isOpen = true
    var isTop = true
    var topEdge: CGFloat = 0
    var activeFile = ""
    var notedHeight: CGFloat = 0

    // Countdown
    var remaining = 60.0
    var hovered = false
    var ticks = 0
    var timer: Timer?
    var expandWork: DispatchWorkItem?
    var transcriptBase: UInt64?
    var closing = false

    var timed: Bool { !(d.kind.needsYou && d.stickyNeedsYou) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch env["CCNOTIFY_THEME"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        palette = Palette.make(style: d.style, kind: d.kind)
        screen = screenUnderMouse()
        screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        remaining = d.seconds
        transcriptBase = d.transcriptSize

        buildViews()

        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: W, height: openHeight),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none      // hidden from screen sharing and recordings
        panel.contentView = card

        applyVisibility()
        registerSelf()
        let vf = screen.visibleFrame
        topEdge = computeTop(vf) ?? (vf.maxY - margin)
        let target = NSRect(x: vf.maxX - W - margin, y: topEdge - openHeight, width: W, height: openHeight)
        if captureTarget != nil {
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
        } else if reduceMotion {
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                self.panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        } else {
            var start = target
            start.origin.x += 24
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().setFrame(target, display: true)
                self.panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        }

        playSound()
        announce()

        card.onEnter = { [weak self] in self?.mouseEntered() }
        card.onExit = { [weak self] in self?.mouseExited() }
        card.onClick = { [weak self] in self?.openConversation() }

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }

        if let path = captureTarget {
            // CCNOTIFY_COMPACT=1: the 3-line version (how older stacked popups look)
            if compactTest { isTop = false; expand(false, animated: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.capture(to: path)
                self?.closePopup()
            }
        }
    }

    func screenUnderMouse() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Building

    func buildViews() {
        let bodyWidth = W - 2 * pad
        let fmt = Formatter(p: palette, size: CGFloat(d.fontSize))

        card = CardView(frame: NSRect(x: 0, y: 0, width: W, height: 100))
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.button)
        card.setAccessibilityLabel("\(d.title): \(L.label(d.kind))")
        card.setAccessibilityHelp(L.open)
        card.toolTip = nil

        // Translucent: blur of what is behind + a soft tinted veil
        if captureTarget == nil && !reduceTransparency {
            let blur = NSVisualEffectView(frame: card.bounds)
            blur.autoresizingMask = [.width, .height]
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = roundedMask(radius)
            card.addSubview(blur)
        }
        let visibleBody = !d.isPrivate && !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let chrome = ChromeView(frame: card.bounds)
        chrome.autoresizingMask = [.width, .height]
        chrome.radius = radius
        chrome.fill = palette.tint
        chrome.overlay = palette.overlay
        chrome.stroke = palette.cardBorder
        chrome.strokeWidth = palette.cardBorderWidth
        chrome.dividerInset = pad
        chrome.dividerColor = palette.divider
        if visibleBody { chrome.dividerY = dividerY }
        if captureTarget != nil || reduceTransparency { chrome.stand = palette.stand }
        card.addSubview(chrome)

        // Header: [icon] project · [symbol] label, one row, vertically centered
        let hh = headerHeight
        let icon = makeIcon()
        icon.frame = NSRect(x: pad, y: pad + (hh - iconSide) / 2, width: iconSide, height: iconSide)
        card.addSubview(icon)

        let fs = CGFloat(d.fontSize)
        let titleFont = NSFont.systemFont(ofSize: fs, weight: .semibold)
        let title = NSTextField(labelWithString: d.title)
        title.font = titleFont
        title.textColor = palette.ink
        title.lineBreakMode = .byTruncatingTail
        let tint = palette.kindTint
        let strongLabel = d.style == .mono && d.kind.needsYou
        let label = NSTextField(labelWithString: L.label(d.kind))
        label.font = NSFont.systemFont(ofSize: fs - 1, weight: strongLabel ? .semibold : .medium)
        label.textColor = tint
        label.lineBreakMode = .byTruncatingTail
        let dot = NSTextField(labelWithString: "·")
        dot.font = titleFont
        dot.textColor = palette.gray
        let symbol = NSImageView()
        let filled = d.style == .mono && d.kind.needsYou
        symbol.image = symbolImage(d.kind.symbols(filled: filled), description: L.label(d.kind))
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: fs - 1, weight: .semibold)
        symbol.contentTintColor = tint
        let symSide = ceil(fs + 3)

        let xTitle = pad + iconSide + 8
        let available = W - xTitle - pad - 22
        let labelW = ceil(label.sizeThatFits(NSSize(width: 400, height: hh)).width)
        let dotW = ceil(dot.sizeThatFits(NSSize(width: 40, height: hh)).width)
        let cueW = dotW + 4 + symSide + 3 + labelW
        let titleNatural = ceil(title.sizeThatFits(NSSize(width: 800, height: hh)).width)
        let titleW = min(titleNatural, max(available - cueW - 6, 60))
        var x = xTitle
        title.frame = NSRect(x: x, y: pad, width: titleW, height: hh)
        x += titleW + 4
        dot.frame = NSRect(x: x, y: pad, width: dotW, height: hh)
        x += dotW + 4
        symbol.frame = NSRect(x: x, y: pad + (hh - symSide) / 2, width: symSide, height: symSide)
        x += symSide + 3
        label.frame = NSRect(x: x, y: pad, width: min(labelW, max(W - pad - 22 - x, 30)), height: hh)
        [title, dot, symbol, label].forEach { card.addSubview($0) }

        closeButton = ClickButton(title: "", target: self, action: #selector(dismissButton))
        closeButton.isBordered = false
        closeButton.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: palette.gray])
        closeButton.frame = NSRect(x: W - pad - 16, y: pad + (hh - 20) / 2, width: 20, height: 20)
        closeButton.toolTip = L.close
        closeButton.setAccessibilityLabel(L.close)
        closeButton.isHidden = true
        card.addSubview(closeButton)

        let minHeight = pad + hh + pad

        // Compact: running text, `compact_lines` lines at most, with "…" if it goes on
        summary = NSTextField(labelWithAttributedString: visibleBody ? fmt.running(d.text) : NSAttributedString())
        summary.maximumNumberOfLines = d.compactLines
        summary.cell?.wraps = true
        summary.cell?.truncatesLastVisibleLine = true
        summary.lineBreakMode = .byWordWrapping
        summary.preferredMaxLayoutWidth = bodyWidth
        let summaryH = visibleBody ? ceil(summary.sizeThatFits(NSSize(width: bodyWidth, height: 400)).height) : 0
        summary.frame = NSRect(x: xText, y: yText, width: bodyWidth, height: summaryH)
        card.addSubview(summary)

        // Open: the whole text. Past max_height_ratio of the screen height it goes in a scroll view.
        let vf = screen.visibleFrame
        let maxH = max(floor((vf.height - 2 * margin) * CGFloat(d.maxHeightRatio)) - yText - pad, 80)
        fullText = NSTextView(frame: NSRect(x: 0, y: 0, width: bodyWidth, height: 10))
        fullText.isEditable = false
        fullText.isSelectable = false
        fullText.drawsBackground = false
        fullText.textContainerInset = .zero
        fullText.textContainer?.lineFragmentPadding = 0
        fullText.textContainer?.widthTracksTextView = false
        fullText.textContainer?.containerSize = NSSize(width: bodyWidth, height: .greatestFiniteMagnitude)
        fullText.isVerticallyResizable = false
        if visibleBody { fullText.textStorage?.setAttributedString(fmt.blocks(d.text)) }
        let totalH = visibleBody ? measure(fullText) : 0
        let textH = min(totalH, maxH)
        if env["CCNOTIFY_DEBUG"] != nil { FileHandle.standardError.write("natural=\(totalH) cap=\(maxH)\n".data(using: .utf8)!) }
        fullText.frame = NSRect(x: 0, y: 0, width: bodyWidth, height: totalH)
        if totalH > maxH {
            // 8 px wider than the text: the scroll bar sits in the margin and covers no letters
            let sv = NSScrollView(frame: NSRect(x: xText, y: yText, width: bodyWidth + 8, height: textH))
            sv.drawsBackground = false
            sv.contentView.drawsBackground = false
            sv.borderType = .noBorder
            sv.hasVerticalScroller = true
            sv.hasHorizontalScroller = false
            sv.autohidesScrollers = true
            sv.scrollerStyle = .overlay
            fullText.minSize = NSSize(width: bodyWidth, height: textH)
            fullText.maxSize = NSSize(width: bodyWidth, height: .greatestFiniteMagnitude)
            fullText.isVerticallyResizable = true
            sv.documentView = fullText
            card.scroller = sv
            fullView = sv
        } else {
            fullText.frame.origin = NSPoint(x: xText, y: yText)
            fullView = fullText
        }
        fullView.isHidden = true
        card.addSubview(fullView)

        compactHeight = visibleBody ? max(yText + summaryH + pad, minHeight) : minHeight
        openHeight = visibleBody ? max(yText + textH + pad, minHeight) : minHeight
        if !visibleBody { isOpen = true }
    }

    func makeIcon() -> NSView {
        let img = NSImageView()
        if let img0 = NSImage(contentsOfFile: ccHome + "/logo.png") {
            img.image = img0
            img.imageScaling = .scaleProportionallyUpOrDown
            return img
        }
        // Neutral built-in icon: an SF Symbol on a soft rounded square
        let box = IconBox(frame: NSRect(x: 0, y: 0, width: iconSide, height: iconSide))
        box.fill = dynamic(light: NSColor(hex: 0x000000, alpha: 0.06), dark: NSColor(hex: 0xFFFFFF, alpha: 0.10))
        let sym = NSImageView(frame: box.bounds.insetBy(dx: iconSide * 0.18, dy: iconSide * 0.18))
        sym.image = symbolImage(["bubble.left.and.bubble.right"], description: nil)
        sym.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: iconSide * 0.5, weight: .regular)
        sym.contentTintColor = palette.ink
        sym.imageScaling = .scaleProportionallyUpOrDown
        box.addSubview(sym)
        return box
    }

    func measure(_ tv: NSTextView) -> CGFloat {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return 18 }
        lm.ensureLayout(for: tc)
        return ceil(max(lm.usedRect(for: tc).height, 16))
    }

    /// Shows the summary or the full text depending on the state. The card is flipped: everything is
    /// measured from the top, so growing the window downwards moves nothing.
    func applyVisibility() {
        let wasFull = !fullView.isHidden
        summary.isHidden = isOpen
        fullView.isHidden = !isOpen
        // If it scrolls, let the bar flash so it is clear there is more below
        if isOpen && !wasFull, let sv = fullView as? NSScrollView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sv.flashScrollers() }
        }
    }

    // MARK: Sound, announcement

    func playSound() {
        guard captureTarget == nil else { return }
        let name = d.sound ?? d.kind.defaultSound
        guard !name.isEmpty else { return }
        let onlyAway = d.onlyWhenAway ?? (d.kind == .done)
        let hostFront = !d.host.isEmpty && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == d.host
        if onlyAway && hostFront { return }
        // At most one sound every 3 s across all popups
        let now = Date().timeIntervalSince1970
        if let s = try? String(contentsOfFile: lastSoundFile, encoding: .utf8),
           let last = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), now - last >= 0, now - last < 3 {
            return
        }
        ensureDir(stateDir)
        writePrivate(String(format: "%.3f", now), to: lastSoundFile)
        let sound: NSSound? = name.hasPrefix("/")
            ? NSSound(contentsOfFile: name, byReference: true)
            : NSSound(named: NSSound.Name(name))
        sound?.volume = Float(min(max(d.volume ?? d.kind.defaultVolume, 0), 1))
        sound?.play()
    }

    func announce() {
        guard captureTarget == nil else { return }
        var text = "\(d.title): \(L.label(d.kind))."
        if !d.isPrivate {
            let first = plainFirstLine(d.text)
            if !first.isEmpty { text += " " + first }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    // MARK: Mouse

    func mouseEntered() {
        hovered = true
        closeButton.isHidden = false
        expandWork?.cancel()
        guard !isOpen else { return }
        let work = DispatchWorkItem { [weak self] in self?.expand(true) }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func mouseExited() {
        hovered = false
        closeButton.isHidden = true
        expandWork?.cancel()
        if !isTop { expand(false) }       // the ones below collapse again
        remaining = max(remaining, 4)    // do not vanish the moment the mouse leaves
    }

    func expand(_ open: Bool, animated: Bool = true) {
        guard open != isOpen, !closing else { return }
        isOpen = open
        let h = open ? openHeight : compactHeight
        let target = NSRect(x: panel.frame.minX, y: topEdge - h, width: W, height: h)
        if open { panel.orderFrontRegardless(); applyVisibility() }
        guard animated && !reduceMotion else {
            panel.setFrame(target, display: true)
            applyVisibility()
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            if !self.isOpen { self.applyVisibility() }
            self.panel.invalidateShadow()
        })
    }

    // MARK: Clock (every 0.1 s)

    func tick() {
        guard !closing else { return }
        ticks += 1
        if ticks % 3 == 0 && !compactTest { relayout() }
        if ticks % 10 == 0, conversationMoved() { closePopup(); return }
        guard timed, !hovered else { return }
        if userAway() {
            remaining = max(remaining, 15)   // you are not here: stay; keep going where it was when you return
            return
        }
        remaining -= 0.1
        if remaining <= 0 { closePopup() }
    }

    /// More than 90 s without keyboard, mouse or trackpad (reading a popup does not count as away).
    func userAway() -> Bool {
        guard let any = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) > 90
    }

    /// Did the conversation continue after the notification? Looks at what is new in the session's
    /// transcript, starting from the size it had when the hook fired (`transcript_size`):
    ///  - done: any new message from you or from Claude.
    ///  - needs you: Claude wrote again (you approved or denied) or you typed something. A tool
    ///    result alone is not enough: it may belong to another tool running in parallel.
    func conversationMoved() -> Bool {
        guard !d.transcript.isEmpty, let fh = FileHandle(forReadingAtPath: d.transcript) else { return false }
        defer { try? fh.close() }
        let end = fh.seekToEndOfFile()
        guard var base = transcriptBase else {
            if Date().timeIntervalSince1970 - created > 1.5 { transcriptBase = end }   // fallback baseline
            return false
        }
        if end < base { transcriptBase = end; return false }   // file was rewritten
        guard end > base else { return false }
        fh.seek(toFileOffset: base)
        let data = fh.readData(ofLength: Int(min(end - base, 4_000_000)))
        guard let last = data.lastIndex(of: 0x0A) else { return false }   // complete lines only
        base += UInt64(last - data.startIndex + 1)
        transcriptBase = base
        for line in data[data.startIndex...last].split(separator: 0x0A) {
            guard let e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if d.eventAt > 0, let ts = e["timestamp"] as? String, let when = parseISO(ts), when < d.eventAt - 0.5 {
                continue
            }
            let type = e["type"] as? String
            if type == "assistant" { return true }
            if type == "user" {
                if !d.kind.needsYou { return true }
                if (e["message"] as? [String: Any])?["content"] is String { return true }
            }
        }
        return false
    }

    func parseISO(_ s: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let t = f.date(from: s) { return t.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    // MARK: Stacking

    /// Notes this popup in state/active/ ("<id>__<pid>" holding "created height screen") and replaces
    /// the previous popup of the same session. A pid is only signalled after checking that it is
    /// really our popup (pids get reused); stale files are just deleted.
    func registerSelf() {
        ensureDir(activeDir)
        let fm = FileManager.default
        let id = safeName(d.id)
        let mine = executablePath(of: getpid())
        for name in (try? fm.contentsOfDirectory(atPath: activeDir)) ?? [] {
            guard let r = name.range(of: "__", options: .backwards),
                  let pid = Int32(name[r.upperBound...]), pid != getpid() else { continue }
            let path = activeDir + "/" + name
            guard let exe = executablePath(of: pid), exe == mine else {
                try? fm.removeItem(atPath: path)      // dead pid, or reused by something else
                continue
            }
            if String(name[..<r.lowerBound]) == id {
                kill(pid, SIGTERM)
                try? fm.removeItem(atPath: path)
            }
        }
        activeFile = activeDir + "/\(id)__\(getpid())"
        noteHeight(openHeight)
    }

    /// Height this popup takes in the stack (open if it is on top, compact otherwise). Opening it
    /// with the mouse does not change it: it opens over the ones below.
    func noteHeight(_ h: CGFloat) {
        guard h != notedHeight, !activeFile.isEmpty else { return }
        notedHeight = h
        writePrivate("\(created) \(Double(h)) \(screenID)", to: activeFile)
    }

    /// Heights of the popups newer than this one on the same screen (the ones above it).
    func newerHeights() -> [Double] {
        let fm = FileManager.default
        let mine = executablePath(of: getpid())
        var heights: [Double] = []
        for name in (try? fm.contentsOfDirectory(atPath: activeDir)) ?? [] {
            guard let r = name.range(of: "__", options: .backwards),
                  let pid = Int32(name[r.upperBound...]), pid != getpid(),
                  let exe = executablePath(of: pid), exe == mine,
                  let s = try? String(contentsOfFile: activeDir + "/" + name, encoding: .utf8)
            else { continue }
            let v = s.split(separator: " ").compactMap { Double($0) }
            guard v.count >= 2, v[0] > created else { continue }
            if v.count >= 3, Int(v[2]) != screenID { continue }
            heights.append(v[1])
        }
        return heights
    }

    /// Top edge for this popup: below the newer ones. nil if it must leave (too many newer ones, or
    /// even compact it no longer fits). "Needs you" popups are not dropped for the count limit.
    func computeTop(_ vf: NSRect) -> CGFloat? {
        let heights = newerHeights()
        if heights.count >= d.maxStacked && !(d.kind.needsYou && d.stickyNeedsYou) { return nil }
        let top = vf.maxY - margin - heights.reduce(0) { $0 + CGFloat($1) + gap }
        if !heights.isEmpty && top - compactHeight < vf.minY + margin { return nil }
        return top
    }

    func relayout() {
        let vf = screen.visibleFrame
        guard let newTop = computeTop(vf) else { closePopup(); return }
        // The top one is open; the rest are compact (unless the mouse is over them)
        isTop = abs(newTop - (vf.maxY - margin)) < 0.5
        noteHeight(isTop ? openHeight : compactHeight)
        let wantsOpen = isTop || hovered
        let moved = abs(newTop - topEdge) > 0.5
        topEdge = newTop
        if wantsOpen != isOpen { expand(wantsOpen); return }   // already uses the new top
        guard moved else { return }
        let h = panel.frame.height
        let target = NSRect(x: vf.maxX - W - margin, y: newTop - h, width: W, height: h)
        if reduceMotion { panel.setFrame(target, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: Actions

    @objc func openConversation() {
        markSeen()
        runFocus()
        closePopup()
    }

    /// Jump to the conversation: python3 focus_session.py --host … --cwd … [--pid …], run with argv
    /// (no shell involved).
    func runFocus() {
        let f = d.focus
        guard !f.host.isEmpty || !f.cwd.isEmpty,
              FileManager.default.fileExists(atPath: focusScript) else { return }
        var args = ["python3", focusScript]
        if !f.host.isEmpty { args += ["--host", f.host] }
        if !f.cwd.isEmpty { args += ["--cwd", f.cwd] }
        if let pid = f.pid { args += ["--pid", String(pid)] }
        if !f.job.isEmpty { args += ["--job", f.job] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }

    /// Tells the menu bar the session was seen: state/seen/<session-id> holds the epoch.
    func markSeen() {
        guard !d.session.isEmpty, captureTarget == nil else { return }
        ensureDir(seenDir)
        writePrivate(String(format: "%.3f", Date().timeIntervalSince1970), to: seenDir + "/" + safeName(d.session))
    }

    @objc func closePopup() {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        if !activeFile.isEmpty { try? FileManager.default.removeItem(atPath: activeFile) }
        if captureTarget != nil { NSApp.terminate(nil); return }
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                self.panel.animator().alphaValue = 0
            }, completionHandler: { NSApp.terminate(nil) })
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            self.panel.animator().alphaValue = 0
            var f = self.panel.frame
            f.origin.x += 16
            self.panel.animator().setFrame(f, display: true)
        }, completionHandler: {
            NSApp.terminate(nil)
        })
    }

    /// The X also counts as "seen".
    @objc func dismissButton() {
        markSeen()
        closePopup()
    }

    // MARK: Test capture

    /// CCNOTIFY_CAPTURE: renders the card (without the blur, which does not exist in a capture) over
    /// a soft backdrop and saves a PNG. CCNOTIFY_CAPTURE_BACKDROP=0 saves the bare card;
    /// CCNOTIFY_CAPTURE_SCALE sets the pixel density (default 2).
    func capture(to path: String) {
        let b = card.bounds
        let scale = CGFloat(Double(env["CCNOTIFY_CAPTURE_SCALE"] ?? "") ?? 2)
        guard let cardRep = makeRep(b.width, b.height, scale: scale) else { return }
        card.cacheDisplay(in: b, to: cardRep)
        var png = cardRep.representation(using: .png, properties: [:])
        if env["CCNOTIFY_CAPTURE_BACKDROP"] != "0" {
            png = composeOnBackdrop([cardRep], gap: 0, scale: scale, radius: radius) ?? png
        }
        try? png?.write(to: URL(fileURLWithPath: path))
    }
}

/// Soft rounded square behind the built-in icon.
final class IconBox: NSView {
    var fill = NSColor.clear
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width * 0.28, yRadius: bounds.width * 0.28).fill()
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Test hook: CCNOTIFY_COMPOSE=<out.png> CCNOTIFY_COMPOSE_INPUTS=a.png:b.png:c.png joins bare card captures
// (top to bottom, 8 points apart) over the backdrop, like a stack of popups. Quits when done.
if let out = env["CCNOTIFY_COMPOSE"] {
    switch env["CCNOTIFY_THEME"] {
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    default: break
    }
    let reps = (env["CCNOTIFY_COMPOSE_INPUTS"] ?? "").split(separator: ":").compactMap { path -> NSBitmapImageRep? in
        guard let data = FileManager.default.contents(atPath: String(path)),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep
    }
    let scale = CGFloat(Double(env["CCNOTIFY_CAPTURE_SCALE"] ?? "") ?? 2)
    if let png = composeOnBackdrop(reps, gap: 8, scale: scale, radius: 14) {
        try? png.write(to: URL(fileURLWithPath: out))
    }
    exit(0)
}

let popup = Popup()
app.delegate = popup
// A newer popup of the same session replaces this one (SIGTERM): it leaves with the animation.
signal(SIGTERM, SIG_IGN)
let onReplace = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
onReplace.setEventHandler { popup.closePopup() }
onReplace.resume()
app.run()
