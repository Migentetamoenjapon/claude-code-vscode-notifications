// CCNotify Sessions: a menu bar item and a panel that show the state of every open Claude Code session.
//
// The status item is an SF Symbol (the menu bar paints it) and, when sessions are waiting for you (they need
// permission, ask a question, or finished and you have not looked yet), ONE number next to it in the bar's own color.
// Click it for a panel (an NSPopover) with ONE list: a one-line, soft-colored box per open session, from the most
// to the least relevant (pinned, need you, finished and unread, reminder pending, working, read). Each box shows
// the state word, the project and, on the right, `2 agents · ctx 62 % · 3 min`. Hover a box for 180 ms and it opens
// in place (Go to chat / Remind me / Mark as read / Pin); 600 ms later a bubble with the whole last message appears
// beside the panel. Click a box's line (or "Go to chat") to jump to its terminal (focus_session.py, run with argv,
// never a shell); the session is marked as seen. A gear in the footer opens the options page (the status item's icon,
// the emoji of each session, what the panel shows). With the emoji on, each row starts with a small picture, chosen
// by the app from a family you pick (a different one for each open session) or by you: click the picture in a row.
//
// Reads  <CCNOTIFY_HOME>/state/sessions/<id>.json   written by the hooks
//        <CCNOTIFY_HOME>/state/seen/<id>            epoch written by the popup / this app
//        <CCNOTIFY_HOME>/state/context/<id>.json    {"pct", "at"}, written by the status line (optional)
//        <CCNOTIFY_HOME>/state/usage.json           {"five_hour": {"pct", "resets_at"}, "seven_day": {...}, "at"}
//                                                   written by the status line (optional: no file, no "Limits" block)
// A session counts as seen when seen >= since (a json "seen": true is also honored). Sessions with a newer-or-equal
// tombstone in state/ended/ are hidden. CCNOTIFY_HOME defaults to $CLAUDE_CONFIG_DIR/ccnotify (~/.claude/ccnotify).
// Language: "language" in config.json ("auto" | "en" | "es"); "popup.style": "mono" turns the panel grayscale.
//
// The session files are owned by the hooks; this app never writes them. It also watches each session's transcript,
// in memory only, so a state does not stay stale when no hook fires (permission approved, request interrupted, you
// typed something). What this app owns lives in <CCNOTIFY_HOME>/state/menubar/ (folders 0700, files 0600):
//   pins/<safe id>             an empty file per pinned session
//   reminders/<safe id>.json   {"at": <due epoch>, "since": <the session's `since` when it was set>}
//   options.json               {"icon", "emoji_theme", "bubble", "usage", "context"}: the options page; keys it does not
//                              know are kept; unreadable: the defaults ("emoji_theme" is a family or "none")
//   emoji-auto.json            {"family", "assigned": {"<safe id>": "<name>.png"}}: the emoji given to each session
//   emoji-chosen.json          {"<safe id>": "<family>/<name>.png"}: the emoji you picked by hand
// The emoji pictures (Fluent Emoji, MIT; see assets/emoji/LICENSE) are in the app's bundle, Contents/Resources/emoji/<family>/.
// A reminder that comes due is shown with the usual popup (a JSON in state/queue/ and `open -n -g CCNotify.app`,
// like hooks/notify.py does); a reminder is dropped when the session changes state or goes away.
//
// Test hooks (inert unless set):
//   CCNOTIFY_OPEN_MENU=1            opens the panel after a second.
//   CCNOTIFY_CAPTURE_MENU=<png>     opens the panel, grabs its window (a window of this process, so no Screen Recording
//                                   permission is needed), joins it with the status item over a soft backdrop and quits.
//   CCNOTIFY_CAPTURE_OPEN=<id>      with the capture: that row open, as when the mouse rests on it.
//   CCNOTIFY_CAPTURE_BUBBLE=<id>    with the capture: also the bubble of that session.
//   CCNOTIFY_CAPTURE_REMIND=<id>    with the capture: that row showing its "Remind me in" choices.
//   CCNOTIFY_CAPTURE_PICKER=<id>    with the capture: that row showing its emoji picker.
//   CCNOTIFY_CAPTURE_OPTIONS=1      with the capture: the options page instead of the list
//                                   (CCNOTIFY_CAPTURE_ALL_FAMILIES=1: with every family of emoji in view).
//   CCNOTIFY_EMOJI_DIR=<folder>     where the emoji families are (default: the app's Contents/Resources/emoji).
//   CCNOTIFY_THEME=light|dark       forces the appearance; CCNOTIFY_CAPTURE_SCALE sets the pixel density (default 2).
//   CCNOTIFY_TEST_MINUTES_AS_SECONDS=1   "2 / 5 / 15 min" last 2 / 5 / 15 seconds.
//   CCNOTIFY_TEST_REMIND=<id>       sets a "2 min" reminder at launch, lets the clock run and quits after 12 s (no icon).
//   CCNOTIFY_TEST_MOUSE=<id>        opens the panel, MOVES the cursor onto that session's row and away again, noting in
//                                   stderr what is open at each step (the 180 ms row and 600 ms bubble timings), and quits.
//   CCNOTIFY_TEST_ORDER=1           prints the session ids in list order and quits.
//   CCNOTIFY_TEST_EMOJI=1           prints "<id>\t<family>/<name>.png|-\tmanual|auto" per session (in id order) and quits.
//   CCNOTIFY_TEST_OPTIONS=<json>    saves those keys the way the options page does, prints options.json and quits.
//   CCNOTIFY_TEST_CHOOSE=<id>=<family>/<name>.png   saves that session's emoji by hand (empty after "=": removes it) and quits.
//   CCNOTIFY_TEST_NAV=<id>          opens the panel and does what the clicks do (options page, switches, icon, emoji picker of that
//                                   row), noting each step in stderr, and quits.
//   CCNOTIFY_TEST_BAR=1             prints "<number>\t<tooltip>" (what the bar shows) and quits.
//   CCNOTIFY_TEST_USAGE=1           prints one line per row of the "Limits" block and quits; CCNOTIFY_TEST_NOW=<epoch>
//                                   fixes "now" for it and the zone is the environment's (TZ=America/Panama).
import Cocoa
import Darwin

// MARK: - Paths

let env = ProcessInfo.processInfo.environment
let ccHome: String = {
    if let h = env["CCNOTIFY_HOME"], !h.isEmpty { return (h as NSString).expandingTildeInPath }
    let claudeDir = (env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.claude")
    return (claudeDir as NSString).expandingTildeInPath + "/ccnotify"
}()
let stateDir = ccHome + "/state"
let sessionsDir = stateDir + "/sessions"
let seenDir = stateDir + "/seen"
let endedDir = stateDir + "/ended"
let contextDir = stateDir + "/context"
let usageFile = stateDir + "/usage.json"
let queueDir = stateDir + "/queue"
let appStateDir = stateDir + "/menubar"
let pinsDir = appStateDir + "/pins"
let remindersDir = appStateDir + "/reminders"
let focusScript = ccHome + "/bin/focus_session.py"
let popupApp = ccHome + "/CCNotify.app"
/// Seconds in a "minute" of a reminder: 60, or 1 in tests.
let secondsPerMinute: Double = env["CCNOTIFY_TEST_MINUTES_AS_SECONDS"] == "1" ? 1 : 60
/// The gap the status item's button leaves between the icon and the number (measured on real macOS 12 captures).
let iconNumberGap: CGFloat = 5

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
}

/// Atomic private write (temp file, mode 0600, rename), like the popup does.
@discardableResult
func writePrivate(_ data: Data, to path: String) -> Bool {
    let tmp = path + ".tmp\(getpid())"
    guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
    if rename(tmp, path) != 0 {
        try? FileManager.default.removeItem(atPath: tmp)
        return false
    }
    return true
}

func safeName(_ s: String) -> String {
    // Same rule as notify.py: only [A-Za-z0-9._-], at most 128 chars, no leading dots
    let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    var cleaned = String(String(s.prefix(128)).map { ok.contains($0) ? $0 : "_" })
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    return cleaned.isEmpty ? "unknown" : cleaned
}

// MARK: - Config and localization

/// config.json as a dictionary (empty if missing or unreadable).
func configObject() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: ccHome + "/config.json"),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
    return o
}

/// popup.style from config.json: "color" (the default), "neutral" or "mono". Mono means grayscale only.
func configStyle() -> String {
    if let popup = configObject()["popup"] as? [String: Any], let style = popup["style"] as? String { return style.lowercased() }
    return "color"
}

/// popup.private: the hooks keep message text out of the state files, and so does this app.
func configPrivate() -> Bool {
    ((configObject()["popup"] as? [String: Any])?["private"] as? Bool) ?? false
}

/// Grayscale panel (popup.style = "mono"). Set on every refresh; the colors below read it when a panel is built.
enum PanelStyle { static var mono = false }

struct Strings {
    let es: Bool

    init() {
        var lang = "auto"
        if let l = configObject()["language"] as? String { lang = l.lowercased() }
        switch lang {
        case "es": es = true
        case "en": es = false
        default: es = (Locale.preferredLanguages.first ?? "en").hasPrefix("es")
        }
    }

    var code: String { es ? "es" : "en" }
    var title: String { es ? "Sesiones de Claude" : "Claude sessions" }
    var panelTitle: String { es ? "Sesiones" : "Sessions" }
    var noSessions: String { es ? "No hay sesiones de Claude abiertas" : "No Claude sessions open" }
    var allCaughtUp: String { es ? "Todo al día" : "All caught up" }
    var interrupted: String { es ? "La interrumpiste" : "You interrupted it" }
    var youAsked: String { es ? "Pediste" : "You asked" }
    var stillWorking: String { es ? "Sigue trabajando." : "Still working." }
    var noMessage: String { es ? "Sin mensaje." : "No message." }
    var doneFallback: String { es ? "Listo para leer" : "Ready to read" }
    var needsFallback: String { es ? "Te está esperando para seguir" : "Waiting for you to continue" }
    /// Subtitle of the fallback notification (the same labels notify.py uses).
    func popupLabel(_ kind: String) -> String {
        switch kind {
        case "permission": return es ? "Pide permiso" : "Needs permission"
        case "question": return es ? "Pregunta" : "Question"
        default: return es ? "Terminó" : "Done"
        }
    }

    // State words (the first word of a box)
    var permission: String { es ? "Permiso" : "Permission" }
    var question: String { es ? "Pregunta" : "Question" }
    var needsYou: String { es ? "Te necesita" : "Needs you" }
    var finished: String { es ? "Terminó" : "Finished" }
    var working: String { es ? "Trabajando" : "Working" }
    var read: String { es ? "Leída" : "Read" }
    func reminderIn(_ seconds: Double) -> String {
        seconds <= 60 ? (es ? "En <1 min" : "In <1 min") : (es ? "En \(Int(ceil(seconds / 60))) min" : "In \(Int(ceil(seconds / 60))) min")
    }

    // Buttons
    var goToChat: String { es ? "Ir al chat" : "Go to chat" }
    var remindMe: String { es ? "Recuérdame" : "Remind me" }
    var remindMeIn: String { es ? "Recuérdame en" : "Remind me in" }
    var removeReminder: String { es ? "Quitar recordatorio" : "Remove reminder" }
    var markRead: String { es ? "Marcar leída" : "Mark as read" }
    var markAllRead: String { es ? "Marcar todo como leído" : "Mark all as read" }
    var pin: String { es ? "Fijar" : "Pin" }
    var unpin: String { es ? "Soltar" : "Unpin" }
    var cancel: String { es ? "Cancelar" : "Cancel" }
    var quit: String { es ? "Salir" : "Quit" }
    var options: String { es ? "Opciones" : "Options" }
    var pinned: String { es ? "Fijada" : "Pinned" }

    // Options page
    var back: String { es ? "‹ Volver" : "‹ Back" }
    var sectionMenuBar: String { es ? "Barra de menú" : "Menu bar" }
    var sectionEmoji: String { "Emoji" }
    var sectionPanel: String { "Panel" }
    var emojiForEach: String { es ? "Emoji en cada sesión" : "Emoji for each session" }
    var emojiNote: String {
        es ? "Para cambiar el de una sola sesión, haz clic en su emoji."
           : "To change one session's emoji, click it in the list."
    }
    func showMore(_ n: Int) -> String { es ? "Mostrar \(n) más" : "Show \(n) more" }
    var showLess: String { es ? "Mostrar menos" : "Show less" }
    var optBubble: String { es ? "Globo con el mensaje completo" : "Bubble with the whole message" }
    var optUsage: String { es ? "Uso de 5 horas y de la semana" : "5-hour and weekly usage" }
    var optContext: String { es ? "Contexto de cada sesión" : "Context of each session" }
    var pickEmoji: String { es ? "Elige un emoji" : "Pick an emoji" }
    var automatic: String { es ? "Automático" : "Automatic" }
    var changeEmoji: String { es ? "Cambiar emoji" : "Change emoji" }
    /// Name of a family of emoji (a folder of assets/emoji); an unknown folder shows its name with a capital.
    func family(_ key: String) -> String {
        let names: [String: (en: String, es: String)] = [
            "nature": ("Nature", "Naturaleza"), "bugs": ("Bugs", "Bichos"), "music": ("Music", "Música"),
            "cozy": ("Cozy", "Acogedor"), "adventure": ("Adventure", "Aventura"), "animals": ("Animals", "Animales"),
            "fruits": ("Fruits", "Frutas"), "gems": ("Gems & objects", "Gemas y objetos"), "colors": ("Colors", "Colores")]
        if let n = names[key] { return es ? n.es : n.en }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    func agents(_ n: Int) -> String {
        es ? "\(n) agente\(n > 1 ? "s" : "")" : "\(n) agent\(n > 1 ? "s" : "")"
    }

    /// "now", "3 min", "2 h", "1 d": how long ago, without the "ago".
    func age(_ t: Double) -> String {
        let s = max(0, Date().timeIntervalSince1970 - t)
        if s < 60 { return es ? "ahora" : "now" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86400 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86400)) d"
    }

    /// The gray breakdown in the panel header: "2 need you · 1 unread · 1 working".
    func breakdown(needs: Int, unread: Int, working: Int) -> String {
        var parts: [String] = []
        if needs > 0 { parts.append(es ? "\(needs) te necesita\(needs > 1 ? "n" : "")" : "\(needs) need\(needs > 1 ? "" : "s") you") }
        if unread > 0 { parts.append(es ? "\(unread) sin leer" : "\(unread) unread") }
        if working > 0 { parts.append(es ? "\(working) trabajando" : "\(working) working") }
        return parts.joined(separator: " · ")
    }

    /// Tooltip and accessibility label of the status item.
    func barTip(waiting: Int, working: Int) -> String {
        var parts: [String] = []
        if waiting > 0 {
            parts.append(es ? (waiting == 1 ? "1 sesión te espera" : "\(waiting) sesiones te esperan")
                            : (waiting == 1 ? "1 session is waiting for you" : "\(waiting) sessions are waiting for you"))
        }
        if working > 0 { parts.append(es ? "\(working) trabajando" : "\(working) working") }
        return parts.isEmpty ? (es ? "Nada te espera" : "Nothing is waiting for you") : parts.joined(separator: " · ")
    }

    // Limits block
    var limits: String { es ? "Límites" : "Limits" }
    var fiveHours: String { es ? "5 horas" : "5 hours" }
    var week: String { es ? "Semana" : "Week" }
    var weekdaysShort: [String] {
        es ? ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"] : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }
    var weekdaysLong: [String] {
        es ? ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
           : ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    }
    var months: [String] {
        es ? ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
           : ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    }
    var resetsLong: String { es ? "se reinicia" : "resets" }
    var resetsMid: String { es ? "reinicia" : "resets" }
    var resetDone: String { es ? "se reinició" : "reset" }
    var today: String { es ? "hoy" : "today" }
    var tomorrow: String { es ? "mañana" : "tomorrow" }

    /// "3:30 PM" / "3:30 p. m.": a 12-hour clock built here (it does not depend on the Mac using 24 hours).
    func clock(_ d: Date, _ cal: Calendar) -> String {
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        let h12 = h % 12 == 0 ? 12 : h % 12
        let mm = m < 10 ? "0\(m)" : "\(m)"
        return "\(h12):\(mm)" + (es ? (h < 12 ? " a. m." : " p. m.") : (h < 12 ? " AM" : " PM"))
    }

    /// "today at 3:30 PM", "tomorrow at …", "yesterday at …" or "on Saturday, November 20 at 9:00 AM".
    func dateWords(_ r: Double, now: Double, _ cal: Calendar) -> String {
        let d = Date(timeIntervalSince1970: r)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: now)),
                                      to: cal.startOfDay(for: d)).day ?? 0
        let wd = weekdaysLong[cal.component(.weekday, from: d) - 1], dayNum = cal.component(.day, from: d)
        let month = months[cal.component(.month, from: d) - 1]
        if es {
            let day: String
            switch days {
            case 0: day = "hoy"
            case 1: day = "mañana"
            case -1: day = "ayer"
            default: day = "el \(wd) \(dayNum) de \(month)"
            }
            return day + ((cal.component(.hour, from: d) % 12) == 1 ? " a la " : " a las ") + clock(d, cal)
        }
        let day: String
        switch days {
        case 0: day = "today"
        case 1: day = "tomorrow"
        case -1: day = "yesterday"
        default: day = "on \(wd), \(month) \(dayNum)"
        }
        return day + " at " + clock(d, cal)
    }

    /// "25 min", "2 h 38 min" or, from a day on, "4 days" (for the tooltip).
    func remaining(_ seconds: Double) -> String {
        if seconds < 86400 { return duration(seconds) }
        let d = max(1, Int((seconds / 86400).rounded()))
        return es ? (d == 1 ? "1 día" : "\(d) días") : (d == 1 ? "1 day" : "\(d) days")
    }
    var inWord: String { es ? "en" : "in" }
    var resetTipStart: String { es ? "Se reinicia " : "Resets " }
    var resetTipDone: String { es ? "Se reinició " : "Reset " }
    var fiveTipNoReset: String { es ? "Uso de la ventana de 5 horas" : "Usage of the 5-hour window" }
    var weekTipNoReset: String { es ? "Uso de la semana" : "Usage of the week" }
}

