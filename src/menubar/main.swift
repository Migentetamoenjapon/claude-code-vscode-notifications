// CCNotify Sessions: a menu bar item that shows the state of every open Claude Code session.
//
//   needs you    permission or a question: Claude does not continue without you  (attention color)
//   wrote to you finished and you have not looked yet                              (accent color)
//   thinking     still working (or background agents running)                      (gray)
//   waiting      finished and you already looked                                   (gray)
//
// The icon is an SF Symbol tinted by the most urgent state. Click it for the list, one row per
// session grouped by state; click a session to jump to its terminal (focus_session.py, run with
// argv, never a shell) and mark it as seen.
//
// Reads  <CCNOTIFY_HOME>/state/sessions/<id>.json  (written by the hooks) and
//        <CCNOTIFY_HOME>/state/seen/<id>           (epoch written by the popup / this app).
// A session counts as seen when seen >= since (a json "seen": true is also honored). Sessions with
// a newer-or-equal tombstone in state/ended/ are hidden. CCNOTIFY_HOME defaults to
// $CLAUDE_CONFIG_DIR/ccnotify (~/.claude/ccnotify). Language: "language" in config.json ("auto" | "en" | "es").
//
// Test hooks (inert unless set): CCNOTIFY_OPEN_MENU=1 opens the menu after a second.
// CCNOTIFY_CAPTURE_MENU=<file.png> opens the menu, grabs the open menu (a window of this process, so no
// Screen Recording permission is needed), draws the status item from the button's real symbol, tint and
// count, joins both over a soft backdrop like the popup captures and quits. CCNOTIFY_THEME=light|dark
// forces the appearance and CCNOTIFY_CAPTURE_SCALE sets the pixel density of the picture (default 2).
//
// The session files are owned by the hooks; this app never writes them. It also watches each
// session's transcript, in memory only, so a state does not stay stale when no hook fires
// (permission approved, request interrupted, you typed something).
import Cocoa
import Darwin

// MARK: - Paths

let env = ProcessInfo.processInfo.environment
let ccHome: String = {
    if let h = env["CCNOTIFY_HOME"], !h.isEmpty { return (h as NSString).expandingTildeInPath }
    let claudeDir = (env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.claude")
    return (claudeDir as NSString).expandingTildeInPath + "/ccnotify"
}()
let sessionsDir = ccHome + "/state/sessions"
let seenDir = ccHome + "/state/seen"
let endedDir = ccHome + "/state/ended"
let focusScript = ccHome + "/bin/focus_session.py"

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
}

func safeName(_ s: String) -> String {
    // Same rule as notify.py: only [A-Za-z0-9._-], at most 128 chars, no leading dots
    let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    var cleaned = String(String(s.prefix(128)).map { ok.contains($0) ? $0 : "_" })
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    return cleaned.isEmpty ? "unknown" : cleaned
}

// MARK: - Localization

/// popup.style from config.json: "default", "color" or "mono". Mono means grayscale only.
func configStyle() -> String {
    if let data = FileManager.default.contents(atPath: ccHome + "/config.json"),
       let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let popup = o["popup"] as? [String: Any],
       let style = popup["style"] as? String { return style.lowercased() }
    return "default"
}

struct Strings {
    let es: Bool

    init() {
        var lang = "auto"
        if let data = FileManager.default.contents(atPath: ccHome + "/config.json"),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let l = o["language"] as? String { lang = l.lowercased() }
        switch lang {
        case "es": es = true
        case "en": es = false
        default: es = (Locale.preferredLanguages.first ?? "en").hasPrefix("es")
        }
    }

    var needs: String { es ? "Te necesita" : "Needs you" }
    var wrote: String { es ? "Te escribió" : "Wrote to you" }
    var thinking: String { es ? "Pensando" : "Thinking" }
    var waiting: String { es ? "Espera que escribas" : "Waiting for you" }
    var needsHeading: String { es ? "Te necesitan" : "Need you" }
    var wroteHeading: String { es ? "Te escribieron" : "Wrote to you" }
    var thinkingHeading: String { es ? "Pensando" : "Thinking" }
    var waitingHeading: String { es ? "Esperan que escribas" : "Waiting for you" }
    var noSessions: String { es ? "No hay sesiones de Claude abiertas" : "No Claude sessions open" }
    var markAllSeen: String { es ? "Marcar todo como visto" : "Mark all as seen" }
    var quit: String { es ? "Salir" : "Quit" }
    var interrupted: String { es ? "La interrumpiste" : "You interrupted it" }
    var youAsked: String { es ? "Pediste: " : "You asked: " }
    var title: String { es ? "Sesiones de Claude" : "Claude sessions" }
    var nothingPending: String { es ? "nada pendiente" : "nothing pending" }