/// "N min", "N h" or "N h M min" (rounded up, never 0 min).
func duration(_ seconds: Double) -> String {
    let m = max(1, Int(ceil(seconds / 60)))
    if m < 60 { return "\(m) min" }
    return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
}

// MARK: - Colors (dynamic)

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }
}

/// The label color (black in light, white in dark) with another opacity. Truly dynamic: a
/// `labelColor.withAlphaComponent(...)` kept in a constant would keep the theme it had when it was created.
func labelAlpha(_ a: CGFloat) -> NSColor {
    NSColor.dynamic(light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: a), dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a))
}

func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// Warning colors of the high percentages (the "Soft" palette): ochre, orange and soft red (see pctStyle).
let orangeWarn = NSColor.dynamic(light: 0xA85A38, dark: 0xE39A78)
let ochreWarn = NSColor.dynamic(light: 0x8A6A1F, dark: 0xD6B25E)
let redWarn = NSColor.dynamic(light: 0xB24A3F, dark: 0xEA8A80)

/// Color and weight of a percentage (a row's "ctx" and the account usage), in three steps on the integer that is
/// shown: up to 59 % the usual color; 60-79 ochre; 80-89 orange and semibold; from 90 soft red and semibold.
/// In mono style only the weight changes.
func pctStyle(_ p: Double, normal: NSColor) -> (color: NSColor, weight: NSFont.Weight) {
    let r = Int(p.rounded())
    if PanelStyle.mono { return (r >= 80 ? NSColor.labelColor : normal, r >= 80 ? .semibold : .regular) }
    if r >= 90 { return (redWarn, .semibold) }
    if r >= 80 { return (orangeWarn, .semibold) }
    if r >= 60 { return (ochreWarn, .regular) }
    return (normal, .regular)
}

/// "Level" of a percentage, same cuts as pctStyle (for the test hook).
func pctLevel(_ p: Double) -> String {
    let r = Int(p.rounded())
    return r >= 90 ? "red" : (r >= 80 ? "orange" : (r >= 60 ? "ochre" : "neutral"))
}

/// The colors of a box in the list: state word, fill, border and the two kinds of button.
struct Ink {
    let text: NSColor           // state word
    let fill: NSColor
    let line: NSColor           // the box's border
    let primary: NSColor        // fill of the main button
    let primaryText: NSColor
    let secondaryText: NSColor  // text of the secondary buttons
    let secondaryLine: NSColor  // border of the secondary buttons
}

/// A colored box: the main button is a fuller shade with white text; the secondary ones take the box's color.
func colorInk(text: NSColor, fill: NSColor, line: NSColor, primary: UInt32) -> Ink {
    Ink(text: text, fill: fill, line: line, primary: NSColor(hex: primary), primaryText: .white,
        secondaryText: text, secondaryLine: line)
}

/// A neutral box (working, read, reminded; every box in mono): dark main button (light in the dark theme), gray secondary ones.
func neutralInk(text: NSColor, fill: NSColor, line: NSColor) -> Ink {
    Ink(text: text, fill: fill, line: line, primary: labelAlpha(0.85), primaryText: .windowBackgroundColor,
        secondaryText: labelAlpha(0.8), secondaryLine: .separatorColor)
}

/// What each box of the list is (the state word and the colors come from it).
enum Tone {
    case permission, question, needs, finished, reminded, working, read

    var ink: Ink {
        if PanelStyle.mono {
            switch self {
            case .permission, .question, .needs:
                return neutralInk(text: .labelColor, fill: labelAlpha(0.07), line: labelAlpha(0.30))
            case .finished: return neutralInk(text: labelAlpha(0.85), fill: labelAlpha(0.04), line: labelAlpha(0.22))
            case .reminded: return neutralInk(text: .secondaryLabelColor, fill: labelAlpha(0.04), line: labelAlpha(0.22))
            case .working: return neutralInk(text: .secondaryLabelColor, fill: labelAlpha(0.04), line: .separatorColor)
            case .read: return neutralInk(text: .tertiaryLabelColor, fill: .clear, line: .separatorColor)
            }
        }
        switch self {
        case .permission, .needs: return Tone.permissionInk
        case .question: return Tone.questionInk
        case .finished: return Tone.finishedInk
        case .reminded: return neutralInk(text: Tone.permissionInk.text, fill: labelAlpha(0.04), line: Tone.permissionInk.line)
        case .working: return neutralInk(text: .secondaryLabelColor, fill: labelAlpha(0.04), line: .separatorColor)
        case .read: return neutralInk(text: .tertiaryLabelColor, fill: .clear, line: .separatorColor)
        }
    }

    static let permissionInk = colorInk(
        text: .dynamic(light: 0xA85A38, dark: 0xE39A78),
        fill: .dynamic(light: rgba(235, 104, 52, 0.07), dark: rgba(217, 89, 38, 0.14)),
        line: .dynamic(light: rgba(235, 104, 52, 0.28), dark: rgba(225, 126, 86, 0.35)), primary: 0xC4734F)
    static let questionInk = colorInk(
        text: .dynamic(light: 0x3F6FA8, dark: 0x7FB0EA),
        fill: .dynamic(light: rgba(42, 120, 214, 0.06), dark: rgba(57, 135, 229, 0.14)),
        line: .dynamic(light: rgba(42, 120, 214, 0.28), dark: rgba(93, 157, 234, 0.35)), primary: 0x5B88BF)
    static let finishedInk = colorInk(
        text: .dynamic(light: 0x2F7D5F, dark: 0x5CC0A0),
        fill: .dynamic(light: rgba(27, 175, 122, 0.07), dark: rgba(25, 158, 112, 0.14)),
        line: .dynamic(light: rgba(27, 175, 122, 0.28), dark: rgba(57, 172, 132, 0.35)), primary: 0x4E9A7B)
}

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
    var kind: String           // permission | question (only with state needs; may be empty)
    var seen: Bool
    var since: Double
    var summary: String
    var doneText: String
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

/// A reminder: show the session again when `at` comes, if it is still in the same state (`since`).
struct Reminder {
    var key: String        // file name without .json (the session id as safeName makes it)
    var path: String
    var at: Double
    var since: Double
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
    writePrivate(String(format: "%.3f", Date().timeIntervalSince1970).data(using: .utf8) ?? Data(), to: seenDir + "/" + safeName(id))
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

/// How full a conversation's context is (0-100), if the status line wrote its file.
func readContext(_ id: String) -> Double? {
    guard let data = FileManager.default.contents(atPath: contextDir + "/" + safeName(id) + ".json"),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let pct = number(o["pct"]), pct.isFinite else { return nil }
    return min(100, max(0, pct))
}

/// Account usage: percentage and reset time of the 5-hour window and of the week (each piece may be missing).
struct Usage {
    var fivePct: Double?, fiveReset: Double?, weekPct: Double?, weekReset: Double?
}

func readUsage() -> Usage? {
    guard let data = FileManager.default.contents(atPath: usageFile),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    func window(_ key: String) -> (pct: Double?, reset: Double?) {
        guard let w = o[key] as? [String: Any] else { return (nil, nil) }
        let p = number(w["pct"]).flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let r = number(w["resets_at"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return (p, r)
    }
    let five = window("five_hour"), week = window("seven_day")
    return Usage(fivePct: five.pct, fiveReset: five.reset, weekPct: week.pct, weekReset: week.reset)
}

/// "37 %" with a no-break space, so the % never ends up alone on another line.
func pctText(_ p: Double) -> String { "\(Int(p.rounded()))\u{00A0}%" }

/// "Now" for the limits block: the clock, except in tests (CCNOTIFY_TEST_NOW=<epoch>).
func usageNow() -> Double {
    if let v = env["CCNOTIFY_TEST_NOW"], let d = Double(v), d.isFinite { return d }
    return Date().timeIntervalSince1970
}

func localCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone.current      // the Mac's (in tests, the one in TZ)
    return c
}

/// A row of the "Limits" block. `text` is the reset part ("resets 3:30 PM"); `mid` ("resets 3:30 PM") and `short`
/// ("3:30 PM") are shorter forms for when the long one does not fit beside the bar; `tip` is the tooltip's long form.
/// `pct` nil: no filled bar and no percentage.
struct UsageRow {
    let label: String
    let pct: Double?
    let text: String
    let mid: String
    let short: String
    let tip: String
}

/// The rows of the limits block from usage.json (pure: depends on `u`, `now`, the time zone and the language).
/// A missing percentage drops its row; with the window already reset there is no percentage (the stored one is the old one).
func usageRows(_ u: Usage?, now: Double, _ L: Strings) -> [UsageRow] {
    guard let u = u else { return [] }
    let cal = localCalendar()
    var rows: [UsageRow] = []
    func reset(_ label: String, _ r: Double) -> UsageRow {
        UsageRow(label: label, pct: nil, text: L.resetDone, mid: L.resetDone, short: L.resetDone,
                 tip: L.resetTipDone + L.dateWords(r, now: now, cal))
    }
    if let p = u.fivePct {
        if let r = u.fiveReset {
            if r <= now {
                rows.append(reset(L.fiveHours, r))
            } else {
                let left = r - now
                let clock = L.clock(Date(timeIntervalSince1970: r), cal)
                let rest = left < 3600 ? " · \(L.inWord) \(max(1, Int(ceil(left / 60)))) min" : ""
                rows.append(UsageRow(label: L.fiveHours, pct: p, text: L.resetsLong + " " + clock + rest,
                                     mid: L.resetsMid + " " + clock + rest, short: clock + rest,
                                     tip: L.resetTipStart + L.dateWords(r, now: now, cal) + " (\(L.inWord) " + L.remaining(left) + ")"))
            }
        } else {
            rows.append(UsageRow(label: L.fiveHours, pct: p, text: "", mid: "", short: "", tip: L.fiveTipNoReset))
        }
    }
    if let p = u.weekPct {
        if let r = u.weekReset {
            if r <= now {
                rows.append(reset(L.week, r))
            } else {
                let left = r - now
                let d = Date(timeIntervalSince1970: r)
                let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: now)),
                                              to: cal.startOfDay(for: d)).day ?? 0
                let day = left < 86400 ? (days == 0 ? L.today : L.tomorrow) : L.weekdaysShort[cal.component(.weekday, from: d) - 1]
                let when = day + " " + L.clock(d, cal)
                rows.append(UsageRow(label: L.week, pct: p, text: L.resetsLong + " " + when, mid: L.resetsMid + " " + when, short: when,
                                     tip: L.resetTipStart + L.dateWords(r, now: now, cal) + " (\(L.inWord) " + L.remaining(left) + ")"))
            }
        } else {
            rows.append(UsageRow(label: L.week, pct: p, text: "", mid: "", short: "", tip: L.weekTipNoReset))
        }
    }
    return rows
}

// MARK: - Options (the options page) and the emoji of each session

/// The icons offered for the status item (value = SF Symbol name, then the name shown as a tooltip). To change the
/// offer, edit only this list; the ones this macOS does not have are not shown.
let barIcons: [(symbol: String, en: String, es: String)] = [
    ("bubble.left.and.bubble.right", "Two bubbles", "Dos globos"),
    ("terminal.fill", "Terminal", "Terminal"),
    ("bolt.fill", "Bolt", "Rayo"),
    ("list.bullet.rectangle", "List", "Lista"),
    ("chevron.left.forwardslash.chevron.right", "Code", "Código"),
    ("flame.fill", "Flame", "Fuego"),
    ("tornado", "Tornado", "Tornado"),
    ("eyes", "Eyes", "Ojos"),
    ("rays", "Rays", "Rayos"),
    ("circle.hexagonpath.fill", "Hexagon", "Hexágono"),
]
/// The icon used when nothing is chosen or the chosen one does not exist on this Mac.
let defaultBarIcon = "bubble.left.and.bubble.right"
/// Value of "emoji_theme" that turns the emoji off.
let emojiOff = "none"
/// The family used when the emoji are turned on from the options page.
let defaultEmojiFamily = "nature"

let optionsFile = appStateDir + "/options.json"
let emojiAutoFile = appStateDir + "/emoji-auto.json"
let emojiChosenFile = appStateDir + "/emoji-chosen.json"
/// The folders of emoji: <family>/<name>.png. They live in the app's bundle (Contents/Resources/emoji);
/// CCNOTIFY_EMOJI_DIR points somewhere else for tests.
let emojiDir: String = {
    if let d = env["CCNOTIFY_EMOJI_DIR"], !d.isEmpty { return (d as NSString).expandingTildeInPath }
    return (Bundle.main.resourcePath ?? "") + "/emoji"
}()

/// A plain file or folder name: letters, digits, dot, dash, underscore; no leading dot.
func isPlainName(_ s: String) -> Bool {
    let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    return !s.isEmpty && s.count <= 80 && !s.hasPrefix(".") && s.allSatisfy { ok.contains($0) }
}

/// An SF Symbol name has this shape (whether it exists on this Mac is another matter: see `barImage`).
func isSymbolName(_ s: String) -> Bool {
    let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._")
    return !s.isEmpty && s.count <= 80 && s.allSatisfy { ok.contains($0) }
}

/// What the panel shows and the status item looks like. Lives in <CCNOTIFY_HOME>/state/menubar/options.json, which only
/// this app writes (never config.json). Missing or unreadable file: everything at its default.
///   {"icon": "<SF Symbol>", "emoji_theme": "<family>" | "none", "bubble": true, "usage": true, "context": true}
struct PanelOptions {
    var icon = defaultBarIcon
    var emojiFamily = defaultEmojiFamily      // a folder of the emoji, or `emojiOff`
    var bubble = true          // the bubble with the whole message
    var usage = true           // the "Limits" block
    var context = true         // "ctx NN %" in the rows

    /// The file as a dictionary (empty if missing or not a JSON object).
    static func raw() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: optionsFile),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return o
    }

    static func load() -> PanelOptions {
        let o = raw()
        var p = PanelOptions()
        if let s = o["icon"] as? String, isSymbolName(s) { p.icon = s }
        if let s = o["emoji_theme"] as? String, s == emojiOff || isPlainName(s) { p.emojiFamily = s }
        if let b = o["bubble"] as? Bool { p.bubble = b }
        if let b = o["usage"] as? Bool { p.usage = b }
        if let b = o["context"] as? Bool { p.context = b }
        return p
    }

    /// Changes those keys (only the five known ones, each with its own type) and keeps every other key of the file.
    @discardableResult
    static func save(_ changes: [String: Any]) -> Bool {
        var o = raw()
        for (k, v) in changes {
            switch k {
            case "icon": if let s = v as? String, isSymbolName(s) { o[k] = s }
            case "emoji_theme": if let s = v as? String, s == emojiOff || isPlainName(s) { o[k] = s }
            case "bubble", "usage", "context": if let b = v as? Bool { o[k] = b }
            default: break
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]) else { return false }
        ensureDir(appStateDir)
        return writePrivate(data, to: optionsFile)
    }
}

/// True once there is an options page to open: shows the gear in the footer and makes it call `openOptions`.
let hasOptionsPage = true

// MARK: The emoji families

/// The families in the order of the options page: the first three are the ones seen without "Show more"; any other
/// folder found goes after these, alphabetically.
let emojiFamilyOrder = ["nature", "bugs", "music", "cozy", "adventure", "animals", "fruits", "gems", "colors"]

/// The families that have at least one PNG, with their files (sorted), in the order above.
func loadEmojiFamilies() -> [(family: String, files: [String])] {
    let fm = FileManager.default
    var found: [String: [String]] = [:]
    for f in (try? fm.contentsOfDirectory(atPath: emojiDir)) ?? [] where isPlainName(f) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: emojiDir + "/" + f, isDirectory: &isDir), isDir.boolValue else { continue }
        let png = ((try? fm.contentsOfDirectory(atPath: emojiDir + "/" + f)) ?? [])
            .filter { isPlainName($0) && $0.lowercased().hasSuffix(".png") }.sorted()
        if !png.isEmpty { found[f] = png }
    }
    let first = emojiFamilyOrder.filter { found[$0] != nil }
    let others = found.keys.filter { !emojiFamilyOrder.contains($0) }.sorted()
    return (first + others).map { ($0, found[$0] ?? []) }
}
let emojiFamilies = loadEmojiFamilies()

/// "family/name.png" with a plain name on each side, and the file there: its path.
func emojiPath(_ key: String) -> String? {
    let p = key.components(separatedBy: "/")
    guard p.count == 2, isPlainName(p[0]), isPlainName(p[1]), p[1].lowercased().hasSuffix(".png") else { return nil }
    let path = emojiDir + "/" + key
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

/// A readable name for a file of a family: "red-apple.png" -> "red apple".
func emojiLabel(_ key: String) -> String {
    ((key as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ")
}

var emojiImageCache: [String: NSImage] = [:]

/// The picture of an emoji, from the app's folder. In the mono style it is turned to grayscale (like everything else
/// in the panel).
func emojiImage(_ key: String) -> NSImage? {
    let cacheKey = (PanelStyle.mono ? "m:" : "c:") + key
    if let img = emojiImageCache[cacheKey] { return img }
    guard let path = emojiPath(key), let color = NSImage(contentsOfFile: path) else { return nil }
    var result = color
    if PanelStyle.mono, let tiff = color.tiffRepresentation, let ci = CIImage(data: tiff),
       let f = CIFilter(name: "CIColorControls") {
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(0.0, forKey: kCIInputSaturationKey)
        if let out = f.outputImage {
            let rep = NSCIImageRep(ciImage: out)
            let gray = NSImage(size: color.size)
            gray.addRepresentation(rep)
            result = gray
        }
    }
    emojiImageCache[cacheKey] = result
    return result
}

/// FNV-1a of a string: the stable starting point of a session in a family.
func fnv1a(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return h
}

/// What each session shows, computed once per refresh (see `MenuBar.assignEmoji`): session id -> "family/name.png".
enum Emoji {
    static var keys: [String: String] = [:]
    static var manual: Set<String> = []     // the sessions whose emoji you chose by hand
}

/// The small picture of a session (the row's image, drawn left of the state word). nil draws nothing and takes no room.
func sessionImage(for id: String) -> NSImage? {
    guard let key = Emoji.keys[id] else { return nil }
    return emojiImage(key)
}

/// The image of a status item icon, or nil if this macOS does not have that symbol.
func barImage(_ symbol: String, label: String) -> NSImage? {
    guard isSymbolName(symbol), let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else { return nil }
    img.isTemplate = true
    return img
}

/// The icons offered on the options page: those of `barIcons` that exist here and, if the one in use is not among
/// them (written by hand in options.json), that one at the end: what is in use is always seen.
func offeredBarIcons(current: String, _ L: Strings) -> [(symbol: String, name: String)] {
    var list: [(symbol: String, name: String)] = barIcons.filter { barImage($0.symbol, label: "") != nil }
        .map { (symbol: $0.symbol, name: L.es ? $0.es : $0.en) }
    if barImage(current, label: "") != nil && !list.contains(where: { $0.symbol == current }) { list.append((current, current)) }
    return list
}

/// The icon that is really used for a requested value: that one, or the default if it does not exist here.
func resolvedBarIcon(_ requested: String) -> String {
    barImage(requested, label: "") != nil ? requested : defaultBarIcon
}

// MARK: - Panel pieces (everything is drawn by hand: dynamic colors resolve themselves on every redraw)

func attr(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor,
          digits: Bool = false, lineSpacing: CGFloat = 0) -> NSAttributedString {
    let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                      : NSFont.systemFont(ofSize: size, weight: weight)
    var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if lineSpacing > 0 {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        a[.paragraphStyle] = p
    }
    return NSAttributedString(string: s, attributes: a)
}

/// "ctx 62 % · <rest>": only the context part changes color and weight, per pctStyle.
func withContext(_ pct: Double?, rest: String, size: CGFloat, color: NSColor, digits: Bool = false) -> NSAttributedString {
    let t = NSMutableAttributedString()
    if let p = pct {
        let e = pctStyle(p, normal: color)
        t.append(attr("ctx " + pctText(p), size, e.weight, e.color, digits: digits))
        t.append(attr(" · ", size, .regular, color, digits: digits))
    }
    t.append(attr(rest, size, .regular, color, digits: digits))
    return t
}

/// One or several lines of text (with an ellipsis if it does not fit), measured and drawn with TextKit.
final class TextBlock: NSView {
    let storage: NSTextStorage
    let layout: NSLayoutManager
    let container: NSTextContainer
    let textSize: NSSize

    init(_ t: NSAttributedString, width: CGFloat, lines: Int = 1) {
        let st = NSTextStorage(attributedString: t)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: width, height: 100_000))
        tc.lineFragmentPadding = 0
        tc.maximumNumberOfLines = lines
        tc.lineBreakMode = .byTruncatingTail
        lm.addTextContainer(tc)
        st.addLayoutManager(lm)
        _ = lm.glyphRange(for: tc)
        let r = lm.usedRect(for: tc)
        storage = st
        layout = lm
        container = tc
        textSize = NSSize(width: ceil(r.width), height: ceil(r.height))
        super.init(frame: NSRect(origin: .zero, size: textSize))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let range = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: range, at: .zero)      // backgrounds of inline `code`
        layout.drawGlyphs(forGlyphRange: range, at: .zero)
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { storage.string }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go through to the row or button below
}

enum ButtonStyle { case primary, secondary, pill, text }

/// A hand-drawn button: filled (primary), thin full border (secondary, pill) or text only.
/// The ones in the boxes are 26 pt tall (12.5 pt text, 3 x 10 padding, 1 pt border).
final class PanelButton: NSView {
    let title: String
    let style: ButtonStyle
    let ink: Ink
    let onClick: () -> Void
    let size: CGFloat
    var hovered = false { didSet { needsDisplay = true } }
    var pressed = false { didSet { needsDisplay = true } }

    init(_ title: String, style: ButtonStyle, ink: Ink, size: CGFloat = 12.5, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.ink = ink
        self.onClick = action
        self.size = size
        let measured = attr(title, size, style == .primary ? .semibold : .regular, .labelColor).size()
        let w: CGFloat, h: CGFloat
        switch style {
        case .primary, .secondary: w = ceil(measured.width) + 22; h = 26
        case .pill: w = ceil(measured.width) + 18; h = 24
        case .text: w = ceil(measured.width) + 6; h = 24
        }
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { DispatchQueue.main.async { self.onClick() } }   // later: the click may rebuild the panel
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: 0.5, dy: 0.5)
        let color: NSColor
        switch style {
        case .primary:
            let shape = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
            ink.primary.setFill()
            shape.fill()
            if pressed || hovered {   // a veil of the text color: darkens in light and lightens in dark
                labelAlpha(pressed ? 0.16 : 0.08).setFill()
                shape.fill()
            }
            color = ink.primaryText
        case .secondary, .pill:
            let r: CGFloat = style == .pill ? bounds.height / 2 : 7
            let shape = NSBezierPath(roundedRect: inner, xRadius: r - 0.5, yRadius: r - 0.5)
            if hovered || pressed {
                labelAlpha(pressed ? 0.10 : 0.06).setFill()
                shape.fill()
            }
            shape.lineWidth = 1
            ink.secondaryLine.setStroke()
            shape.stroke()
            color = ink.secondaryText
        case .text:
            color = (hovered || pressed) ? NSColor.labelColor : labelAlpha(0.7)
        }
        let t = attr(title, size, style == .primary ? .semibold : .regular, color)
        let m = t.size()
        t.draw(at: NSPoint(x: ((bounds.width - m.width) / 2).rounded(), y: ((bounds.height - m.height) / 2).rounded()))
    }
}

/// The footer's gear (SF Symbol `gearshape`, 13 pt): the color of the footer buttons' text and, with the mouse
/// over it, stronger, like them. Only added to the footer when `hasOptionsPage` is true.
final class GearButton: NSView {
    let onClick: () -> Void
    let image: NSImage?
    let label: String
    var hovered = false { didSet { needsDisplay = true } }
    var pressed = false { didSet { needsDisplay = true } }

    init(label: String, action: @escaping () -> Void) {
        onClick = action
        self.label = label
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: label)?.withSymbolConfiguration(cfg)
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(image?.size.width ?? 14) + 6, height: 24))
        toolTip = label
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { DispatchQueue.main.async { self.onClick() } }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }
        let color = (hovered || pressed) ? NSColor.labelColor : labelAlpha(0.7)
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)      // the symbol is a template: painted with today's dynamic color
            return true
        }
        let o = NSPoint(x: ((bounds.width - img.size.width) / 2).rounded(), y: ((bounds.height - img.size.height) / 2).rounded())
        tinted.draw(in: NSRect(origin: o, size: img.size), from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }
}