    func agents(_ n: Int) -> String {
        es ? "\(n) agente\(n > 1 ? "s" : "")" : "\(n) agent\(n > 1 ? "s" : "")"
    }

    func ago(_ t: Double) -> String {
        let s = max(0, Date().timeIntervalSince1970 - t)
        if s < 60 { return es ? "ahora" : "now" }
        let (n, unit): (Int, String)
        if s < 3600 { (n, unit) = (Int(s / 60), "min") }
        else if s < 86400 { (n, unit) = (Int(s / 3600), "h") }
        else { (n, unit) = (Int(s / 86400), "d") }
        return es ? "hace \(n) \(unit)" : "\(n) \(unit) ago"
    }

    func summaryCount(needs: Int, wrote: Int, thinking: Int) -> String {
        var parts: [String] = []
        if needs > 0 { parts.append(es ? "\(needs) te necesita\(needs > 1 ? "n" : "")" : "\(needs) need\(needs > 1 ? "" : "s") you") }
        if wrote > 0 { parts.append(es ? "\(wrote) te escribi\(wrote > 1 ? "eron" : "ó")" : "\(wrote) wrote to you") }
        if thinking > 0 { parts.append(es ? "\(thinking) pensando" : "\(thinking) thinking") }
        return parts.isEmpty ? nothingPending : parts.joined(separator: " · ")
    }
}

// MARK: - Colors (dynamic)

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

/// "Needs you": the same orange family as the popup's attention cue.
let attentionColor = NSColor.dynamic(light: 0xB8532F, dark: 0xE8977A)
/// "Wrote to you": the system accent color.
let accentColor = NSColor.controlAccentColor

// MARK: - Model

struct FocusTarget {
    var host = ""
    var cwd = ""
    var pid: Int?
    var job = ""   // background session id (claude --bg)
}

struct Session {
    var id: String
    var project: String
    var state: String          // needs | wrote | thinking
    var seen: Bool
    var since: Double
    var summary: String
    var request: String
    var tasks: Int
    var pid: Int32
    var updatedAt: Double
    var transcript: String
    var focus: FocusTarget
    var path: String
}

/// What the transcript says happened after the last hook, kept in memory only.
struct Override {
    var state: String
    var at: Double
    var seen: Bool
    var summary: String?
    var request: String?
}

func number(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

func shorten(_ t: String, _ n: Int) -> String {
    let clean = t.replacingOccurrences(of: "\n", with: " ")
    return clean.count <= n ? clean : String(clean.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
}

func seenMarker(_ id: String) -> Double {
    guard let s = try? String(contentsOfFile: seenDir + "/" + safeName(id), encoding: .utf8),
          let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
    return v
}

/// Epoch stored in state/ended/<id> ({"at": …}) when a session ended, or 0.
func endedAt(_ id: String) -> Double {
    guard let data = FileManager.default.contents(atPath: endedDir + "/" + safeName(id)),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
    return number(o["at"]) ?? 0
}

func markSeen(_ id: String) {
    ensureDir(seenDir)
    let path = seenDir + "/" + safeName(id)
    let text = String(format: "%.3f", Date().timeIntervalSince1970)
    let tmp = path + ".tmp\(getpid())"
    if FileManager.default.createFile(atPath: tmp, contents: text.data(using: .utf8),
                                      attributes: [.posixPermissions: 0o600]) {
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp) }
    }
}

let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Empty RGBA bitmap of w x h points at `scale` pixels per point (test captures).
func makeRep(_ w: CGFloat, _ h: CGFloat, scale: CGFloat) -> NSBitmapImageRep? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((w * scale).rounded()),
                               pixelsHigh: Int((h * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)
    rep?.size = NSSize(width: w, height: h)
    return rep
}

// MARK: - The app