/// The thin bar of one limit (96 x 5): a track in the label color at 10 % and a rounded fill in the step's color
/// (see pctStyle), at least 3 pt if there is any usage. Takes no clicks.
final class UsageBar: NSView {
    static let width: CGFloat = 96, height: CGFloat = 5
    let pct: Double?
    init(pct: Double?) {
        self.pct = pct
        super.init(frame: NSRect(x: 0, y: 0, width: UsageBar.width, height: UsageBar.height))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        labelAlpha(0.10).setFill()
        track.fill()
        guard let p = pct, p > 0 else { return }
        let w = min(bounds.width, max(3, bounds.width * CGFloat(p) / 100))
        NSGraphicsContext.saveGraphicsState()
        track.addClip()                      // the 3 pt fill does not stick out of the rounded track
        pctStyle(p, normal: labelAlpha(0.45)).color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                     xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// One row of the "Limits" block (height 20): its parts are subviews; the row carries the tooltip and the accessibility text.
final class UsageRowView: NSView {
    let descriptionText: String
    init(width: CGFloat, description: String, tip: String) {
        descriptionText = description
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { descriptionText }
}

/// A thin rule between the list, the limits and the footer.
final class Separator: NSView {
    var alpha: CGFloat = 0.17
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // separatorColor was barely visible on the real popover
        labelAlpha(alpha).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// Background of the whole popover content: window color, almost opaque (the real popover is translucent and lets
/// what is behind show through). Fills all the content; the popover clips it with its rounded shape.
final class BackdropView: NSView {
    override var isFlipped: Bool { true }   // the content stays anchored top left even if the popover changes height
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// Panel background: transparent inside the popover (the backdrop is behind it); opaque in the offscreen draws.
final class PanelView: NSView {
    let solid: Bool
    init(solid: Bool) {
        self.solid = solid
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if solid {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
    }
}

/// A box of the list: fill, thin full border and, inside, the line (34 pt) and, when open, the buttons.
/// A click on the line (not on a button) is "Go to chat".
final class RowBox: NSView {
    static let lineHeight: CGFloat = 34
    let sessionId: String
    let tone: Tone
    let onClick: () -> Void
    let descriptionText: String
    let ink: Ink

    init(id: String, tone: Tone, width: CGFloat, description: String, action: @escaping () -> Void) {
        sessionId = id
        self.tone = tone
        ink = tone.ink
        descriptionText = description
        onClick = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: RowBox.lineHeight))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}      // needed to receive the mouseUp
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) && p.y <= RowBox.lineHeight {
            DispatchQueue.main.async { self.onClick() }
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { descriptionText }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
        ink.fill.setFill()
        shape.fill()
        shape.lineWidth = 1
        ink.line.setStroke()
        shape.stroke()
    }
}

/// A session's picture (the row's optional image): drawn with high-quality interpolation at the size it gets. Takes no clicks.
final class PictureView: NSView {
    let image: NSImage
    init(_ image: NSImage, side: CGFloat) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// The pin of a pinned session (SF Symbol `pin.fill`, 11 pt, secondary color).
final class PinView: NSImageView {
    static let width: CGFloat = 12
    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: PinView.width, height: 14))
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: label)?.withSymbolConfiguration(cfg)
        contentTintColor = .secondaryLabelColor
        imageScaling = .scaleProportionallyDown
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A picture you can press (a row's emoji, or each one of the picker): a faint rounded background with the mouse over
/// it and, the one in use, a thin ring. The "mouse over" is set by the panel's mouse clock (see highlightCells), not by
/// a tracking area: that way it survives the rebuilds of the panel.
final class EmojiCell: NSView {
    static let margin: CGFloat = 2
    let image: NSImage
    let side: CGFloat
    let ring: Bool
    let descriptionText: String
    let onClick: () -> Void
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var pressed = false

    init(_ image: NSImage, side: CGFloat, ring: Bool, description: String, tip: String?, action: @escaping () -> Void) {
        self.image = image
        self.side = side
        self.ring = ring
        descriptionText = description
        onClick = action
        let t = side + 2 * EmojiCell.margin
        super.init(frame: NSRect(x: 0, y: 0, width: t, height: t))
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { DispatchQueue.main.async { self.onClick() } }   // later: the click rebuilds the panel
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { descriptionText }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            labelAlpha(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if ring {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
            shape.lineWidth = 1
            labelAlpha(0.55).setStroke()
            shape.stroke()
        }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds.insetBy(dx: EmojiCell.margin, dy: EmojiCell.margin), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A row of the options page for one family of emoji: its name (a fixed column) and, right after it, a strip with the
/// family's pictures (20 pt, 5 pt apart, as many as fit). The chosen one has a border in the label color, a faint
/// fill and a semibold name. The pictures are drawn inside the row: all of it is one click area.
final class FamilyRow: NSView {
    static let height: CGFloat = 36
    static let nameColumn: CGFloat = 112
    static let stripX: CGFloat = 12 + nameColumn
    /// How many 20 pt pictures, 5 pt apart, fit in the strip, leaving 10 pt on the right.
    static func fit(width: CGFloat) -> Int { max(0, Int((width - 10 - stripX + 5) / 25)) }
    static let restFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    let name: String
    let chosen: Bool
    let pictures: [NSImage]      // the ones that are seen
    let rest: Int                // how many do not fit: announced with "+N" at the end of the strip
    let onClick: () -> Void
    var pressed = false { didSet { needsDisplay = true } }

    /// `pictures` are all of the family, in file order. If they do not all fit, the strip ends with "+N" (6 pt after the
    /// last picture) and as many are shown as fit leaving room for it: they never overlap.
    init(name: String, pictures: [NSImage], chosen: Bool, width: CGFloat, action: @escaping () -> Void) {
        self.name = name
        let most = FamilyRow.fit(width: width)
        var shown = min(pictures.count, most)
        if pictures.count > most {
            let free = width - 10 - FamilyRow.stripX
            shown = most
            while shown > 0 {
                let w = ceil(NSAttributedString(string: "+\(pictures.count - shown)",
                                                attributes: [.font: FamilyRow.restFont]).size().width)
                if CGFloat(shown) * 25 - 5 + 6 + w <= free { break }
                shown -= 1
            }
        }
        self.pictures = Array(pictures.prefix(shown))
        rest = pictures.count - shown
        self.chosen = chosen
        onClick = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: FamilyRow.height))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { DispatchQueue.main.async { self.onClick() } }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { chosen ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
        if chosen {
            labelAlpha(0.06).setFill()
            shape.fill()
        } else if pressed {
            labelAlpha(0.05).setFill()
            shape.fill()
        }
        shape.lineWidth = 1
        (chosen ? labelAlpha(0.55) : NSColor.separatorColor).setStroke()
        shape.stroke()
        let t = attr(name, 13, chosen ? .semibold : .regular, .labelColor)
        let m = t.size()
        t.draw(with: NSRect(x: 12, y: ((bounds.height - m.height) / 2).rounded(), width: FamilyRow.nameColumn - 4, height: m.height),
               options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        NSGraphicsContext.current?.imageInterpolation = .high
        for (k, img) in pictures.enumerated() {
            img.draw(in: NSRect(x: FamilyRow.stripX + CGFloat(k) * 25, y: ((bounds.height - 20) / 2).rounded(), width: 20, height: 20),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if rest > 0 {
            let n = NSAttributedString(string: "+\(rest)", attributes: [.font: FamilyRow.restFont,
                                                                        .foregroundColor: NSColor.secondaryLabelColor])
            n.draw(at: NSPoint(x: FamilyRow.stripX + CGFloat(pictures.count) * 25 - 5 + 6,
                               y: ((bounds.height - n.size().height) / 2).rounded()))
        }
    }
}

/// A square button (28 x 28) for the choice of the status item's icon: the symbol (16 pt, label color). The chosen one
/// looks like the chosen family. The tooltip is its name.
final class BarIconButton: NSView {
    let name: String
    let chosen: Bool
    let image: NSImage
    let side: CGFloat
    let onClick: () -> Void
    var pressed = false { didSet { needsDisplay = true } }

    init(name: String, symbol: NSImage, chosen: Bool, side: CGFloat = 28, action: @escaping () -> Void) {
        self.side = side
        self.name = name
        self.chosen = chosen
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        image = symbol.withSymbolConfiguration(cfg) ?? symbol
        onClick = action
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        toolTip = name
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { DispatchQueue.main.async { self.onClick() } }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { chosen ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
        if chosen {
            labelAlpha(0.06).setFill()
            shape.fill()
        } else if pressed {
            labelAlpha(0.05).setFill()
            shape.fill()
        }
        shape.lineWidth = 1
        (chosen ? labelAlpha(0.55) : NSColor.separatorColor).setStroke()
        shape.stroke()
        NSGraphicsContext.current?.imageInterpolation = .high
        let img = image
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            NSColor.labelColor.set()
            r.fill(using: .sourceAtop)      // the symbol is a template: painted with today's dynamic color
            return true
        }
        let o = NSPoint(x: ((bounds.width - img.size.width) / 2).rounded(), y: ((bounds.height - img.size.height) / 2).rounded())
        tinted.draw(in: NSRect(origin: o, size: img.size), from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }
}

/// A row of the options page with a checkbox (or a switch on the right): pressing anywhere on the row toggles it. The
/// checkbox is drawn by hand (a 14 pt rounded square; on, filled with the label color and a tick).
final class OptionRow: NSView {
    let text: String
    let on: Bool
    let inset: CGFloat           // margin left and right (inside a grouped box)
    let asSwitch: Bool
    let onClick: () -> Void
    var pressed = false { didSet { needsDisplay = true } }

    init(_ text: String, on: Bool, width: CGFloat, height: CGFloat = 30, inset: CGFloat = 0, asSwitch: Bool = false,
         action: @escaping () -> Void) {
        self.text = text
        self.on = on
        self.inset = inset
        self.asSwitch = asSwitch
        onClick = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { DispatchQueue.main.async { self.onClick() } }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityValue() -> Any? { on ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        if pressed {
            labelAlpha(0.05).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: inset > 0 ? 0 : 6, yRadius: inset > 0 ? 0 : 6).fill()
        }
        let tick = NSColor.dynamic(light: .white, dark: NSColor(hex: 0x1E1E1E))
        if asSwitch {
            let t = attr(text, 13, .regular, .labelColor)
            t.draw(at: NSPoint(x: inset, y: ((bounds.height - t.size().height) / 2).rounded()))
            let track = NSRect(x: bounds.width - inset - 30, y: ((bounds.height - 18) / 2).rounded(), width: 30, height: 18)
            (on ? labelAlpha(0.85) : labelAlpha(0.18)).setFill()
            NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9).fill()
            let d: CGFloat = 14
            let knob = NSRect(x: on ? track.maxX - 2 - d : track.minX + 2, y: track.minY + 2, width: d, height: d)
            (on ? tick : NSColor.dynamic(light: .white, dark: NSColor(hex: 0xE6E6E6))).setFill()
            NSBezierPath(ovalIn: knob).fill()
            return
        }
        let box = NSRect(x: inset, y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14)
        let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        if on {
            labelAlpha(0.85).setFill()
            shape.fill()
            // The tick: white in light; in dark, the background color (white on white would not be seen)
            tick.setStroke()
            let v = NSBezierPath()
            v.move(to: NSPoint(x: box.minX + 3.5, y: box.minY + 7.3))
            v.line(to: NSPoint(x: box.minX + 6, y: box.minY + 9.8))
            v.line(to: NSPoint(x: box.minX + 10.6, y: box.minY + 4.4))
            v.lineWidth = 1.7
            v.lineCapStyle = .round
            v.lineJoinStyle = .round
            v.stroke()
        } else {
            shape.lineWidth = 1
            labelAlpha(0.4).setStroke()
            shape.stroke()
        }
        let t = attr(text, 13, .regular, .labelColor)
        let m = t.size()
        t.draw(at: NSPoint(x: inset + 14 + 10, y: ((bounds.height - m.height) / 2).rounded()))
    }
}

/// A grouped box of the options page (like System Settings): a faint tinted fill and a thin border all around. It takes
/// no clicks: what is inside belongs to the page.
final class GroupBox: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        labelAlpha(0.04).setFill()
        shape.fill()
        shape.lineWidth = 1
        labelAlpha(0.10).setStroke()
        shape.stroke()
    }
}

/// The last row of the families: the same height and shape as a family row, with "Show N more" (or "Show less") in the
/// accent color and a chevron on the right. Hand cursor and a faint fill with the mouse over it.
final class MoreRow: NSView {
    let text: String
    let expanded: Bool
    let onClick: () -> Void
    var pressed = false { didSet { needsDisplay = true } }
    var hovered = false { didSet { needsDisplay = true } }

    init(_ text: String, expanded: Bool, width: CGFloat, action: @escaping () -> Void) {
        self.text = text
        self.expanded = expanded
        onClick = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: FamilyRow.height))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { DispatchQueue.main.async { self.onClick() } }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
        if pressed { labelAlpha(0.07).setFill(); shape.fill() }
        else if hovered { labelAlpha(0.04).setFill(); shape.fill() }
        shape.lineWidth = 1
        NSColor.separatorColor.setStroke()
        shape.stroke()
        let color = Tone.needs.ink.text
        let t = attr(text, 13, .medium, color)
        t.draw(at: NSPoint(x: 12, y: ((bounds.height - t.size().height) / 2).rounded()))
        // The chevron: down (more) or up (less), a 1.7 pt stroke of 10 x 5.5 pt
        let cx = bounds.width - 12 - 5, cy = bounds.height / 2
        let v = NSBezierPath()
        let h: CGFloat = expanded ? -1 : 1
        v.move(to: NSPoint(x: cx - 5, y: cy - 2.75 * h))
        v.line(to: NSPoint(x: cx, y: cy + 2.75 * h))
        v.line(to: NSPoint(x: cx + 5, y: cy - 2.75 * h))
        v.lineWidth = 1.7
        v.lineCapStyle = .round
        v.lineJoinStyle = .round
        color.setStroke()
        v.stroke()
    }
}

/// Faint background of code blocks (and table rows) in the bubble.
final class CodeBackground: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        labelAlpha(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Reading the whole message (bubble)

/// The last assistant text in a transcript (JSONL): only the tail is read (~400 KB). Skips subagent entries
/// (`isSidechain`) and the ones with no text (tools only).
func lastAssistantText(_ path: String) -> String? {
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path),
          let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let end = fh.seekToEndOfFile()
    let n = min(end, 400_000)
    fh.seek(toFileOffset: end - n)
    let data = fh.readData(ofLength: Int(n))
    var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
    if end > n, !lines.isEmpty { lines.removeFirst() }      // the first line came out cut
    for l in lines.reversed() {
        guard let e = (try? JSONSerialization.jsonObject(with: Data(l))) as? [String: Any],
              e["type"] as? String == "assistant", e["isSidechain"] as? Bool != true,
              let msg = e["message"] as? [String: Any] else { continue }
        var text = ""
        if let s = msg["content"] as? String {
            text = s
        } else if let parts = msg["content"] as? [[String: Any]] {
            text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
    }
    return nil
}

/// Escapes what Markdown would take as formatting (to show exactly what you typed).
func escapeMarkdown(_ s: String) -> String {
    var r = ""
    for c in s {
        if "\\`*_[]<>".contains(c) { r.append("\\") }
        r.append(c)
    }
    return r
}

enum Block {
    case paragraph(String)           // consecutive lines, with inline formatting
    case heading(String)
    case item(String, String)        // marker ("•" or "1."), text
    case code(String)                // code or table: monospaced on a faint background
}

func isTableRow(_ l: String) -> Bool {
    l.hasPrefix("|") && l.hasSuffix("|") && l.count >= 3 && l.filter { $0 == "|" }.count >= 2
}

/// "- something", "* something" or "12. something" -> (marker, text).
func listItem(_ l: String) -> (String, String)? {
    if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") {
        return ("•", String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }
    let digits = l.prefix(while: { $0.isNumber })
    if !digits.isEmpty, digits.count <= 3 {
        let rest = l.dropFirst(digits.count)
        if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return (String(digits) + ".", String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
    }
    return nil
}

/// Light Markdown -> blocks. Split on blank lines and code fences; `#` headings, lists and table rows are
/// recognized per line.
func blocks(of text: String) -> [Block] {
    var res: [Block] = []
    var par: [String] = [], table: [String] = [], code: [String] = []
    var inCode = false
    func closePar() { if !par.isEmpty { res.append(.paragraph(par.joined(separator: "\n"))); par = [] } }
    func closeTable() { if !table.isEmpty { res.append(.code(table.joined(separator: "\n"))); table = [] } }
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if inCode {
            if line.hasPrefix("```") {
                res.append(.code(code.joined(separator: "\n")))
                code = []
                inCode = false
            } else {
                code.append(raw)
            }
            continue
        }
        if line.hasPrefix("```") { closePar(); closeTable(); inCode = true; continue }
        if line.isEmpty { closePar(); closeTable(); continue }
        if isTableRow(line) { closePar(); table.append(line); continue }
        closeTable()
        let hashes = line.prefix(while: { $0 == "#" })
        if (1...6).contains(hashes.count), line.dropFirst(hashes.count).hasPrefix(" ") {
            closePar()
            res.append(.heading(String(line.dropFirst(hashes.count)).trimmingCharacters(in: .whitespaces)))
            continue
        }
        if let (marker, rest) = listItem(line) {
            closePar()
            res.append(.item(marker, rest))
            continue
        }
        // An indented line right after an item continues that item
        if par.isEmpty, raw.hasPrefix(" "), case .item(let m, let t)? = res.last {
            res[res.count - 1] = .item(m, t + " " + line)
            continue
        }
        par.append(line)
    }
    if inCode { res.append(.code(code.joined(separator: "\n"))) }
    closePar()
    closeTable()
    return res
}

/// `**bold**`, `*italic*` and `` `code` `` of ONE line (line breaks are kept). Links are only painted.
func inlineFormat(_ line: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
    let plain = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                              .foregroundColor: color])
    guard #available(macOS 12, *) else { return plain }
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    guard let a = try? AttributedString(markdown: line, options: options) else { return plain }
    let out = NSMutableAttributedString()
    for run in a.runs {
        let piece = String(a[run.range].characters)
        let i = run.inlinePresentationIntent ?? []
        var font: NSFont
        var attributes: [NSAttributedString.Key: Any] = [:]
        if i.contains(.code) {
            font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
            attributes[.backgroundColor] = labelAlpha(0.07)
        } else {
            font = NSFont.systemFont(ofSize: size, weight: i.contains(.stronglyEmphasized) ? .semibold : weight)
            if i.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        }
        attributes[.font] = font
        attributes[.foregroundColor] = run.link != nil ? Tone.question.ink.text : color
        out.append(NSAttributedString(string: piece, attributes: attributes))
    }
    return out.length > 0 ? out : plain
}

/// Several lines, each with its inline formatting, with the given paragraph style.
func markdownText(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                  style: NSParagraphStyle) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let lines = s.components(separatedBy: "\n")
    for (n, l) in lines.enumerated() {
        out.append(inlineFormat(l, size: size, weight: weight, color: color))
        if n < lines.count - 1 { out.append(NSAttributedString(string: "\n")) }
    }
    out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
    return out
}

/// The bubble's content: a rounded background with a thin border and, inside (scrolling if it does not fit), the header and the text.
final class BubbleBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        shape.fill()
        shape.lineWidth = 1
        NSColor.separatorColor.setStroke()
        shape.stroke()
    }
}

/// The bubble's document: transparent, with the origin at the top left.
final class BubbleDocument: NSView {
    override var isFlipped: Bool { true }
}

/// The bubble's window: it does not activate and is not key or main, so it does not take the focus from the popover.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Builds the bubble: header (optional 28 pt picture, state word and name) and the whole message.
/// Its height is the content's, capped at `cap` with a scroll inside.
func buildBubble(word: String, ink: Ink, name: String, picture: NSImage?, text: String,
                 width: CGFloat, cap: CGFloat) -> BubbleBackground {
    let PAD: CGFloat = 14
    let inner = width - 2 * PAD
    let doc = BubbleDocument(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    var y = PAD

    // Header
    var x = PAD
    var headerHeight: CGFloat = 0
    if let img = picture {
        let pv = PictureView(img, side: 28)
        pv.frame.origin = NSPoint(x: PAD, y: y)
        doc.addSubview(pv)
        x += 28 + 8
        headerHeight = 28
    }
    let tWord = TextBlock(attr(word, 11.5, .semibold, ink.text), width: 140)
    let tName = TextBlock(attr(name, 14, .semibold, .labelColor), width: max(40, width - PAD - x - tWord.textSize.width - 8))
    headerHeight = max(headerHeight, tName.textSize.height, tWord.textSize.height)
    tWord.frame.origin = NSPoint(x: x, y: y + ((headerHeight - tWord.textSize.height) / 2).rounded())
    tName.frame.origin = NSPoint(x: x + tWord.textSize.width + 8, y: y + ((headerHeight - tName.textSize.height) / 2).rounded())
    doc.addSubview(tWord)
    doc.addSubview(tName)
    y += headerHeight + 10

    // Body
    let normal = NSMutableParagraphStyle()
    normal.lineSpacing = 4
    let indented = NSMutableParagraphStyle()
    indented.lineSpacing = 4
    indented.headIndent = 16
    indented.tabStops = [NSTextTab(textAlignment: .left, location: 16, options: [:])]
    var previousItem = false
    for b in blocks(of: text) {
        switch b {
        case .paragraph(let t):
            let v = TextBlock(markdownText(t, size: 13.5, color: .labelColor, style: normal), width: inner, lines: 0)
            v.frame.origin = NSPoint(x: PAD, y: y)
            doc.addSubview(v)
            y += v.textSize.height + 8
            previousItem = false
        case .heading(let t):
            let v = TextBlock(markdownText(t, size: 14, weight: .semibold, color: .labelColor, style: normal),
                              width: inner, lines: 0)
            v.frame.origin = NSPoint(x: PAD, y: y)
            doc.addSubview(v)
            y += v.textSize.height + 6
            previousItem = false
        case .item(let marker, let t):
            if previousItem { y -= 4 }      // consecutive items sit closer together
            let s = NSMutableAttributedString(attributedString: markdownText(t, size: 13.5, color: .labelColor, style: indented))
            s.insert(NSAttributedString(string: marker + "\t", attributes: [.font: NSFont.systemFont(ofSize: 13.5),
                                                                            .foregroundColor: NSColor.secondaryLabelColor,
                                                                            .paragraphStyle: indented]), at: 0)
            let v = TextBlock(s, width: inner, lines: 0)
            v.frame.origin = NSPoint(x: PAD, y: y)
            doc.addSubview(v)
            y += v.textSize.height + 8
            previousItem = true
        case .code(let t):
            let mono = NSMutableParagraphStyle()
            mono.lineSpacing = 2
            let s = NSAttributedString(string: t, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                               .foregroundColor: NSColor.labelColor,
                                                               .paragraphStyle: mono])
            let v = TextBlock(s, width: inner - 16, lines: 0)
            let bg = CodeBackground(frame: NSRect(x: PAD, y: y, width: inner, height: v.textSize.height + 16))
            v.frame.origin = NSPoint(x: 8, y: 8)
            bg.addSubview(v)
            doc.addSubview(bg)
            y += bg.frame.height + 8
            previousItem = false
        }
    }
    y = y - 8 + PAD
    doc.frame = NSRect(x: 0, y: 0, width: width, height: ceil(y))

    let height = min(doc.frame.height, cap)
    let background = BubbleBackground(frame: NSRect(x: 0, y: 0, width: width, height: height))
    if doc.frame.height <= cap {
        background.addSubview(doc)
    } else {
        // 1 pt less above and below: scrolling text must not cover the bubble's thin border
        let scroll = NSScrollView(frame: background.bounds.insetBy(dx: 0, dy: 1))
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        scroll.documentView = doc
        doc.frame.size.width = scroll.contentSize.width
        background.addSubview(scroll)
    }
    return background
}

/// Lays views out in rows from left to right, moving to the next row when they do not fit.
/// Returns the total height used.
@discardableResult
func flow(_ views: [NSView], in parent: NSView, x0: CGFloat, y0: CGFloat, width: CGFloat,
          gapX: CGFloat, gapY: CGFloat) -> CGFloat {
    var rows: [[NSView]] = [[]]
    var x: CGFloat = 0
    for v in views {
        let w = v.frame.width
        if x > 0 && x + w > width {
            rows.append([])
            x = 0
        }
        rows[rows.count - 1].append(v)
        x += w + gapX
    }
    var y = y0
    for r in rows where !r.isEmpty {
        let h = r.map { $0.frame.height }.max() ?? 0
        var cx = x0
        for v in r {
            v.frame.origin = NSPoint(x: cx, y: y + ((h - v.frame.height) / 2).rounded())
            parent.addSubview(v)
            cx += v.frame.width + gapX
        }
        y += h + gapY
    }
    return y - y0 - gapY
}

// MARK: - Reminder popups

/// Quiet hours from config.json (same rule as notify.py): no sound inside them.
func inQuietHours(_ cfg: [String: Any], _ now: Date) -> Bool {
    guard let q = cfg["quiet_hours"] as? [String: Any], (q["enabled"] as? Bool) == true else { return false }
    func minutes(_ v: Any?, _ fallback: Int) -> Int {
        guard let s = v as? String else { return fallback }
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return fallback }
        return (h % 24) * 60 + min(m, 59)
    }
    let start = minutes(q["from"], 22 * 60), end = minutes(q["to"], 7 * 60)
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let cur = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    if start == end { return false }
    return start < end ? (start <= cur && cur < end) : (cur >= start || cur < end)
}

/// Shows a session again with the usual popup, the way hooks/notify.py does: a JSON in state/queue/ and
/// `open -n -g CCNotify.app --args <json>`; without the popup app, a plain macOS notification. Honors
/// popup.enabled, events.<kind>, popup.private and the quiet hours of config.json.
func showReminderPopup(_ s: Session, _ L: Strings) {
    let cfg = configObject()
    let kind = s.state == "needs" ? (s.kind == "permission" ? "permission" : "question") : "done"
    if let ev = cfg["events"] as? [String: Any], let on = ev[kind] as? Bool, !on { return }
    let popupCfg = cfg["popup"] as? [String: Any] ?? [:]
    if let on = popupCfg["enabled"] as? Bool, !on { return }
    let isPrivate = (popupCfg["private"] as? Bool) ?? false
    let now = Date().timeIntervalSince1970

    var text = kind == "done" ? (s.doneText.isEmpty ? s.summary : s.doneText) : s.summary
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = kind == "done" ? L.doneFallback : L.needsFallback }
    if isPrivate { text = "" }

    // Sound: the defaults of notify.py, overridden by config.json "sounds"
    let defaults: [String: (String, Double, Bool)] = ["done": ("Glass", 0.5, true), "permission": ("Submarine", 0.8, false),
                                                       "question": ("Ping", 0.8, false)]
    var (sound, volume, away) = defaults[kind] ?? ("", 0.5, false)
    if let spec = (cfg["sounds"] as? [String: Any])?[kind] as? [String: Any] {
        if let v = spec["sound"] as? String { sound = v }
        if let v = number(spec["volume"]) { volume = min(1, max(0, v)) }
        if let v = spec["only_when_away"] as? Bool { away = v }
    }
    if inQuietHours(cfg, Date()) { sound = "" }

    var focus: [String: Any] = ["host": s.focus.host, "cwd": s.focus.cwd]
    if let pid = s.focus.pid { focus["pid"] = pid }
    if !s.focus.job.isEmpty { focus["job"] = s.focus.job }
    let size = ((try? FileManager.default.attributesOfItem(atPath: s.transcript))?[.size] as? NSNumber)?.intValue ?? 0
    var popup: [String: Any] = [
        "title": s.project, "kind": kind, "text": text, "id": String(s.id.prefix(12)), "session": s.id,
        "host": s.focus.host, "focus": focus, "transcript": s.transcript, "transcript_size": size, "event_at": now,
        "language": L.code, "sound": sound, "volume": volume, "only_when_away": away]
    for key in ["seconds", "width", "max_height_ratio", "max_stacked", "sticky_needs_you", "font_size", "private", "style",
                "compact_lines"] {
        if let v = popupCfg[key] { popup[key] = v }      // the popup has its own defaults for what is not set
    }
    guard let json = try? JSONSerialization.data(withJSONObject: popup) else { return }

    if FileManager.default.fileExists(atPath: popupApp) {
        ensureDir(queueDir)
        let queued = queueDir + "/" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".json"
        if writePrivate(json, to: queued) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", "-g", popupApp, "--args", queued]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                p.waitUntilExit()
                if p.terminationStatus == 0 { return }
            }
            try? FileManager.default.removeItem(atPath: queued)
        }
    } else if env["CCNOTIFY_TEST_REMIND"] != nil {
        ensureDir(queueDir)       // tests only: leave the JSON where it can be looked at
        writePrivate(json, to: queueDir + "/test-reminder-" + safeName(s.id) + ".json")
        return
    }
    // No popup app (or it failed): a plain notification, with the text through argv, never the script
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv", "-e",
                   "display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)",
                   "-e", "end run", s.project, L.popupLabel(kind), isPrivate ? L.popupLabel(kind) : shorten(text, 230)]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

// MARK: - The app