final class MenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var L = Strings()
    var sessions: [Session] = []
    var readUpTo: [String: UInt64] = [:]       // per session: how far its transcript has been read
    var overrides: [String: Override] = [:]
    var timer: Timer?
    var mono = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if env["CCNOTIFY_CAPTURE_MENU"] != nil {     // tests only: force the appearance before anything is drawn
            switch env["CCNOTIFY_THEME"] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        if env["CCNOTIFY_CAPTURE_MENU"] != nil { menu.appearance = NSApp.appearance }   // tests only
        item.menu = menu
        item.button?.imagePosition = .imageLeft
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)   // keep updating while the menu is open
        if env["CCNOTIFY_OPEN_MENU"] != nil {        // tests only
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.item.button?.performClick(nil) }
        }
        if let out = env["CCNOTIFY_CAPTURE_MENU"] { captureMenu(to: out) }   // tests only
    }

    func refresh() {
        sessions = readSessions()
        watchTranscripts()
        paintItem()
    }

    // MARK: Data

    func readSessions() -> [Session] {
        let fm = FileManager.default
        var list: [Session] = []
        let now = Date().timeIntervalSince1970
        for name in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] where name.hasSuffix(".json") {
            let path = sessionsDir + "/" + name
            guard let data = fm.contents(atPath: path),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let pid = Int32(number(o["pid"]) ?? 0)
            let updated = number(o["updated_at"]) ?? 0
            // Closed session: the Claude process is gone (or, without a pid, nothing for 24 h)
            if (pid > 0 && kill(pid, 0) != 0 && errno == ESRCH) || (pid <= 0 && updated > 0 && now - updated > 86400) {
                let id = (o["session"] as? String) ?? String(name.dropLast(5))
                try? fm.removeItem(atPath: path)
                try? fm.removeItem(atPath: seenDir + "/" + safeName(id))
                overrides[id] = nil
                continue
            }
            let id = (o["session"] as? String) ?? String(name.dropLast(5))
            // Tombstone written by the SessionEnd hook: hide unless the file was updated after it
            if endedAt(id) >= updated && endedAt(id) > 0 { continue }
            let since = number(o["since"]) ?? updated
            var focus = FocusTarget()
            if let f = o["focus"] as? [String: Any] {
                focus.host = (f["host"] as? String) ?? ""
                focus.cwd = (f["cwd"] as? String) ?? ""
                if let p = number(f["pid"]), p > 0 { focus.pid = Int(p) }
                focus.job = (f["job"] as? String) ?? ""
            }
            if focus.host.isEmpty { focus.host = (o["host"] as? String) ?? "" }
            if focus.cwd.isEmpty { focus.cwd = (o["cwd"] as? String) ?? "" }
            if focus.pid == nil, pid > 0 { focus.pid = Int(pid) }

            var s = Session(id: id, project: (o["project"] as? String) ?? "Claude",
                            state: (o["state"] as? String) ?? "wrote",
                            seen: ((o["seen"] as? Bool) ?? false) || (since > 0 && seenMarker(id) >= since),
                            since: since, summary: (o["summary"] as? String) ?? "",
                            request: (o["request"] as? String) ?? "", tasks: Int(number(o["tasks"]) ?? 0),
                            pid: pid, updatedAt: updated, transcript: (o["transcript"] as? String) ?? "",
                            focus: focus, path: path)
            // A transcript observation newer than the last hook wins; a newer hook wins over it
            if let ov = overrides[id], ov.at >= max(since, updated) {
                s.state = ov.state
                s.since = ov.at
                s.seen = ov.seen || seenMarker(id) >= ov.at
                if let t = ov.summary { s.summary = t }
                if let t = ov.request { s.request = t }
            }
            list.append(s)
        }
        return list
    }

    /// New lines in each session's transcript, to change state without waiting for a hook.
    func watchTranscripts() {
        for s in sessions where !s.transcript.isEmpty {
            guard let fh = FileHandle(forReadingAtPath: s.transcript) else { continue }
            defer { try? fh.close() }
            let end = fh.seekToEndOfFile()
            guard let base = readUpTo[s.id], end > base else { readUpTo[s.id] = end; continue }
            fh.seek(toFileOffset: base)
            let data = fh.readData(ofLength: Int(min(end - base, 8_000_000)))
            guard let last = data.lastIndex(of: 0x0A) else { continue }
            readUpTo[s.id] = base + UInt64(last - data.startIndex + 1)
            var state = s.state
            var change: Override?
            for line in data[data.startIndex...last].split(separator: 0x0A) {
                guard let e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if e["isSidechain"] as? Bool == true { continue }   // a subagent's lines, not the conversation
                // Only what happened after the last state change (do not override a fresh "done")
                if let ts = e["timestamp"] as? String, let when = isoFractional.date(from: ts),
                   when.timeIntervalSince1970 < s.since { continue }
                let type = e["type"] as? String
                let now = Date().timeIntervalSince1970
                if type == "assistant" && state == "needs" {
                    state = "thinking"                      // approved (or denied) and it went on
                    change = Override(state: state, at: now, seen: true, summary: nil, request: nil)
                }
                guard type == "user", let t = userText(e) else { continue }
                if t.hasPrefix("[Request interrupted") {
                    state = "wrote"
                    change = Override(state: state, at: now, seen: true, summary: L.interrupted, request: nil)
                } else if t.hasPrefix("<task-notification>") || t.hasPrefix("<agent-message") {
                    if state != "thinking" {                // a background task came back: Claude goes on
                        state = "thinking"
                        change = Override(state: state, at: now, seen: true, summary: nil, request: nil)
                    }
                } else if t.hasPrefix("<") {
                    continue    // commands such as /model or "!git push" do not make it think
                } else if state != "thinking" {
                    state = "thinking"                      // you typed something
                    change = Override(state: state, at: now, seen: true, summary: nil, request: shorten(t, 160))
                }
            }
            if let c = change { overrides[s.id] = c }
        }
        sessions = readSessions()
    }

    /// Text of a user message (what you typed, or system notices); nil for a tool result or an
    /// internal message.
    func userText(_ e: [String: Any]) -> String? {
        if e["isMeta"] as? Bool == true { return nil }
        let c = (e["message"] as? [String: Any])?["content"]
        if let s = c as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let parts = c as? [[String: Any]],
              !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Menu bar item

    var needing: [Session] { sessions.filter { $0.state == "needs" }.sorted { $0.since < $1.since } }
    var unseenWrote: [Session] { sessions.filter { $0.state == "wrote" && !$0.seen }.sorted { $0.since > $1.since } }
    var thinking: [Session] { sessions.filter { $0.state == "thinking" }.sorted { $0.since < $1.since } }
    var waiting: [Session] { sessions.filter { $0.state == "wrote" && $0.seen }.sorted { $0.since > $1.since } }

    func paintItem() {
        L = Strings()
        let nNeeds = needing.count, nWrote = unseenWrote.count, nThinking = thinking.count
        mono = configStyle() == "mono"
        let tint: NSColor?
        let symbols: [String]
        let base = "bubble.left.and.bubble.right"
        if mono {
            // Grayscale: the state is told by different symbols, not by color
            tint = nil
            if nNeeds > 0 { symbols = ["exclamationmark.bubble.fill", base + ".fill"] }
            else if nWrote > 0 { symbols = [base + ".fill"] }
            else if nThinking > 0 { symbols = ["ellipsis.bubble", base] }
            else { symbols = [base] }
        } else if nNeeds > 0 { tint = attentionColor; symbols = [base + ".fill"] }
        else if nWrote > 0 { tint = accentColor; symbols = [base + ".fill"] }
        else if nThinking > 0 { tint = .secondaryLabelColor; symbols = [base] }
        else { tint = nil; symbols = [base] }

        let button = item.button
        var img: NSImage?
        for name in symbols + [base] {
            img = NSImage(systemSymbolName: name, accessibilityDescription: L.title)
            if img != nil { break }
        }
        img?.isTemplate = true
        button?.image = img
        button?.contentTintColor = tint

        // A plain count of what wants your attention, in the same color as the icon
        let count = nNeeds + nWrote
        if count > 0 {
            let font = NSFont.menuBarFont(ofSize: 0)
            button?.attributedTitle = NSAttributedString(string: " \(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold),
                .foregroundColor: tint ?? NSColor.labelColor])
        } else {
            button?.attributedTitle = NSAttributedString(string: "")
        }
        let summary = L.summaryCount(needs: nNeeds, wrote: nWrote, thinking: nThinking)
        button?.toolTip = "\(L.title): \(summary)"
        button?.setAccessibilityLabel("\(L.title): \(summary)")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        L = Strings()
        mono = configStyle() == "mono"
        sessions = readSessions()
        menu.removeAllItems()
        let groups: [(String, [Session])] = [
            (L.needsHeading, needing), (L.wroteHeading, unseenWrote),
            (L.thinkingHeading, thinking), (L.waitingHeading, waiting)]
        for (heading, list) in groups where !list.isEmpty {
            if menu.items.count > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
            header.attributedTitle = NSAttributedString(string: heading.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.4])
            header.isEnabled = false
            menu.addItem(header)
            for s in list { menu.addItem(row(for: s)) }
        }
        if sessions.isEmpty {
            let none = NSMenuItem(title: L.noSessions, action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        if !unseenWrote.isEmpty {
            let all = NSMenuItem(title: L.markAllSeen, action: #selector(markAll), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
        let quit = NSMenuItem(title: L.quit, action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func stateLabel(_ s: Session) -> String {
        switch s.state {
        case "needs": return L.needs
        case "thinking": return L.thinking
        default: return s.seen ? L.waiting : L.wrote
        }
    }

    func row(for s: Session) -> NSMenuItem {
        let (dot, color): (String, NSColor) = {
            if mono {
                switch s.state {
                case "needs": return ("◆", .labelColor)
                case "thinking": return ("◌", .secondaryLabelColor)
                default: return s.seen ? ("○", .tertiaryLabelColor) : ("●", .secondaryLabelColor)
                }
            }
            switch s.state {
            case "needs": return ("●", attentionColor)
            case "thinking": return ("◌", .secondaryLabelColor)
            default: return s.seen ? ("○", .tertiaryLabelColor) : ("●", accentColor)
            }
        }()
        var detail = "\(stateLabel(s)) · \(L.ago(s.since))"
        if s.state == "thinking" && s.tasks > 0 { detail += " · " + L.agents(s.tasks) }
        let second: String = {
            if s.state == "thinking" && !s.request.isEmpty && s.tasks == 0 { return L.youAsked + s.request }
            return s.summary.isEmpty ? s.request : s.summary
        }()
        let quiet = s.state == "wrote" && s.seen
        let t = NSMutableAttributedString()
        t.append(NSAttributedString(string: dot + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]))
        t.append(NSAttributedString(string: s.project, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: quiet ? .regular : .semibold),
            .foregroundColor: NSColor.labelColor]))
        t.append(NSAttributedString(string: "   " + detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        if !second.isEmpty {
            t.append(NSAttributedString(string: "\n     " + shorten(second, 64), attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let menuItem = NSMenuItem(title: s.project, action: #selector(openSession(_:)), keyEquivalent: "")
        menuItem.attributedTitle = t
        menuItem.target = self
        menuItem.representedObject = s.id
        menuItem.toolTip = second.isEmpty ? nil : second
        return menuItem
    }

    // MARK: Test capture

    /// CCNOTIFY_CAPTURE_MENU: opens the menu, grabs the open menu (a window of this process, so no Screen
    /// Recording permission is needed), draws the status item next to it and quits. A watchdog ends the
    /// process even if the menu never shows up.
    func captureMenu(to path: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            fputs("menu capture timed out\n", stderr)
            exit(1)
        }
        // Wait for the status item to get its window and its final width, then open the menu. The click
        // blocks in the menu's tracking loop, so the grab runs from a timer in the common run loop modes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let win = self.item.button?.window else { fputs("no status item window\n", stderr); exit(1) }
            let itemID = CGWindowID(win.windowNumber)
            let grab = Timer(timeInterval: 0.8, repeats: false) { _ in
                let ok = self.grabAndCompose(itemID: itemID, to: path)
                self.item.menu?.cancelTracking()
                exit(ok ? 0 : 1)
            }
            RunLoop.main.add(grab, forMode: .common)
            self.item.button?.performClick(nil)
        }
    }

    /// Pixels of one of this process's windows. CGWindowListCreateImage is looked up at run time because
    /// the newest SDKs mark it unavailable in Swift (they point to ScreenCaptureKit, which needs the
    /// Screen Recording permission this test hook is meant to avoid); the function itself still works
    /// for a process's own windows.
    func windowImage(_ id: CGWindowID) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: Fn.self)
        let options: CGWindowListOption = .optionIncludingWindow
        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return create(.null, options.rawValue, id, imageOptions.rawValue)?.takeRetainedValue()
    }

    func grabAndCompose(itemID: CGWindowID, to path: String) -> Bool {
        let scale = CGFloat(Double(env["CCNOTIFY_CAPTURE_SCALE"] ?? "") ?? 2)
        let pid = Int(getpid())
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        // The open menu is this process's largest window other than the status item
        var menuWin: (id: CGWindowID, area: Double)?
        for w in infos {
            guard (w[kCGWindowOwnerPID as String] as? Int) == pid,
                  let num = w[kCGWindowNumber as String] as? Int, CGWindowID(num) != itemID,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let ww = number(b["Width"]), let hh = number(b["Height"]), hh > 40 else { continue }
            if menuWin == nil || ww * hh > menuWin!.area { menuWin = (CGWindowID(num), ww * hh) }
        }
        guard let mw = menuWin, let menuImg = windowImage(mw.id), let button = item.button else {
            fputs("could not grab the menu windows\n", stderr)
            return false
        }
        // The menu grab comes at the screen's pixel density; sizes below are in points
        let density = button.window?.backingScaleFactor ?? 1
        let menuSize = NSSize(width: CGFloat(menuImg.width) / density, height: CGFloat(menuImg.height) / density)
        let itemSize = button.bounds.size

        let margin: CGFloat = 40, barH: CGFloat = 24, sidePad: CGFloat = 28
        let w = menuSize.width + 2 * margin, h = barH + menuSize.height + margin
        guard let rep = makeRep(w, h, scale: scale), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // Same soft backdrop as the popup captures
            let c1 = dark ? NSColor(hex: 0x4A4743) : NSColor(hex: 0xE6DDCF)
            let c2 = dark ? NSColor(hex: 0x2B2927) : NSColor(hex: 0xCFC4B2)
            NSGradient(starting: c1, ending: c2)?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -60)
            // A piece of the menu bar across the top with the status item near its right end
            (dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.62)).setFill()
            NSRect(x: 0, y: h - barH, width: w, height: barH).fill()
            let cg = ctx.cgContext
            drawStatusItem(button, in: NSRect(x: w - margin - sidePad - itemSize.width,
                                              y: h - barH + (barH - itemSize.height) / 2,
                                              width: itemSize.width, height: itemSize.height),
                           dark: dark, cg: cg)
            // The open menu below the bar, with a soft shadow like the popup cards
            let menuRect = NSRect(x: margin, y: h - barH - menuSize.height, width: menuSize.width, height: menuSize.height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
            shadow.shadowBlurRadius = 20
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            cg.draw(menuImg, in: menuRect)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// The status item as the button holds it (its symbol, tint and count), highlighted like an item
    /// whose menu is open. Drawn here because a grab of the item's window comes without the tint,
    /// which the system applies on screen. Must run with the capture appearance current.
    func drawStatusItem(_ button: NSStatusBarButton, in rect: NSRect, dark: Bool, cg: CGContext) {
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        let title = button.attributedTitle
        let titleSize = title.size()
        let iconSize = button.image?.size ?? .zero
        var x = rect.minX + (rect.width - iconSize.width - titleSize.width) / 2
        if let img = button.image {
            let iconRect = NSRect(x: x, y: rect.midY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
            // The symbol is a template: paint the tint (or the label color) only where it has pixels
            cg.beginTransparencyLayer(in: iconRect, auxiliaryInfo: nil)
            img.draw(in: iconRect)
            cg.setBlendMode(.sourceAtop)
            cg.setFillColor((button.contentTintColor ?? NSColor.labelColor).cgColor)
            cg.fill(iconRect)
            cg.endTransparencyLayer()
            x += iconSize.width
        }
        title.draw(at: NSPoint(x: x, y: rect.midY - titleSize.height / 2))
    }

    // MARK: Actions

    @objc func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = sessions.first(where: { $0.id == id }) else { return }
        markSeen(id)
        runFocus(s.focus)
        refresh()
    }

    /// python3 focus_session.py --host … --cwd … [--pid …], run with argv (no shell involved).
    func runFocus(_ f: FocusTarget) {
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

    @objc func markAll() {
        for s in unseenWrote { markSeen(s.id) }
        refresh()
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBar = MenuBar()
app.delegate = menuBar
app.run()