final class MenuBar: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var item: NSStatusItem?                    // does not exist in the headless test hooks
    var L = Strings()
    var opts = PanelOptions.load()
    var isPrivate = false                      // popup.private: no message text anywhere, so no bubble
    var sessions: [Session] = []
    var readUpTo: [String: UInt64] = [:]       // per session: how far its transcript has been read
    var overrides: [String: Override] = [:]
    var timer: Timer?
    let popover = NSPopover()
    let container = BackdropView(frame: NSRect(x: 0, y: 0, width: 380, height: 100))
    var lastSignature: String?                 // what the panel shows now: it is only rebuilt if this changes
    var reminded: [String: Double] = [:]       // session id -> when it will remind me (active reminders only)
    var remindingId: String?                   // the row that has "Remind me in" open
    var pinned: Set<String> = []               // safeName of the pinned sessions
    enum Page { case list, options }
    var page = Page.list                       // what the panel shows: the sessions or the options page
    var pagePainted: Page?                     // the page of the last build (the scroll does not pass from one to the other)
    var listScroll: CGFloat?                   // where the list was scrolled to when the options page opened
    var showAllFamilies = false                // options page: every family of emoji, not just the first three
    var pickingId: String?                     // the row that has the emoji picker open
    var revealId: String?                      // after the next build, scroll to this row
    var cells: [EmojiCell] = []                // the pressable pictures that are seen now
    var pendingCells: [EmojiCell] = []
    var shownIcon: String?                     // the symbol the status item shows now
    // What is seen and the mouse. All the state lives here, by session id, never in the views: the panel is rebuilt
    // every time something changes and the views do not survive.
    var openRow: String?                       // the row opened by the mouse ("Remind me in" wins over it)
    var rows: [(id: String, view: RowBox)] = []        // the rows that are seen now
    var pendingRows: [(id: String, view: RowBox)] = [] // those of the last build (they become `rows` only if used)
    var signatureInProgress = ""
    var mouseTimer: Timer?
    var captureFixed = false                   // in captures the mouse does not count: nothing opens or closes by itself
    var hoverId: String?, hoverSince: Double = 0           // row under the mouse and since when
    var bubble: BubblePanel?
    var bubbleId: String?
    var restId: String?, restSince: Double = 0             // for the bubble: the mouse resting on a row
    var candidateId: String?, candidateSince: Double = 0   // with the bubble open: the row the mouse moved to
    var outsideSince: Double?                              // since when the mouse is in neither the row nor the bubble
    var suppressed: String?                                // row whose bubble was closed by a click: stays closed until the mouse leaves it

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless test hooks: they print and quit
        if env["CCNOTIFY_TEST_ORDER"] == "1" {
            sessions = readSessions()
            reminded = classifyReminders(Date().timeIntervalSince1970).active
            pinned = readPins(clean: false)
            for s in ordered() { print(s.id) }
            fflush(stdout)
            exit(0)
        }
        if env["CCNOTIFY_TEST_BAR"] == "1" {
            sessions = readSessions()
            reminded = classifyReminders(Date().timeIntervalSince1970).active
            let b = barState()
            print("\(b.number > 0 ? String(b.number) : "")\t\(b.tip)")
            fflush(stdout)
            exit(0)
        }
        if env["CCNOTIFY_TEST_USAGE"] == "1" {
            for r in usageRows(readUsage(), now: usageNow(), Strings()) {
                print("\(r.label)\t\(r.pct.map { String(Int($0.rounded())) } ?? "")\t\(r.pct.map(pctLevel) ?? "neutral")\t\(r.text)")
            }
            fflush(stdout)
            exit(0)
        }
        if env["CCNOTIFY_TEST_EMOJI"] == "1" {
            opts = PanelOptions.load()
            sessions = readSessions()
            assignEmoji()
            for s in sessions.sorted(by: { $0.id < $1.id }) {
                print("\(s.id)\t\(Emoji.keys[s.id] ?? "-")\t\(Emoji.manual.contains(s.id) ? "manual" : "auto")")
            }
            fflush(stdout)
            exit(0)
        }
        if let json = env["CCNOTIFY_TEST_OPTIONS"], !json.isEmpty {
            // Saves those keys through the same path as the options page, prints the file and quits
            guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                fputs("CCNOTIFY_TEST_OPTIONS is not a JSON object\n", stderr)
                exit(2)
            }
            let ok = PanelOptions.save(o)
            if let data = FileManager.default.contents(atPath: optionsFile) { print(String(decoding: data, as: UTF8.self)) }
            fflush(stdout)
            exit(ok ? 0 : 2)
        }
        if let spec = env["CCNOTIFY_TEST_CHOOSE"], let eq = spec.firstIndex(of: "=") {
            // "<session>=<family>/<name>.png" saves the emoji you chose by hand for that session; with the right side empty, removes it
            opts = PanelOptions.load()
            sessions = readSessions()
            let value = String(spec[spec.index(after: eq)...])
            exit(chooseEmoji(String(spec[..<eq]), value.isEmpty ? nil : value) ? 0 : 2)
        }
        if let id = env["CCNOTIFY_TEST_REMIND"], !id.isEmpty {
            // Reminders without icon or panel: sets one of "2 min" the way the button does, lets the usual clock run, quits at 12 s
            sessions = readSessions()
            if let s = sessions.first(where: { $0.id == id }) { setReminder(s, minutes: 2) }
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
            return
        }
        let capturing = env["CCNOTIFY_CAPTURE_MENU"] != nil
        if capturing {     // tests only: fix the appearance and the state before anything is drawn
            captureFixed = true
            if let id = env["CCNOTIFY_CAPTURE_OPEN"], !id.isEmpty { openRow = id }
            if let id = env["CCNOTIFY_CAPTURE_REMIND"], !id.isEmpty { remindingId = id; openRow = id }
            if let id = env["CCNOTIFY_CAPTURE_PICKER"], !id.isEmpty { pickingId = id; openRow = id }
            if env["CCNOTIFY_CAPTURE_OPTIONS"] == "1" { page = .options }
            if env["CCNOTIFY_CAPTURE_ALL_FAMILIES"] == "1" { showAllFamilies = true }
            if let theme = env["CCNOTIFY_THEME"], theme == "dark" || theme == "light" {
                let ap = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                NSApp.appearance = ap
                popover.appearance = ap       // the popover takes the menu bar's appearance, not the app's
                container.appearance = ap
            }
        }
        let button = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = button
        button.button?.target = self
        button.button?.action = #selector(togglePanel)
        button.button?.imagePosition = .imageLeft
        // Transient: a click anywhere else closes it. Not in the test hooks, where a stray click or a change of the
        // active app (somebody using the Mac while a capture runs) would close the panel before the grab.
        popover.behavior = capturing || env["CCNOTIFY_TEST_MOUSE"] != nil || env["CCNOTIFY_TEST_NAV"] != nil
            ? .applicationDefined : .transient
        let vc = NSViewController()
        vc.view = container
        popover.contentViewController = vc
        popover.delegate = self
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)   // keep updating while the panel is open
        if env["CCNOTIFY_OPEN_MENU"] != nil {        // tests only
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.item?.button?.performClick(nil) }
        }
        if let out = env["CCNOTIFY_CAPTURE_MENU"] { captureMenu(to: out) }   // tests only
        if let id = env["CCNOTIFY_TEST_NAV"], !id.isEmpty {                  // tests only
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.item?.button?.performClick(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.navTest(id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(3) }
        }
        if let id = env["CCNOTIFY_TEST_MOUSE"], !id.isEmpty {                // tests only
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.item?.button?.performClick(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.mouseTest(id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(3) }
        }
    }

    func refresh() {
        L = Strings()
        PanelStyle.mono = configStyle() == "mono"
        isPrivate = configPrivate()
        opts = PanelOptions.load()
        sessions = readSessions()
        watchTranscripts()
        processReminders()
        pinned = readPins(clean: true)
        assignEmoji()
        paintItem()
        if popover.isShown { rebuildPanel(force: false) }
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
                            state: (o["state"] as? String) ?? "wrote", kind: (o["kind"] as? String) ?? "",
                            seen: ((o["seen"] as? Bool) ?? false) || (since > 0 && seenMarker(id) >= since),
                            since: since, summary: (o["summary"] as? String) ?? "",
                            doneText: (o["done_text"] as? String) ?? "",
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

    // MARK: Pins

    /// The pinned sessions: an empty file per session in state/menubar/pins/. The ones of sessions that are gone are
    /// removed, but only when the session's file is really not there (not because a stray read did not see it:
    /// other programs rewrite those files).
    func readPins(clean: Bool) -> Set<String> {
        let fm = FileManager.default
        var set = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: pinsDir)) ?? [] where !name.hasPrefix(".") {
            let has = sessions.contains { safeName($0.id) == name }
            if !has && !fm.fileExists(atPath: sessionsDir + "/" + name + ".json") {
                if clean { try? fm.removeItem(atPath: pinsDir + "/" + name) }
                continue
            }
            set.insert(name)
        }
        return set
    }

    func isPinned(_ s: Session) -> Bool { pinned.contains(safeName(s.id)) }

    func togglePin(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        let fm = FileManager.default
        let path = pinsDir + "/" + safeName(s.id)
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        } else {
            ensureDir(appStateDir)
            ensureDir(pinsDir)
            fm.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        pinned = readPins(clean: false)
        rebuildPanel(force: true)
    }

    // MARK: Order of the list

    /// 2 needs you · 3 finished unread · 4 reminder pending · 5 working · 6 read
    func group(_ s: Session) -> Int {
        if reminded[s.id] != nil { return 4 }
        if s.state == "needs" { return 2 }
        if s.state == "wrote" && !s.seen { return 3 }
        if s.state == "thinking" { return 5 }
        return 6
    }

    /// All the sessions, most to least relevant: first the pinned ones (among them, in the order below), then
    /// needs you (the oldest first), finished unread (the newest first), reminder pending (the one that fires first
    /// first), working (the oldest first) and read (the newest first).
    func ordered() -> [Session] {
        sessions.sorted { a, b in
            let pa = isPinned(a), pb = isPinned(b)
            if pa != pb { return pa }
            let ga = group(a), gb = group(b)
            if ga != gb { return ga < gb }
            switch ga {
            case 2, 5: if a.since != b.since { return a.since < b.since }
            case 4:
                let ca = reminded[a.id] ?? 0, cb = reminded[b.id] ?? 0
                if ca != cb { return ca < cb }
            default: if a.since != b.since { return a.since > b.since }
            }
            return a.id < b.id
        }
    }

    func tone(_ s: Session) -> Tone {
        if reminded[s.id] != nil { return .reminded }
        if s.state == "wrote" { return s.seen ? .read : .finished }
        if s.state == "thinking" { return .working }
        switch s.kind {
        case "permission": return .permission
        case "question": return .question
        default: return .needs
        }
    }

    /// The state word of a box ("In 5 min" for a reminded one).
    func word(_ s: Session) -> String {
        let t = tone(s)
        switch t {
        case .permission: return L.permission
        case .question: return L.question
        case .needs: return L.needsYou
        case .finished: return L.finished
        case .reminded: return L.reminderIn((reminded[s.id] ?? 0) - Date().timeIntervalSince1970)
        case .working: return L.working
        case .read: return L.read
        }
    }

    // MARK: Reminders

    func readReminders() -> [Reminder] {
        let fm = FileManager.default
        var list: [Reminder] = []
        for name in (try? fm.contentsOfDirectory(atPath: remindersDir)) ?? [] where name.hasSuffix(".json") {
            let path = remindersDir + "/" + name
            guard let data = fm.contents(atPath: path),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let at = number(o["at"]), let since = number(o["since"]) else {
                try? fm.removeItem(atPath: path)       // unreadable: no use for it
                continue
            }
            list.append(Reminder(key: String(name.dropLast(5)), path: path, at: at, since: since))
        }
        return list
    }

    /// A session "waits for you" if it needs something from you or finished and you did not read it.
    func isWaiting(_ s: Session) -> Bool { s.state == "needs" || (s.state == "wrote" && !s.seen) }

    /// Splits the reminders into active (not yet due), due (time to show it) and obsolete (the session changed state
    /// or went away). Changes nothing on disk.
    func classifyReminders(_ now: Double) -> (active: [String: Double], due: [(Reminder, Session)], obsolete: [Reminder]) {
        var active: [String: Double] = [:], due: [(Reminder, Session)] = [], obsolete: [Reminder] = []
        for r in readReminders() {
            guard let s = sessions.first(where: { safeName($0.id) == r.key }) else {
                // No session: it is only obsolete if its file is really gone (one being rewritten that could not be
                // read at this instant must not be dropped).
                if !FileManager.default.fileExists(atPath: sessionsDir + "/" + r.key + ".json") { obsolete.append(r) }
                continue
            }
            if !isWaiting(s) || abs(s.since - r.since) >= 0.001 {
                obsolete.append(r)
            } else if now >= r.at {
                due.append((r, s))
            } else {
                active[s.id] = r.at
            }
        }
        return (active, due, obsolete)
    }

    /// Drops the reminders that no longer apply and shows again the ones whose time came.
    func processReminders() {
        let (active, due, obsolete) = classifyReminders(Date().timeIntervalSince1970)
        for r in obsolete { try? FileManager.default.removeItem(atPath: r.path) }
        for (r, s) in due {
            try? FileManager.default.removeItem(atPath: r.path)   // first remove it: so it never shows twice
            showReminderPopup(s, L)
        }
        reminded = active
    }

    /// Creates the reminder of a session (in `minutes`).
    func setReminder(_ s: Session, minutes: Int) {
        ensureDir(appStateDir)
        ensureDir(remindersDir)
        let o: [String: Any] = ["at": Date().timeIntervalSince1970 + Double(minutes) * secondsPerMinute, "since": s.since]
        if let data = try? JSONSerialization.data(withJSONObject: o) {
            writePrivate(data, to: remindersDir + "/" + safeName(s.id) + ".json")
        }
    }

    // MARK: Menu bar item

    // A session with an active reminder does not count: neither in the bar nor in the panel header.
    var needing: [Session] { sessions.filter { $0.state == "needs" && reminded[$0.id] == nil }.sorted { $0.since < $1.since } }
    var unread: [Session] { sessions.filter { $0.state == "wrote" && !$0.seen && reminded[$0.id] == nil }.sorted { $0.since > $1.since } }
    var working: [Session] { sessions.filter { $0.state == "thinking" }.sorted { $0.since < $1.since } }

    /// What the item shows: how many sessions are waiting for you (they need you or finished unread; a reminder
    /// pending does not count) and the tooltip.
    func barState() -> (number: Int, tip: String) {
        let n = needing.count + unread.count
        return (n, Strings().barTip(waiting: n, working: working.count))
    }

    /// The item: just the symbol (a template: the menu bar paints it in its own color, light or dark) and, if sessions
    /// wait for you, ONE number next to it, also in the bar's color (no tint: orange and green looked odd and
    /// misaligned). The baseline is not shifted: with +1 pt it looked like a superscript. Between the
    /// icon and the number sits the gap the status bar button itself puts (~5 pt; a negative kern does not shrink it).
    func paintItem() {
        guard let button = item?.button else { return }
        let b = barState()
        let symbol = resolvedBarIcon(opts.icon)
        if button.image == nil || shownIcon != symbol {
            button.image = barImage(symbol, label: L.title)
            button.imagePosition = .imageLeft
            shownIcon = symbol
        }
        if b.number > 0 {
            button.attributedTitle = NSAttributedString(string: "\(b.number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .baselineOffset: 0])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = "\(L.title): \(b.tip)"
        button.setAccessibilityLabel("\(L.title): \(b.tip)")
    }

    /// Where the icon sits inside the button, in the button's coordinates. The button centers its content (icon + gap
    /// + number), so the icon starts where half of the spare width is. (The cell's imageRect(forBounds:) does not
    /// help here: it gives the icon stuck to the left.)
    func iconRect(of button: NSStatusBarButton) -> NSRect {
        var rect = button.bounds
        if let img = button.image, button.attributedTitle.length > 0 {
            let iconW = img.size.width
            let numberW = ceil(button.attributedTitle.size().width)
            let x0 = max(0, (button.bounds.width - (iconW + iconNumberGap + numberW)) / 2)
            if iconW > 1, x0 + iconW <= button.bounds.width {
                rect = NSRect(x: x0, y: 0, width: iconW, height: button.bounds.height)
            }
        }
        return rect
    }

    // MARK: Panel

    /// Opens or closes the panel when the status item is clicked.
    @objc func togglePanel(_ sender: Any?) {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        refresh()
        rebuildPanel(force: true)
        NSApp.activate(ignoringOtherApps: true)
        // The panel's arrow comes out from under the ICON, not the button's center: with the number beside it, the
        // button's center falls between icon and number and the icon looked shifted from the arrow.
        popover.show(relativeTo: iconRect(of: button), of: button, preferredEdge: .minY)
        startMouse()
    }

    func popoverDidClose(_ notification: Notification) {
        lastSignature = nil
        container.subviews.forEach { $0.removeFromSuperview() }   // when it opens again, the scroll starts at the top
        rows = []
        remindingId = nil      // the next time you open the panel, the rows go back to their own state
        pickingId = nil
        openRow = nil
        cells = []
        page = .list           // and it opens on the list, not on the options
        pagePainted = nil
        listScroll = nil
        stopMouse()
    }

    /// Draws the panel again with what is on disk. If nothing that is seen changed, it is left as it is (so a half
    /// click, or the cursor over a button, are not lost to the periodic refresh). What is open and what is pinned
    /// count in the signature: changing them does rebuild the panel.
    func rebuildPanel(force: Bool) {
        let (view, signature) = buildPanel(opaque: false)
        if !force && signature == lastSignature { return }
        lastSignature = signature
        rows = pendingRows
        cells = pendingCells
        // If it already scrolled, remember where, so each refresh does not go back to the top. The scroll of a page does
        // not pass to the other: coming back from the options, the list is where it was; opening the emoji picker
        // brings its row into view.
        var previous = pagePainted == page ? (container.subviews.first as? NSScrollView)?.contentView.bounds.origin.y : nil
        if previous == nil && page == .list, let saved = listScroll { previous = saved }
        pagePainted = page
        if page == .list { listScroll = nil }
        if let id = revealId {
            revealId = nil
            if let r = rows.first(where: { $0.id == id })?.view { previous = max(0, r.frame.minY - 8) }
        }
        var content: NSView = view
        let screen = item?.button?.window?.screen ?? NSScreen.main
        let cap = ((screen?.visibleFrame.height) ?? 800) - 40
        if view.frame.height > cap {
            // Scrolling, with an overlay bar (not the always-visible one, which takes ~15 pt of width from the content
            // and leaves the 380 pt document wider than the visible view), no horizontal scroll.
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: view.frame.width, height: cap))
            scroll.scrollerStyle = .overlay
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.horizontalScrollElasticity = .none
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.documentView = view
            view.frame.size.width = scroll.contentSize.width      // the document is as wide as the visible view
            let maximum = max(0, view.frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, previous ?? 0), maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
            content = scroll
        }
        let size = content.frame.size
        container.subviews.forEach { $0.removeFromSuperview() }
        // The popover places `container` inside its window, which has ~13 pt of invisible margin. Here only its size
        // is changed and only with the panel closed: moving it to (0, 0) with the panel open shifted all the content
        // 13 pt left and down (it showed when the size did not change).
        if !popover.isShown { container.setFrameSize(size) }
        content.frame = NSRect(origin: .zero, size: size)
        container.addSubview(content)
        // Only if it changed: setting the same size again on an open popover that is almost as tall as the screen made
        // it close.
        if popover.contentSize != size { popover.contentSize = size }
        adjustBubble()
    }

    /// The open row: the one with the emoji picker or "Remind me in" if there is one; otherwise the one the mouse opened.
    func isOpen(_ id: String) -> Bool { (pickingId ?? remindingId ?? openRow) == id }

    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor,
              width: CGFloat, lines: Int = 1) -> TextBlock {
        signatureInProgress += s + "\u{1}"
        return TextBlock(attr(s, size, weight, color), width: width, lines: lines)
    }

    /// A button: pressing it hides the bubble, and its title counts in the signature.
    func button(_ s: String, _ style: ButtonStyle, _ ink: Ink, size: CGFloat = 12.5,
                _ action: @escaping () -> Void) -> PanelButton {
        signatureInProgress += "[" + s + "]"
        return PanelButton(s, style: style, ink: ink, size: size) { [unowned self] in
            self.hideBubble(byClick: true)
            action()
        }
    }

    /// Builds the whole panel. Also returns a "signature" of everything it shows, to know if it changed.
    func buildPanel(opaque: Bool) -> (NSView, String) {
        if page == .options { return buildOptions(opaque: opaque) }
        let WIDTH: CGFloat = 380, PAD: CGFloat = 14, GAP: CGFloat = 10
        let inner = WIDTH - 2 * PAD
        let panel = PanelView(solid: opaque)
        signatureInProgress = "L\(L.code)\(PanelStyle.mono ? "m" : "")\(opts.context ? "c" : "")\(opts.usage ? "u" : "")"
        pendingRows = []
        pendingCells = []
        // The emoji picker only exists while its session is open and has a picture
        if let e = pickingId, sessionImage(for: e) == nil || !sessions.contains(where: { $0.id == e }) { pickingId = nil }
        var y = PAD

        let list = ordered()
        // Header: "Sessions" on the left and, on the right in gray, the breakdown of what waits for you
        // (reminded ones do not count).
        let breakdown = L.breakdown(needs: needing.count, unread: unread.count, working: working.count)
        let title = text(L.panelTitle, 15, .semibold, .labelColor, width: inner)
        title.frame.origin = NSPoint(x: PAD, y: y)
        panel.addSubview(title)
        let summary = text(breakdown.isEmpty ? (list.isEmpty ? "" : L.allCaughtUp) : breakdown,
                           12, .regular, .secondaryLabelColor, width: inner - title.textSize.width - 12)
        summary.frame.origin = NSPoint(x: PAD + inner - summary.textSize.width,
                                       y: y + (title.textSize.height - summary.textSize.height) / 2 + 1)
        panel.addSubview(summary)
        y += title.textSize.height + 12

        // The list: one box per open session, no headings or rules
        if list.isEmpty {
            let none = text(L.noSessions, 13, .regular, .secondaryLabelColor, width: inner)
            none.frame.origin = NSPoint(x: PAD, y: y)
            panel.addSubview(none)
            y += none.textSize.height + GAP
        } else {
            let hasImages = list.contains { sessionImage(for: $0.id) != nil }
            let hasPin = list.contains { isPinned($0) }
            for s in list {
                let box = makeRow(s, width: inner, hasImages: hasImages, hasPin: hasPin)
                box.frame.origin = NSPoint(x: PAD, y: y)
                panel.addSubview(box)
                pendingRows.append((s.id, box))
                y += box.frame.height + 6
            }
            y += GAP - 6
        }

        // Account limits (if there is data): rule, heading and up to two rows with their bar
        let now = usageNow()
        let usage = opts.usage ? usageRows(readUsage(), now: now, L) : []
        if !usage.isEmpty {
            y += 2                                    // 12 pt between the last box and the rule
            panel.addSubview(Separator(frame: NSRect(x: PAD, y: y, width: inner, height: 1)))
            y += 1 + 10
            let heading = text(L.limits, 11.5, .semibold, .secondaryLabelColor, width: inner)
            heading.frame.origin = NSPoint(x: PAD, y: y)
            panel.addSubview(heading)
            y += heading.textSize.height + 6
            // Columns of a row: label 56 · bar 96 · percentage (right) 40 · reset (right, up to the edge)
            let xBar: CGFloat = 56, xPct = xBar + UsageBar.width + 4, widthPct: CGFloat = 40
            let xReset = xPct + widthPct + 4, widthReset = inner - xReset     // ~152 pt for the reset
            // The fullest text that fits in ALL the rows (so both read the same): "resets 3:30 PM", else a shorter
            // verb, else just "3:30 PM" (the full form always goes in the tooltip)
            let resetAttr = { (t: String) in attr(t, 12, .regular, .secondaryLabelColor) }
            func fitsAll(_ q: (UsageRow) -> String) -> Bool { usage.allSatisfy { ceil(resetAttr(q($0)).size().width) <= widthReset - 8 } }   // 8 pt of air beside the %
            let level = fitsAll({ $0.text }) ? 0 : (fitsAll({ $0.mid }) ? 1 : 2)
            for r in usage {
                let reset = level == 0 ? r.text : (level == 1 ? r.mid : r.short)
                let e = r.pct.map { pctStyle($0, normal: labelAlpha(0.8)) }
                signatureInProgress += "<u|\(r.label)|\(r.pct.map { String(format: "%.1f", $0) } ?? "-")|\(reset)|\(r.tip)>"
                var description = r.label
                if let p = r.pct { description += ", " + pctText(p) }
                if !r.text.isEmpty { description += ", " + r.text }
                let row = UsageRowView(width: inner, description: description, tip: r.tip)
                let label = TextBlock(attr(r.label, 12.5, .regular, .secondaryLabelColor), width: xBar)
                label.frame.origin = NSPoint(x: 0, y: ((20 - label.textSize.height) / 2).rounded())
                row.addSubview(label)
                let bar = UsageBar(pct: r.pct)
                bar.frame.origin = NSPoint(x: xBar, y: 8)
                row.addSubview(bar)
                if let p = r.pct, let e = e {
                    let tp = TextBlock(attr(pctText(p), 12.5, e.weight, e.color, digits: true), width: widthPct)
                    tp.frame.origin = NSPoint(x: xPct + widthPct - tp.textSize.width, y: ((20 - tp.textSize.height) / 2).rounded())
                    row.addSubview(tp)
                }
                if !reset.isEmpty {
                    let tr = TextBlock(resetAttr(reset), width: widthReset)
                    tr.frame.origin = NSPoint(x: inner - tr.textSize.width, y: ((20 - tr.textSize.height) / 2).rounded())
                    row.addSubview(tr)
                }
                row.frame.origin = NSPoint(x: PAD, y: y)
                panel.addSubview(row)
                y += 20 + 4
            }
            y += GAP - 4
        }

        // Footer: always ONE rule between what is above (list or limits) and the footer, 10 pt above and 8 below
        panel.addSubview(Separator(frame: NSRect(x: PAD, y: y, width: inner, height: 1)))
        y += 1 + 8
        let footerHeight: CGFloat = 24
        if !unread.isEmpty {
            let all = button(L.markAllRead, .text, Tone.needs.ink) { [unowned self] in self.markAllRead() }
            all.frame.origin = NSPoint(x: PAD - 3, y: y)
            panel.addSubview(all)
        }
        let quit = button(L.quit, .text, Tone.needs.ink) { [unowned self] in self.quit() }
        quit.frame.origin = NSPoint(x: WIDTH - PAD + 3 - quit.frame.width, y: y)
        panel.addSubview(quit)
        if hasOptionsPage {
            // The gear of the options page, 12 pt to the left of "Quit"
            signatureInProgress += "[gear]"
            let gear = GearButton(label: L.options) { [unowned self] in
                self.hideBubble(byClick: true)
                self.openOptions()
            }
            gear.frame.origin = NSPoint(x: quit.frame.minX - 12 - gear.frame.width, y: y)
            panel.addSubview(gear)
        }
        y += footerHeight + PAD - 3

        panel.frame = NSRect(x: 0, y: 0, width: WIDTH, height: ceil(y))
        return (panel, signatureInProgress)
    }

    // MARK: Emoji of each session

    /// What you chose by hand (emoji-chosen.json): {"<safe session id>": "<family>/<name>.png"}. Anything unreadable is
    /// empty.
    func readChosenRaw() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: emojiChosenFile),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        return o
    }

    func writeChosen(_ map: [String: String]) {
        if map.isEmpty {
            try? FileManager.default.removeItem(atPath: emojiChosenFile)
        } else if let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) {
            ensureDir(appStateDir)
            writePrivate(data, to: emojiChosenFile)
        }
    }

    /// The choices by hand, clean: the one whose picture no longer exists is dropped (only if the app has pictures at
    /// all) and so is the one of a session that is gone, but only when its session file is really not there (the same
    /// rule as the pins: other programs rewrite those files and a stray read would not see it).
    func readChosen() -> [String: String] {
        let original = readChosenRaw()
        var map = original
        let fm = FileManager.default
        let open = Set(sessions.map { safeName($0.id) })
        for (safe, key) in original {
            let brokenPicture = !emojiFamilies.isEmpty && emojiPath(key) == nil
            let gone = !open.contains(safe) && !fm.fileExists(atPath: sessionsDir + "/" + safe + ".json")
            if brokenPicture || gone { map[safe] = nil }
        }
        if map != original { writeChosen(map) }
        return map
    }

    /// Saves (or, with `key` nil, removes) the emoji you chose for a session. False if it could not be saved.
    @discardableResult
    func chooseEmoji(_ id: String, _ key: String?) -> Bool {
        guard sessions.contains(where: { $0.id == id }) else { return false }
        var map = readChosen()
        if let k = key {
            guard emojiPath(k) != nil else { return false }
            map[safeName(id)] = k
        } else {
            map[safeName(id)] = nil
        }
        writeChosen(map)
        return true
    }

    /// Which emoji each open session shows, into `Emoji.keys` (session id -> "family/name.png") and `Emoji.manual`.
    /// What you chose by hand rules (from any family). Otherwise a session keeps the one it was given: it is stored in
    /// emoji-auto.json {"family": "<family>", "assigned": {"<safe session id>": "<name>.png"}}. A new session gets the
    /// file its id hashes to (FNV-1a) in the chosen family and, if another open session has it (by hand or not), the
    /// next free one; with none free, it repeats. Changing the family gives every open session a new one. With the emoji
    /// off (or a family with no pictures) nobody has one. Run once per refresh: the rest only reads `Emoji`.
    func assignEmoji() {
        Emoji.keys = [:]
        Emoji.manual = []
        let family = opts.emojiFamily
        guard family != emojiOff, let files = emojiFamilies.first(where: { $0.family == family })?.files else { return }
        let fm = FileManager.default
        let ids = sessions.map { (id: $0.id, safe: safeName($0.id)) }
        let open = Set(ids.map { $0.safe })
        let chosen = readChosen().filter { open.contains($0.key) }
        var storedFamily = "", assigned: [String: String] = [:]
        if let data = fm.contents(atPath: emojiAutoFile),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            storedFamily = (o["family"] as? String) ?? ""
            assigned = (o["assigned"] as? [String: String]) ?? [:]
        }
        let (originalFamily, originalAssigned) = (storedFamily, assigned)
        if storedFamily != family { assigned = [:] }            // another family: every session is given a new one
        for (safe, file) in assigned {
            if open.contains(safe) {
                if !files.contains(file) { assigned[safe] = nil }          // that picture is gone: another one
            } else if !fm.fileExists(atPath: sessionsDir + "/" + safe + ".json") {
                assigned[safe] = nil                                        // its session ended
            }
        }
        // What another session has by hand is not given to anybody; and a session with one by hand keeps no given one
        let byHand = Set(chosen.values)
        for safe in open {
            if chosen[safe] != nil { assigned[safe] = nil; continue }
            if let a = assigned[safe], byHand.contains(family + "/" + a) { assigned[safe] = nil }
        }
        var taken = byHand.union(open.compactMap { assigned[$0] }.map { family + "/" + $0 })
        for safe in open.sorted() where assigned[safe] == nil && chosen[safe] == nil {
            let start = Int(fnv1a(safe) % UInt32(files.count))
            var pick = files[start]
            for i in 0..<files.count {
                let f = files[(start + i) % files.count]
                if !taken.contains(family + "/" + f) { pick = f; break }
            }
            assigned[safe] = pick
            taken.insert(family + "/" + pick)
        }
        if family != originalFamily || assigned != originalAssigned,
           let data = try? JSONSerialization.data(withJSONObject: ["family": family, "assigned": assigned] as [String: Any],
                                                  options: [.sortedKeys, .prettyPrinted]) {
            ensureDir(appStateDir)
            writePrivate(data, to: emojiAutoFile)
        }
        for (id, safe) in ids {
            if let c = chosen[safe] { Emoji.keys[id] = c; Emoji.manual.insert(id) }
            else if let a = assigned[safe] { Emoji.keys[id] = family + "/" + a }
        }
    }

    // MARK: Emoji picker of a session

    /// The picker, inside the row and in place of its buttons: "Pick an emoji · [Automatic] Cancel" and, for each family,
    /// its name and its pictures (22 pt, 6 pt apart, in lines); the one the session has gets a ring. "Automatic" shows
    /// only if the session has one chosen by hand. Returns how far it reaches (without the bottom margin).
    func buildPicker(_ box: RowBox, id: String, width: CGFloat, pad: CGFloat, y0: CGFloat, ink: Ink) -> CGFloat {
        var y = y0
        let head = text(L.pickEmoji, 12, .regular, .secondaryLabelColor, width: 200)
        head.frame.origin = NSPoint(x: pad, y: y + ((24 - head.textSize.height) / 2).rounded())
        box.addSubview(head)
        let cancel = button(L.cancel, .text, ink) { [unowned self] in self.closePicker() }
        cancel.frame.origin = NSPoint(x: width - pad + 3 - cancel.frame.width, y: y)
        box.addSubview(cancel)
        if Emoji.manual.contains(id) {
            let auto = button(L.automatic, .text, ink) { [unowned self] in self.pickEmoji(id, nil) }
            auto.frame.origin = NSPoint(x: cancel.frame.minX - 6 - auto.frame.width, y: y)
            box.addSubview(auto)
        }
        y += 24 + 4
        let current = Emoji.keys[id]
        let step: CGFloat = 28                                         // 22 of picture + 6 apart
        let columns = max(1, Int((width - 2 * pad + 6) / step))        // 12 in the 332 pt inside
        for (family, files) in emojiFamilies {
            let heading = text(L.family(family), 10.5, .semibold, .secondaryLabelColor, width: width - 2 * pad)
            heading.frame.origin = NSPoint(x: pad, y: y)
            box.addSubview(heading)
            y += heading.textSize.height + 4
            var n = 0
            for f in files {
                let key = family + "/" + f
                guard let img = emojiImage(key) else { continue }
                let cell = EmojiCell(img, side: 22, ring: key == current,
                                     description: L.family(family) + ", " + emojiLabel(key), tip: nil) { [unowned self] in
                    self.pickEmoji(id, key)
                }
                cell.frame.origin = NSPoint(x: pad - EmojiCell.margin + CGFloat(n % columns) * step,
                                            y: y - EmojiCell.margin + CGFloat(n / columns) * step)
                box.addSubview(cell)
                pendingCells.append(cell)
                n += 1
            }
            y += CGFloat((n + columns - 1) / columns) * step - 6 + 10
        }
        return y - 10
    }

    /// Click on a row's emoji: the row stays open with the picker (and the bubble goes away).
    func openPicker(_ id: String) {
        hideBubble(byClick: true)
        remindingId = nil
        pickingId = id
        openRow = id
        revealId = id
        rebuildPanel(force: true)
    }

    func closePicker() {
        pickingId = nil
        rebuildPanel(force: true)
    }

    /// One emoji of the picker (or, with nil, "Automatic"): it is saved and the row goes back to its buttons.
    func pickEmoji(_ id: String, _ key: String?) {
        chooseEmoji(id, key)
        pickingId = nil
        assignEmoji()          // the ones given by themselves step aside from the one just chosen
        rebuildPanel(force: true)
    }

    // MARK: Options page

    /// Opens the options page in place of the list (the list's scroll is kept for the way back).
    func openOptions() {
        listScroll = (container.subviews.first as? NSScrollView)?.contentView.bounds.origin.y
        page = .options
        pickingId = nil
        remindingId = nil
        openRow = nil
        hoverId = nil
        rebuildPanel(force: true)
    }

    func closeOptions() {
        page = .list
        rebuildPanel(force: true)
    }

    /// Saves the change and applies it: the page, the rows and the status item.
    func applyOptions(_ changes: [String: Any]) {
        PanelOptions.save(changes)
        opts = PanelOptions.load()
        assignEmoji()
        paintItem()
        rebuildPanel(force: true)
    }

    /// The options page, in three grouped boxes: "Menu bar" (the icon, one line), "Emoji" (a switch and a row per family
    /// with its pictures) and "Panel" (three checkboxes).
    func buildOptions(opaque: Bool) -> (NSView, String) {
        let WIDTH: CGFloat = 380, PAD: CGFloat = 14
        let inner = WIDTH - 2 * PAD
        let panel = PanelView(solid: opaque)
        signatureInProgress = "OL\(L.code)\(PanelStyle.mono ? "m" : "")|\(opts.emojiFamily)|\(opts.bubble)|\(opts.usage)|\(opts.context)|\(opts.icon)|\(showAllFamilies)|"
        pendingRows = []
        pendingCells = []
        var y = PAD - 3     // a text button is 24 pt tall and its text sits 3 pt inside

        let back = button(L.back, .text, Tone.needs.ink, size: 13) { [unowned self] in self.closeOptions() }
        back.frame.origin = NSPoint(x: PAD - 3, y: y)
        panel.addSubview(back)
        y += back.frame.height + 2
        let title = text(L.options, 16, .semibold, .labelColor, width: inner)
        title.frame.origin = NSPoint(x: PAD, y: y)
        panel.addSubview(title)
        y += title.textSize.height + 16

        func label(_ t: String) {
            let r = text(t, 12, .semibold, .secondaryLabelColor, width: inner - 8)
            r.frame.origin = NSPoint(x: PAD + 4, y: y)
            panel.addSubview(r)
            y += r.textSize.height + 6
        }

        let INSIDE: CGFloat = 8              // margin inside a grouped box
        let boxWidth = inner
        let rowWidth = inner - 2 * INSIDE
        let BETWEEN: CGFloat = 17            // space between sections

        /// An empty grouped box at the current position (behind whatever is put over it); the height is set afterwards.
        func newBox() -> GroupBox {
            let b = GroupBox(frame: NSRect(x: PAD, y: y, width: boxWidth, height: 10))
            panel.addSubview(b)
            return b
        }

        // 1. Menu bar: the icons in one line of 28 pt buttons
        label(L.sectionMenuBar)
        let box1 = newBox()
        let current = resolvedBarIcon(opts.icon)
        var buttons: [NSView] = []
        for (symbol, name) in offeredBarIcons(current: current, L) {
            guard let img = barImage(symbol, label: name) else { continue }
            signatureInProgress += "<i:\(symbol)>"
            buttons.append(BarIconButton(name: name, symbol: img, chosen: symbol == current, side: 28) { [unowned self] in
                self.applyOptions(["icon": symbol])
            })
        }
        let box1Top = y
        y += 8
        let gap: CGFloat = buttons.count > 1
            ? min(8, max(5, floor((rowWidth - CGFloat(buttons.count) * 28) / CGFloat(buttons.count - 1)))) : 5
        y += flow(buttons, in: panel, x0: PAD + INSIDE, y0: y, width: rowWidth, gapX: gap, gapY: 5) - 5
        y += 8
        box1.frame.size.height = y - box1Top
        y += BETWEEN

        // 2. Emoji: a general switch and, if it is on, a row per family with its pictures
        label(L.sectionEmoji)
        let box2 = newBox()
        let box2Top = y
        let on = opts.emojiFamily != emojiOff
        signatureInProgress += "<emoji:\(on)>"
        let toggle = OptionRow(L.emojiForEach, on: on, width: boxWidth, height: 40, inset: 12, asSwitch: true) { [unowned self] in
            if on {
                self.applyOptions(["emoji_theme": emojiOff])
            } else {
                let first = emojiFamilies.contains { $0.family == defaultEmojiFamily } ? defaultEmojiFamily : (emojiFamilies.first?.family ?? emojiOff)
                self.applyOptions(["emoji_theme": first])
            }
        }
        toggle.frame.origin = NSPoint(x: PAD, y: y)
        panel.addSubview(toggle)
        y += 40
        if on {
            let rule = Separator(frame: NSRect(x: PAD + 12, y: y, width: boxWidth - 24, height: 1))
            rule.alpha = 0.10
            panel.addSubview(rule)
            y += 1 + INSIDE
            // The first three families (and the chosen one, wherever it is) are seen; the rest, with "Show N more"
            let visible = showAllFamilies ? emojiFamilies
                : emojiFamilies.enumerated().filter { $0.offset < 3 || $0.element.family == opts.emojiFamily }.map { $0.element }
            for (family, files) in visible {
                let pictures = files.compactMap { emojiImage(family + "/" + $0) }
                signatureInProgress += "<\(family)>"
                let row = FamilyRow(name: L.family(family), pictures: pictures, chosen: opts.emojiFamily == family, width: rowWidth) {
                    [unowned self] in self.applyOptions(["emoji_theme": family])
                }
                row.frame.origin = NSPoint(x: PAD + INSIDE, y: y)
                panel.addSubview(row)
                y += FamilyRow.height + 6
            }
            if emojiFamilies.count > visible.count || showAllFamilies {
                let hidden = emojiFamilies.count - visible.count
                let moreText = showAllFamilies ? L.showLess : L.showMore(hidden)
                signatureInProgress += "<more:\(moreText)>"
                let more = MoreRow(moreText, expanded: showAllFamilies, width: rowWidth) { [unowned self] in
                    self.showAllFamilies.toggle()
                    self.rebuildPanel(force: true)
                }
                more.frame.origin = NSPoint(x: PAD + INSIDE, y: y)
                panel.addSubview(more)
                y += FamilyRow.height + 6
            }
            y += -6 + INSIDE
        }
        box2.frame.size.height = y - box2Top
        y += 8
        let note = text(L.emojiNote, 11.5, .regular, .secondaryLabelColor, width: inner - 8, lines: 0)
        note.frame.origin = NSPoint(x: PAD + 4, y: y)
        panel.addSubview(note)
        y += note.textSize.height + BETWEEN

        // 3. Panel: three checkboxes, with a thin rule between rows
        label(L.sectionPanel)
        let box3 = newBox()
        let box3Top = y
        let checks: [(String, String, Bool)] = [("bubble", L.optBubble, opts.bubble), ("usage", L.optUsage, opts.usage),
                                                ("context", L.optContext, opts.context)]
        for (k, (key, caption, isOn)) in checks.enumerated() {
            signatureInProgress += "<\(key)>"
            if k > 0 {
                let rule = Separator(frame: NSRect(x: PAD + 12, y: y, width: boxWidth - 24, height: 1))
                rule.alpha = 0.10
                panel.addSubview(rule)
                y += 1
            }
            let row = OptionRow(caption, on: isOn, width: boxWidth, height: 38, inset: 12) { [unowned self] in
                self.applyOptions([key: !isOn])
            }
            row.frame.origin = NSPoint(x: PAD, y: y)
            panel.addSubview(row)
            y += row.frame.height
        }
        box3.frame.size.height = y - box3Top
        y += PAD

        panel.frame = NSRect(x: 0, y: 0, width: WIDTH, height: ceil(y))
        return (panel, signatureInProgress)
    }

    /// Lights up the pressable picture under the mouse (the ones in the rows and in the picker).
    func highlightCells(_ p: NSPoint) {
        guard let w = container.window else { return }
        let visible = w.convertToScreen(container.convert(container.bounds, to: nil))
        for c in cells {
            let inside = c.window === w && visible.contains(p) && w.convertToScreen(c.convert(c.bounds, to: nil)).contains(p)
            if c.hovered != inside { c.hovered = inside }
        }
    }

    /// A box of the list: [picture] state word · name · info on the right · [pin]; open, a row of buttons below.
    func makeRow(_ s: Session, width: CGFloat, hasImages: Bool, hasPin: Bool) -> RowBox {
        let tone = self.tone(s)
        let ink = tone.ink
        let id = s.id
        let pad: CGFloat = 10, gap: CGFloat = 8
        let line = RowBox.lineHeight
        let pinnedRow = isPinned(s)
        let stateWord = word(s)
        let picture = sessionImage(for: id)
        let open = isOpen(id)

        // What is on the right: "2 agents · ctx 62 % · 20 min"
        let info = NSMutableAttributedString()
        if s.state == "thinking" && s.tasks > 0 {
            info.append(attr(L.agents(s.tasks) + " · ", 12, .regular, .secondaryLabelColor, digits: true))
        }
        info.append(withContext(opts.context ? readContext(s.id) : nil, rest: L.age(s.since), size: 12,
                                color: .secondaryLabelColor, digits: true))
        let picking = open && pickingId == id && picture != nil
        signatureInProgress += "{\(s.id)|\(stateWord)|\(s.project)|\(info.string)|\(pinnedRow ? "P" : "")|\(open ? "O" : "")\(picking ? "K" : "")|\(tone)|\(Emoji.keys[id] ?? "")\(Emoji.manual.contains(id) ? "M" : "")}"

        let box = RowBox(id: id, tone: tone, width: width, description: "\(s.project), \(stateWord), \(info.string)") { [unowned self] in
            self.hideBubble(byClick: true)
            self.goToChat(id)
        }
        var x = pad
        if hasImages {
            if let img = picture {
                // The picture is pressable (it opens the emoji picker): its area is 24 pt, with 2 pt of margin
                let cell = EmojiCell(img, side: 20, ring: false, description: L.changeEmoji, tip: L.changeEmoji) { [unowned self] in
                    self.openPicker(id)
                }
                cell.frame.origin = NSPoint(x: x - EmojiCell.margin, y: ((line - 24) / 2).rounded())
                box.addSubview(cell)
                pendingCells.append(cell)
            }
            x += 20 + gap
        }
        let wordView = TextBlock(attr(stateWord, 11.5, .semibold, ink.text), width: 120)
        wordView.frame.origin = NSPoint(x: x, y: ((line - wordView.textSize.height) / 2).rounded())
        box.addSubview(wordView)
        x += max(72, wordView.textSize.width) + gap
        var right = width - pad
        if hasPin {
            if pinnedRow {
                let pin = PinView(label: L.pinned)
                pin.frame.origin = NSPoint(x: right - PinView.width, y: ((line - pin.frame.height) / 2).rounded())
                box.addSubview(pin)
            }
            right -= PinView.width + gap
        }
        let infoView = TextBlock(info, width: 200)
        infoView.frame.origin = NSPoint(x: right - infoView.textSize.width, y: ((line - infoView.textSize.height) / 2).rounded())
        box.addSubview(infoView)
        let nameColor: NSColor = tone == .read ? .secondaryLabelColor : .labelColor
        let name = TextBlock(attr(s.project, 13.5, tone == .read ? .regular : .semibold, nameColor),
                             width: max(20, infoView.frame.minX - gap - x))
        name.frame.origin = NSPoint(x: x, y: ((line - name.textSize.height) / 2).rounded())
        box.addSubview(name)

        var totalHeight = line
        if picking {
            totalHeight = buildPicker(box, id: id, width: width, pad: pad, y0: 33, ink: ink) + 9
        } else if open {
            var buttons: [NSView]
            var gapX: CGFloat = 6   // with 8 the four buttons of "Finished" measured 334 pt and 332 fit
            if remindingId == id {
                // "Remind me in  [2 min] [5 min] [15 min]  Cancel": replaces the usual buttons
                gapX = 4
                buttons = [text(L.remindMeIn, 12.5, .regular, .secondaryLabelColor, width: width - 2 * pad)]
                for m in [2, 5, 15] {
                    buttons.append(button("\(m) min", .pill, ink) { [unowned self] in self.remind(id, minutes: m) })
                }
                buttons.append(button(L.cancel, .text, ink) { [unowned self] in
                    self.remindingId = nil
                    self.rebuildPanel(force: true)
                })
            } else {
                buttons = [button(L.goToChat, .primary, ink) { [unowned self] in self.goToChat(id) }]
                if tone == .reminded {
                    buttons.append(button(L.removeReminder, .secondary, ink) { [unowned self] in self.removeReminder(id) })
                } else if tone != .working && tone != .read {
                    buttons.append(button(L.remindMe, .secondary, ink) { [unowned self] in
                        self.remindingId = id
                        self.openRow = id
                        self.rebuildPanel(force: true)
                    })
                }
                if s.state == "wrote" && !s.seen {
                    buttons.append(button(L.markRead, .secondary, ink) { [unowned self] in self.markRead(id) })
                }
                buttons.append(button(pinnedRow ? L.unpin : L.pin, .secondary, ink) { [unowned self] in self.togglePin(id) })
            }
            let yb: CGFloat = 33
            let h = flow(buttons, in: box, x0: pad, y0: yb, width: width - 2 * pad, gapX: gapX, gapY: 8)
            totalHeight = yb + h + 9
        }
        box.setFrameSize(NSSize(width: width, height: totalHeight))
        return box
    }

    // MARK: Mouse: opening the box and the bubble

    func startMouse() {
        guard !captureFixed else { return }
        mouseTimer?.invalidate()
        hoverId = nil; restId = nil; candidateId = nil; outsideSince = nil
        // The mouse is looked at every 30 ms (not with tracking areas, which die with every rebuild of the panel).
        // In .common mode so it keeps running while scrolling.
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.tickMouse() }
        RunLoop.main.add(t, forMode: .common)
        mouseTimer = t
    }

    func stopMouse() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        hideBubble()
        hoverId = nil
    }

    /// The row under the point `p` (screen coordinates), if there is one and it is seen (a scroll can cover it).
    func rowAt(_ p: NSPoint) -> String? {
        guard let w = container.window else { return nil }
        let visible = w.convertToScreen(container.convert(container.bounds, to: nil))
        guard visible.contains(p) else { return nil }
        for (id, v) in rows {
            guard v.window === w else { continue }
            if w.convertToScreen(v.convert(v.bounds, to: nil)).contains(p) { return id }
        }
        return nil
    }

    func tickMouse() {
        guard popover.isShown, !captureFixed else { return }
        highlightCells(NSEvent.mouseLocation)
        // With a mouse button down nothing is touched: a quick click on a box would lose its mouseUp if the panel
        // were rebuilt between the mouseDown and the mouseUp.
        if NSEvent.pressedMouseButtons != 0 { return }
        let p = NSEvent.mouseLocation
        let under = rowAt(p)
        let now = ProcessInfo.processInfo.systemUptime
        let overBubble = bubble?.frame.contains(p) ?? false
        var rebuild = false

        // 1. The box that opens: 180 ms with the mouse over it; it closes on leaving (except with "Remind me in" or the
        // emoji picker open)
        if remindingId == nil && pickingId == nil {
            if openRow != nil && under != openRow { openRow = nil; rebuild = true }
            if openRow == nil, let b = under {
                if b != hoverId { hoverId = b; hoverSince = now }
                else if now - hoverSince >= 0.18 { openRow = b; rebuild = true }
            }
            if under == nil { hoverId = nil }
        } else {
            hoverId = nil
        }
        if rebuild { rebuildPanel(force: false) }

        // With the bubble turned off (or private mode, which keeps message text out), the emoji picker or the options
        // page open, there is no bubble
        if !opts.bubble || isPrivate || pickingId != nil || page == .options {
            if bubbleId != nil { hideBubble() }
            restId = nil
            return
        }

        // 2. The bubble: 600 ms resting on a box; with one open, another box changes the content after 140 ms;
        // it hides 250 ms after the mouse left the box and the bubble.
        let b2 = rebuild ? rowAt(p) : under
        if suppressed != nil && b2 != suppressed { suppressed = nil }
        if let g = bubbleId {
            if let b = b2, b != g {
                if candidateId != b { candidateId = b; candidateSince = now }
                else if now - candidateSince >= 0.14 { candidateId = nil; showBubble(b) }
                outsideSince = nil
            } else if b2 == g || overBubble {
                candidateId = nil
                outsideSince = nil
            } else {
                candidateId = nil
                if let f = outsideSince {
                    if now - f >= 0.25 { hideBubble() }
                } else {
                    outsideSince = now
                }
            }
        } else if let b = b2 {
            if b != restId { restId = b; restSince = now }
            else if now - restSince >= 0.6 && b != suppressed { showBubble(b) }
        } else {
            restId = nil
        }
    }

    // MARK: The bubble with the whole message

    /// What the bubble says (Markdown). "Needs you": the summary, which describes the permission or the question.
    /// Working: what you asked and Claude's last text. Otherwise Claude's last text in the transcript, or what the hook saved.
    func fullText(_ s: Session) -> String {
        var t: String
        switch s.state {
        case "needs":
            t = s.summary
        case "thinking":
            var parts: [String] = []
            if !s.request.isEmpty { parts.append("**\(L.youAsked):** " + escapeMarkdown(s.request)) }
            if let u = lastAssistantText(s.transcript) { parts.append(u) }
            t = parts.joined(separator: "\n\n")
        default:
            t = lastAssistantText(s.transcript) ?? (s.doneText.isEmpty ? s.summary : s.doneText)
        }
        if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { t = s.summary }
        if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { t = s.state == "thinking" ? L.stillWorking : L.noMessage }
        if t.count > 6000 { t = String(t.prefix(6000)) + "…" }
        return t
    }

    /// Shows the bubble of that session (or changes the one that is there). It goes beside the popover, at the height of the box.
    func showBubble(_ id: String, animate: Bool = true) {
        guard opts.bubble, !isPrivate, let window = container.window, let s = sessions.first(where: { $0.id == id }),
              rows.contains(where: { $0.id == id }) else { return }
        let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let content = buildBubble(word: word(s), ink: tone(s).ink, name: s.project, picture: sessionImage(for: id),
                                  text: fullText(s), width: 360, cap: floor(vf.height * 0.6))
        let isNew = bubble == nil
        if bubble == nil {
            let g = BubblePanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            g.isFloatingPanel = true
            g.hidesOnDeactivate = false
            g.isOpaque = false
            g.backgroundColor = .clear
            g.hasShadow = true
            g.ignoresMouseEvents = false          // only so scrolling works; it has no buttons
            g.becomesKeyOnlyIfNeeded = true
            g.collectionBehavior = [.transient, .ignoresCycle]
            bubble = g
        }
        guard let g = bubble else { return }
        g.appearance = window.effectiveAppearance
        g.setContentSize(content.frame.size)
        g.contentView = content
        bubbleId = id
        candidateId = nil
        outsideSince = nil
        placeBubble()
        if isNew {
            g.alphaValue = animate ? 0 : 1
            window.addChildWindow(g, ordered: .above)
            g.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            g.orderFront(nil)
            if animate {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.18
                    g.animator().alphaValue = 1
                }
            }
        }
        g.invalidateShadow()
    }

    /// To the left of the popover if it fits on the screen, else to the right; 10 pt gap; the top edge at the height of
    /// the box; never outside the visible area of the screen. Measured from the popover's content (not from its
    /// window, which brings ~13 pt of invisible margin).
    func placeBubble() {
        guard let g = bubble, let id = bubbleId, let w = container.window,
              let row = rows.first(where: { $0.id == id })?.view else { return }
        let vf = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let panel = w.convertToScreen(container.convert(container.bounds, to: nil))
        let rc = w.convertToScreen(row.convert(row.bounds, to: nil))
        let size = g.frame.size
        let left = panel.minX - 10 - size.width
        let x = left >= vf.minX ? left : panel.maxX + 10
        let y = max(vf.minY, min(rc.maxY - size.height, vf.maxY - size.height))
        g.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// After rebuilding the panel: the bubble follows its box; if the session is gone, it goes too.
    func adjustBubble() {
        guard let id = bubbleId else { return }
        if rows.contains(where: { $0.id == id }) { placeBubble() } else { hideBubble() }
    }

    /// `byClick`: the bubble closes because you pressed something; with the mouse still over that box it does not come back by itself.
    func hideBubble(byClick: Bool = false) {
        suppressed = byClick ? rowAt(NSEvent.mouseLocation) : nil
        if let g = bubble {
            g.parent?.removeChildWindow(g)
            g.orderOut(nil)
        }
        bubble = nil
        bubbleId = nil
        candidateId = nil
        outsideSince = nil
        restId = nil
    }

    // MARK: Navigation test (CCNOTIFY_TEST_NAV=<id>)

    /// Does what the clicks do, through the same functions: options page, a switch, a family, the icon, back to the list,
    /// the emoji picker of a row and a choice in it; notes the result of each step in stderr and quits.
    func navTest(_ id: String) {
        func note(_ t: String) {
            let o = PanelOptions.load()
            fputs("\(t): page=\(page == .options ? "options" : "list") picking=\(pickingId ?? "-") emoji(\(id))=\(Emoji.keys[id] ?? "-")"
                  + "\(Emoji.manual.contains(id) ? "*" : "") family=\(o.emojiFamily) icon=\(o.icon) bubble=\(o.bubble) rows=\(rows.count)"
                  + " height=\(Int(container.frame.height))\n", stderr)
        }
        guard popover.isShown else { fputs("the panel is not open\n", stderr); exit(2) }
        note("1. list")
        openOptions(); note("2. gear")
        applyOptions(["bubble": false]); note("3. bubble off")
        applyOptions(["emoji_theme": "music"]); note("4. family music")
        showAllFamilies = true; rebuildPanel(force: true); note("5. all families")
        applyOptions(["icon": "bolt.fill"]); note("6. icon")
        applyOptions(["emoji_theme": emojiOff]); note("7. emoji off")
        applyOptions(["emoji_theme": "animals"]); note("8. family animals")
        closeOptions(); note("9. back")
        openPicker(id); note("10. picker")
        pickEmoji(id, "fruits/banana.png"); note("11. picked banana")
        openPicker(id); pickEmoji(id, nil); note("12. automatic")
        applyOptions(["bubble": true, "icon": defaultBarIcon, "emoji_theme": defaultEmojiFamily]); note("13. defaults")
        exit(0)
    }

    // MARK: Mouse test (CCNOTIFY_TEST_MOUSE=<id>)

    /// Moves the real cursor (CGWarpMouseCursorPosition) onto a row and away, writing to stderr what is open at each
    /// step; at the end the cursor goes back where it was.
    func mouseTest(_ id: String) {
        guard let w = container.window, popover.isShown else { fputs("the panel is not open\n", stderr); exit(2) }
        let initial = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens[0].frame.height
        func move(_ p: NSPoint) { CGWarpMouseCursorPosition(CGPoint(x: p.x, y: screenHeight - p.y)) }
        func lineOf(_ id: String) -> NSPoint {      // the middle of a row's line (its top 34 pt)
            guard let v = rows.first(where: { $0.id == id })?.view else { fputs("no such row\n", stderr); exit(2) }
            let r = w.convertToScreen(v.convert(v.bounds, to: nil))
            return NSPoint(x: r.midX, y: r.maxY - 17)
        }
        // (if the numbers look wrong, check you did not touch the mouse: a real movement overrides the warp)
        func note(_ t: String) {
            fputs("\(t): open row=\(openRow ?? "-") bubble=\(bubbleId ?? "-") under=\(rowAt(NSEvent.mouseLocation) ?? "-")\n", stderr)
        }
        var t = 0.0
        func then(_ dt: Double, _ f: @escaping () -> Void) {
            t += dt
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f)
        }
        then(0) { move(lineOf(id)); note("1. mouse on \(id) (t=0)") }
        then(0.08) { note("2. +80 ms (the row must not be open yet)") }
        then(0.30) { note("3. +380 ms (row open, no bubble yet)") }
        then(0.55) { note("4. +930 ms (the bubble is up)") }
        then(0.05) {
            if let g = self.bubble { move(NSPoint(x: g.frame.midX, y: g.frame.midY)) }
            note("5. mouse on the bubble")
        }
        then(0.40) { note("6. +400 ms on the bubble (still there; the row has closed)") }
        then(0.05) {
            if let g = self.bubble { move(NSPoint(x: g.frame.minX - 120, y: g.frame.midY)) }
            note("7. mouse away from everything")
        }
        then(0.12) { note("8. +120 ms away (the bubble is not hidden yet)") }
        then(0.35) { note("9. +470 ms away (bubble hidden; the panel is still open)") }
        then(0.1) { move(initial); exit(0) }
    }

    // MARK: Test capture

    /// CCNOTIFY_CAPTURE_MENU: opens the real panel, grabs its window (a window of this process, so no Screen Recording
    /// permission is needed), draws the status item at its real place and quits. A watchdog ends the process even
    /// if the panel never shows up.
    func captureMenu(to path: String) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("menu capture timed out\n", stderr)
            exit(1)
        }
        // Wait for the status item to get its window and its final width, then open the panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.item?.button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let id = env["CCNOTIFY_CAPTURE_BUBBLE"], !id.isEmpty { self.showBubble(id, animate: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let ok = self.grabAndCompose(to: path)
                    self.popover.performClose(nil)
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    /// Pixels of one of this process's windows. CGWindowListCreateImage is looked up at run time because the newest
    /// SDKs mark it unavailable in Swift (they point to ScreenCaptureKit, which needs the Screen Recording permission
    /// this test hook is meant to avoid); the function itself still works for a process's own windows.
    func windowImage(_ id: CGWindowID) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: Fn.self)
        let options: CGWindowListOption = .optionIncludingWindow
        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return create(.null, options.rawValue, id, imageOptions.rawValue)?.takeRetainedValue()
    }

    /// True when a grab shows nothing: fully transparent, or one flat color.
    func isBlank(_ image: CGImage) -> Bool {
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        var flat = true
        for i in stride(from: 4, to: px.count, by: 4) where flat {
            for c in 0..<4 where abs(Int(px[i + c]) - Int(px[c])) > 6 { flat = false }
        }
        return flat
    }

    /// The popover's window (and the bubble's, if there is one) grabbed as they are on screen, with the status item
    /// drawn at its real place over a piece of menu bar, on a soft backdrop. The windows keep their real positions
    /// relative to the item, so the arrow visibly points at the icon.
    func grabAndCompose(to path: String) -> Bool {
        let scale = CGFloat(Double(env["CCNOTIFY_CAPTURE_SCALE"] ?? "") ?? 2)
        guard popover.isShown, let button = item?.button, let itemWindow = button.window, let popWindow = container.window else {
            fputs("the panel is not open\n", stderr)
            return false
        }
        var shots: [(frame: NSRect, image: CGImage)] = []
        for w in [popWindow] + (bubble.map { [$0 as NSWindow] } ?? []) {
            guard let img = windowImage(CGWindowID(w.windowNumber)) else {
                fputs("could not grab a window of the panel\n", stderr)
                return false
            }
            // With the display asleep or the screen locked the window exists but has no pixels
            if isBlank(img) {
                fputs("the panel came out empty: is the display asleep or the screen locked?\n", stderr)
                return false
            }
            shots.append((w.frame, img))
        }
        let fi = itemWindow.frame
        let margin: CGFloat = 36
        let minX = min(fi.minX, shots.map { $0.frame.minX }.min() ?? fi.minX) - margin
        let maxX = max(fi.maxX, shots.map { $0.frame.maxX }.max() ?? fi.maxX) + margin
        let minY = (shots.map { $0.frame.minY }.min() ?? fi.minY) - margin
        let maxY = fi.maxY
        let w = maxX - minX, h = maxY - minY
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
            // A piece of the menu bar across the top, where the real one is
            (dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.62)).setFill()
            NSRect(x: 0, y: fi.minY - minY, width: w, height: h - (fi.minY - minY)).fill()
            let cg = ctx.cgContext
            drawStatusItem(button, in: NSRect(x: fi.minX - minX, y: fi.minY - minY, width: fi.width, height: fi.height),
                           dark: dark, cg: cg)
            // The windows, each with a soft shadow that follows its shape
            for shot in shots {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
                shadow.shadowBlurRadius = 20
                shadow.shadowOffset = NSSize(width: 0, height: -6)
                shadow.set()
                cg.draw(shot.image, in: NSRect(x: shot.frame.minX - minX, y: shot.frame.minY - minY,
                                               width: shot.frame.width, height: shot.frame.height))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// The status item as the button holds it (its symbol and its count), highlighted like an item whose panel is
    /// open. Drawn here because a grab of the item's window comes without what the system paints on screen. Must
    /// run with the capture appearance current.
    func drawStatusItem(_ button: NSStatusBarButton, in rect: NSRect, dark: Bool, cg: CGContext) {
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        let number = NSMutableAttributedString(attributedString: button.attributedTitle)
        number.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: number.length))
        let numberW = number.length > 0 ? ceil(number.size().width) : 0
        let iconSize = button.image?.size ?? .zero
        let gap: CGFloat = number.length > 0 ? iconNumberGap : 0
        var x = rect.minX + (rect.width - iconSize.width - gap - numberW) / 2
        if let img = button.image {
            let iconRect = NSRect(x: x, y: rect.midY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
            // The symbol is a template: paint the label color only where it has pixels
            cg.beginTransparencyLayer(in: iconRect, auxiliaryInfo: nil)
            img.draw(in: iconRect)
            cg.setBlendMode(.sourceAtop)
            cg.setFillColor(NSColor.labelColor.cgColor)
            cg.fill(iconRect)
            cg.endTransparencyLayer()
            x += iconSize.width + gap
        }
        if number.length > 0 { number.draw(at: NSPoint(x: x, y: rect.midY - number.size().height / 2)) }
    }

    // MARK: Actions

    /// "Go to chat": its terminal window, and the session is marked as seen.
    func goToChat(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        markSeen(id)
        runFocus(s.focus)
        popover.performClose(nil)
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

    func markRead(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }), s.state == "wrote" else { return }
        markSeen(id)
        refresh()
        rebuildPanel(force: true)
    }

    /// You chose a length in "Remind me in": the reminder is created and the box moves to the reminded ones.
    func remind(_ id: String, minutes: Int) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        setReminder(s, minutes: minutes)
        remindingId = nil
        refresh()
        rebuildPanel(force: true)
    }

    /// "Remove reminder": deletes the file and the session counts again among those that wait for you.
    func removeReminder(_ id: String) {
        try? FileManager.default.removeItem(atPath: remindersDir + "/" + safeName(id) + ".json")
        refresh()
        rebuildPanel(force: true)
    }

    func markAllRead() {
        for s in unread { markSeen(s.id) }
        refresh()
        rebuildPanel(force: true)
    }

    func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBar = MenuBar()
app.delegate = menuBar
app.run()
