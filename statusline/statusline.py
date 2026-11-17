#!/usr/bin/env python3
"""CCNotify status line: one minimal gray line for Claude Code's `statusLine` setting.

    project  model effort | ctx % | session ~% ~$ tokens | 5h % reset | wk % $/$ | TICKER price %

- "session" restarts on its own after /clear (new session = counter at zero).
- The session's share of the weekly plan usage is an estimate: the weekly % is split
  across the week's sessions in proportion to their list-price cost, so a session can
  never show more than the whole week.
- The optional market ticker is read from a local copy. When that copy is stale it is
  refreshed in the background, so the bar never waits on the network. With no ticker
  configured (the default) this script makes no network access at all.
- Never crashes: whatever happens, it prints one line and exits 0.

Config:  $CCNOTIFY_HOME/config.json  ->  "statusline": {...}   (see docs/statusline.md)
Cache:   $CCNOTIFY_HOME/state/statusline/
Shared with the menu bar app (optional, read-only for it):
         $CCNOTIFY_HOME/state/context/<session>.json  {"pct", "at"}  context used by that session
         $CCNOTIFY_HOME/state/usage.json  {"five_hour": {"pct", "resets_at"}, "seven_day": {...}, "at"}
Python 3.8+, standard library only.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time

# ---------------------------------------------------------------- paths and config

def ccnotify_home():
    env = os.environ.get("CCNOTIFY_HOME")
    if env:
        return os.path.expanduser(env)
    claude_dir = os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"
    return os.path.join(os.path.expanduser(claude_dir), "ccnotify")


HOME = ccnotify_home()
CACHE_DIR = os.path.join(HOME, "state", "statusline")

DEFAULTS = {
    "plan_monthly_usd": None,        # None -> hide plan-dollar figures, show only %
    "ticker": "",                    # "" -> no ticker and no network access
    "ticker_refresh_open_s": 60,     # seconds between refreshes while the market is open
    "ticker_refresh_closed_s": 1800,  # ... while it is closed
    "ticker_min_move_pct": 0.5,      # % move from which the ticker takes a color
    "color_threshold_pct": 40,       # percentages stay gray up to this value
}


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def num(value):
    """A real number, or None. Rejects strings, bools and NaN."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value:
        return None
    return float(value)


def obj(parent, key):
    """parent[key] if it is a dict, else {} (Claude Code may omit or change fields)."""
    v = parent.get(key) if isinstance(parent, dict) else None
    return v if isinstance(v, dict) else {}


def load_config():
    cfg = dict(DEFAULTS)
    cfg["project_names"] = {}
    raw = read_json(os.path.join(HOME, "config.json"))
    if not isinstance(raw, dict):
        return cfg, "auto"
    names = raw.get("project_names")
    if isinstance(names, dict):
        cfg["project_names"] = names
    section = raw.get("statusline")
    if isinstance(section, dict):
        for key in DEFAULTS:
            if key in section:
                cfg[key] = section[key]
    for key in ("ticker_refresh_open_s", "ticker_refresh_closed_s",
                "ticker_min_move_pct", "color_threshold_pct"):
        v = num(cfg[key])
        cfg[key] = v if v is not None else DEFAULTS[key]
    plan = num(cfg["plan_monthly_usd"])
    cfg["plan_monthly_usd"] = plan if plan and plan > 0 else None
    if not isinstance(cfg["ticker"], str):
        cfg["ticker"] = ""
    lang = raw.get("language")
    return cfg, lang if isinstance(lang, str) else "auto"


WORKTREE_MARK = "/.claude/worktrees/"


def project_label(path, names=None):
    """Name of the project folder. A Claude Code worktree (<project>/.claude/worktrees/<name>) shows the
    project it belongs to; `project_names` in the config can give a folder a shorter label.
    Kept in step with hooks/notify.py."""
    folder = str(path or "").rstrip("/")
    cut = folder.find(WORKTREE_MARK)
    if cut >= 0:
        folder = folder[:cut].rstrip("/")
    base = os.path.basename(folder)
    nick = names.get(base) if isinstance(names, dict) else None
    if isinstance(nick, str) and nick.strip():
        return nick.strip()
    return base or str(path)


def write_json(path, obj):
    tmp = "%s.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


# ---------------------------------------------------------------- numbers for the menu bar app

PANEL_REWRITE_S = 5      # an unchanged context % is not rewritten more often than this
SAME_WINDOW = 60         # two "resets_at" less than a minute apart are the same limit window


def session_file_name(sid):
    """A session id as a file name; the same rule as hooks/notify.py and the menu bar app (safeName)."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", sid or "")[:128].lstrip(".") or "unknown"


def mkdir_private(path):
    if not os.path.isdir(path):
        os.mkdir(path, 0o700)
        os.chmod(path, 0o700)


def write_private(path, obj):
    """Atomic write, file mode 0600."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def merged_window(old, pct, reset):
    """One limit window as {"pct", "resets_at"}, or None when there is nothing to say. Every session brings the
    snapshot of its own last reply, so the newer window wins and, within the same window, the higher % (usage
    only goes up)."""
    old = old if isinstance(old, dict) else {}
    old_pct, old_reset = num(old.get("pct")), num(old.get("resets_at"))
    if pct is None:
        return {"pct": old_pct, "resets_at": old_reset} if old_pct is not None else None
    new = {"pct": pct, "resets_at": reset}
    if old_pct is None:
        return new
    kept = {"pct": old_pct, "resets_at": old_reset}
    if reset is None:                      # the new snapshot cannot say which window it belongs to
        return kept if old_reset is not None or pct < old_pct else new
    if old_reset is None:
        return new
    if reset > old_reset + SAME_WINDOW:
        return new
    return new if abs(reset - old_reset) <= SAME_WINDOW and pct >= old_pct else kept


def save_for_panel(data, ctx_pct, five_pct, five_reset, week_pct, week_reset, now=None):
    """Hand the numbers only the status line receives to the menu bar app: this session's context % and the
    account's 5-hour / weekly usage. Writes nothing for data that is absent. May raise: the caller wraps it."""
    now = time.time() if now is None else now
    state = os.path.join(HOME, "state")
    sid = data.get("session_id")
    if isinstance(sid, str) and sid and ctx_pct is not None:
        folder = os.path.join(state, "context")
        mkdir_private(state)
        mkdir_private(folder)
        path = os.path.join(folder, session_file_name(sid) + ".json")
        old = read_json(path)
        same = (isinstance(old, dict) and num(old.get("pct")) == ctx_pct
                and now - (num(old.get("at")) or 0) < PANEL_REWRITE_S)
        if not same:
            write_private(path, {"pct": ctx_pct, "at": now})
    if five_pct is None and week_pct is None:
        return
    path = os.path.join(state, "usage.json")
    old = read_json(path)
    old = old if isinstance(old, dict) else {}
    out = {}
    for key, pct, reset in (("five_hour", five_pct, five_reset), ("seven_day", week_pct, week_reset)):
        window = merged_window(old.get(key), pct, reset or None)
        if window is not None:
            out[key] = window
    out["at"] = now
    if all(out.get(k) == old.get(k) for k in ("five_hour", "seven_day")) and now - (num(old.get("at")) or 0) < PANEL_REWRITE_S:
        return
    mkdir_private(state)
    write_private(path, out)


# ---------------------------------------------------------------- language

LABELS = {
    "en": {"session": "session", "week": "wk"},
    "es": {"session": "sesión", "week": "sem"},
}


def detect_language(setting):
    """Return "en" or "es". 'auto' looks at the macOS preferred language, once, then caches it."""
    if setting in LABELS:
        return setting
    cache = os.path.join(CACHE_DIR, "lang.json")
    cached = read_json(cache)
    if isinstance(cached, dict) and cached.get("lang") in LABELS:
        return cached["lang"]
    first = ""
    try:
        out = subprocess.run(["/usr/bin/defaults", "read", "-g", "AppleLanguages"],
                             capture_output=True, text=True, timeout=2).stdout
        m = re.search(r'"?([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*)"?', out.replace("(", " ", 1))
        first = m.group(1) if m else ""
    except Exception:
        pass
    if not first:
        first = (os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES")
                 or os.environ.get("LANG") or "")
    lang = "es" if first.lower().startswith("es") else "en"
    try:
        write_json(cache, {"lang": lang})
    except Exception:
        pass
    return lang


# ---------------------------------------------------------------- palette

def c256(n):
    return "\033[38;5;%dm" % n


RESET = "\033[0m"
BOLD = "\033[1m"
VAL = c256(250)    # numbers you read
SEC = c256(245)    # supporting data: dollars, tokens, times
LBL = c256(241)    # labels: ctx, session, 5h, wk
RULE = c256(237)   # separators
PROJ = c256(110)   # project name, muted blue
GREEN = c256(108)
YELLOW = c256(179)
RED = c256(167)
SEP = " %s│%s " % (RULE, RESET)


def make_color_for(threshold):
    def color_for(pct):
        """Gray up to the threshold; above it, color starts."""
        if pct is None or pct <= threshold:
            return VAL
        if pct < 60:
            return GREEN
        if pct < 80:
            return YELLOW
        return RED
    return color_for


def fmt_tokens(n):
    if n >= 1000000:
        return "%.1fM" % (n / 1000000)
    if n >= 1000:
        return "%.0fk" % (n / 1000)
    return str(int(n))


def fmt_clock(epoch):
    t = time.localtime(epoch)
    return time.strftime("%I:%M", t).lstrip("0") + time.strftime("%p", t).lower()


# ---------------------------------------------------------------- session tokens

def session_tokens(data):
    """Sum new tokens (input + cache writes + output) from the session transcript.
    Reads only what was appended since the last call."""
    sid, path = data.get("session_id"), data.get("transcript_path")
    if not isinstance(sid, str) or not isinstance(path, str) or not sid or not os.path.exists(path):
        return None
    state_file = os.path.join(CACHE_DIR, "%s.json" % safe_name(sid))
    fresh = {"offset": 0, "sum": 0, "pid": None, "pval": 0}
    st = dict(fresh)
    saved = read_json(state_file)
    if isinstance(saved, dict):
        st.update(saved)
    try:
        if os.path.getsize(path) < st["offset"]:
            st = dict(fresh)
        with open(path, "rb") as f:
            f.seek(st["offset"])
            chunk = f.read()
    except Exception:
        return st["sum"] + st["pval"]
    end = chunk.rfind(b"\n")
    if end >= 0:
        for line in chunk[:end].split(b"\n"):
            if b'"type":"assistant"' not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if not isinstance(e, dict) or e.get("type") != "assistant" or e.get("isSidechain"):
                continue
            msg = obj(e, "message")
            usage = obj(msg, "usage")
            tok = ((num(usage.get("input_tokens")) or 0) + (num(usage.get("cache_creation_input_tokens")) or 0)
                   + (num(usage.get("output_tokens")) or 0))
            mid = msg.get("id")
            if mid is not None and mid == st["pid"]:
                st["pval"] = max(st["pval"], tok)   # the same message is stored on several lines
            else:
                st["sum"] += st["pval"]
                st["pid"] = mid
                st["pval"] = tok
        st["offset"] += end + 1
        try:
            write_json(state_file, st)
        except Exception:
            pass
    return st["sum"] + st["pval"]


def safe_name(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", s)[:120]


# ---------------------------------------------------------------- weekly usage

SAME_WEEK = 3600   # two "resets_at" less than an hour apart are the same week


def fresh_week(data):
    """The weekly % a session sees is the one from its last reply, so in an idle window it
    is stale. Across all sessions we keep the most recent one (within a week the % only
    goes up) and the status line uses that."""
    wk = obj(obj(data, "rate_limits"), "seven_day")
    pct, reset = num(wk.get("used_percentage")), num(wk.get("resets_at"))
    gfile = os.path.join(CACHE_DIR, "week.json")
    g = read_json(gfile)
    if not isinstance(g, dict):
        g = {}
    gp, gr = num(g.get("pct")), num(g.get("reset"))
    if pct is None or not reset:
        return (gp, gr) if gr and gr > time.time() else (pct, reset)
    if not gr or reset > gr + SAME_WEEK:             # first time, or another week started
        gp, gr = pct, reset
    elif abs(reset - gr) <= SAME_WEEK:               # same week: the larger value wins
        gp = max(gp if gp is not None else pct, pct)
    else:                                            # this window is stuck in last week
        return gp, gr
    if gp != g.get("pct") or gr != g.get("reset"):
        try:
            write_json(gfile, {"pct": gp, "reset": gr})
        except Exception:
            pass
    return gp, gr


def fraction_before(path, t):
    """What part of the session transcript (by bytes) is older than time t.
    Used for a session that comes from last week: that part is discounted."""
    pat = re.compile(rb'"timestamp":"([^"]+)"')

    def time_at(f, pos):
        f.seek(pos)
        if pos:
            f.readline()                             # skip the cut line
        for _ in range(40):
            line = f.readline()
            if not line:
                return None
            m = pat.search(line)
            if m:
                try:
                    s = m.group(1).decode().replace("Z", "+00:00")
                    return datetime.datetime.fromisoformat(s).timestamp()
                except Exception:
                    pass
        return None

    size = os.path.getsize(path)
    if size <= 0:
        return 0.0
    with open(path, "rb") as f:
        first = time_at(f, 0)
        if first is None or first >= t:
            return 0.0
        lo, hi = 0, size
        for _ in range(40):
            if hi - lo < 65536:
                break
            mid = (lo + hi) // 2
            h = time_at(f, mid)
            if h is None or h >= t:
                hi = mid
            else:
                lo = mid
    return hi / size


def session_week_pct(data, cost, week_pct, week_reset):
    """How much of the week this session used (estimate).
    Claude Code does not report that per session. What was spent in the week is split
    across the week's sessions in proportion to their list-price cost, so a session can
    never come out with more than the whole week."""
    sid = data.get("session_id")
    if cost is None or week_pct is None or not week_reset or not isinstance(sid, str) or not sid:
        return None
    sid = safe_name(sid)
    start = week_reset - 7 * 86400
    sfile = os.path.join(CACHE_DIR, "%s.week" % sid)
    st = read_json(sfile)
    if not isinstance(st, dict):
        st = None
    if st is None:                                   # first time this session is seen
        base = 0.0
        try:
            base = cost * fraction_before(data.get("transcript_path"), start)
        except Exception:
            pass
        st = {"reset": week_reset, "base": base, "cost": None}
    elif week_reset > (num(st.get("reset")) or 0) + SAME_WEEK:   # another week started
        st = {"reset": week_reset, "base": num(st.get("cost")) or 0.0, "cost": None}
    prev_cost = num(st.get("cost"))
    base = num(st.get("base")) or 0.0
    if prev_cost is not None and cost < prev_cost - 0.01:
        # the cost counter started over (resumed session): keep what was already counted
        base = cost - max(0.0, prev_cost - base)
        st["base"] = base
    if st.get("cost") != cost:
        st["cost"] = cost
        try:
            write_json(sfile, st)
        except Exception:
            pass
    mine = max(0.0, cost - base)
    total = 0.0
    for name in os.listdir(CACHE_DIR):
        if not name.endswith(".week"):
            continue
        if name[:-5] == sid:
            total += mine
            continue
        o = read_json(os.path.join(CACHE_DIR, name))
        if isinstance(o, dict) and abs((num(o.get("reset")) or 0) - week_reset) <= SAME_WEEK:
            total += max(0.0, (num(o.get("cost")) or 0.0) - (num(o.get("base")) or 0.0))
    if total <= 0:
        return None
    return week_pct * min(1.0, mine / total)


# ---------------------------------------------------------------- ticker

TICKER_RE = re.compile(r"^[A-Za-z0-9.^=-]{1,15}$")
FETCH_SH = ('/usr/bin/curl -s -m 8 -A "Mozilla/5.0" "$1" -o "$2.tmp" '
            '&& grep -q regularMarketPrice "$2.tmp" && mv "$2.tmp" "$2"')


def ticker_segment(cfg, seg, short):
    """Price and daily change for the configured ticker. Returns nothing if there is no
    ticker. Reads a local copy; refreshes it in the background when it is stale."""
    ticker = cfg["ticker"].strip()
    if not ticker or not TICKER_RE.match(ticker):
        return
    name = ticker.upper()
    cache = os.path.join(CACHE_DIR, "ticker-%s.json" % safe_name(name))
    lock = os.path.join(CACHE_DIR, "ticker-%s.lock" % safe_name(name))
    now = time.time()
    price = prev = stamp = None
    is_open = False
    age = None
    try:
        age = now - os.path.getmtime(cache)
        meta = read_json(cache)["chart"]["result"][0]["meta"]
        price = num(meta.get("regularMarketPrice"))
        prev = num(meta.get("chartPreviousClose")) or num(meta.get("previousClose"))
        stamp = num(meta.get("regularMarketTime"))   # when that price was marked
        reg = obj(obj(meta, "currentTradingPeriod"), "regular")
        is_open = bool(reg.get("start") and reg["start"] <= now < reg.get("end", 0))
    except Exception:
        pass
    ttl = cfg["ticker_refresh_open_s"] if is_open else cfg["ticker_refresh_closed_s"]
    if age is None or age > ttl:
        try:
            lock_age = now - os.path.getmtime(lock)
        except Exception:
            lock_age = 1e9
        if lock_age > 15:                      # keep every session from querying at once
            try:
                open(lock, "w").close()
                url = ("https://query1.finance.yahoo.com/v8/finance/chart/%s?range=1d&interval=1d"
                       % name)
                subprocess.Popen(["/bin/sh", "-c", FETCH_SH, "sh", url, cache],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            except Exception:
                pass
    if price is None:
        return
    txt = "%s%s%s %s%.2f%s" % (LBL, name, RESET, VAL, price, RESET)
    if prev:
        chg = (price - prev) / prev * 100
        recent = is_open and age is not None and age < 300
        col = (GREEN if chg >= 0 else RED) if (recent and abs(chg) >= cfg["ticker_min_move_pct"]) else SEC
        txt += " %s%+.2f%%%s" % (col, chg, RESET)
    short["ticker"] = txt
    if stamp:
        txt += " %s%s%s" % (LBL, fmt_clock(stamp), RESET)
    seg["ticker"] = txt


# ---------------------------------------------------------------- build and trim the line

ORDER = ["project", "model", "ctx", "session", "5h", "week", "ticker"]
# What is sacrificed first when width runs out. The weekly % is never dropped.
TRIMS = [("drop", "model"), ("short", "week"), ("short", "ticker"), ("drop", "ticker"),
         ("short", "5h"), ("short", "session"), ("drop", "session"), ("drop", "ctx")]


def visible_width(s):
    return len(re.sub(r"\033\[[0-9;]*m", "", s))


def build(data):
    cfg, lang_setting = load_config()
    try:
        os.makedirs(HOME, exist_ok=True)
        mkdir_private(os.path.join(HOME, "state"))
        os.makedirs(CACHE_DIR, exist_ok=True)
    except Exception:
        pass
    labels = LABELS[detect_language(lang_setting)]
    color_for = make_color_for(cfg["color_threshold_pct"])
    plan_week = cfg["plan_monthly_usd"] * 12 / 52 if cfg["plan_monthly_usd"] else None

    seg, short = {}, {}

    # project and model
    ws = obj(data, "workspace")
    project_dir = ws.get("project_dir") or ws.get("current_dir") or os.getcwd()
    project = project_label(project_dir, cfg.get("project_names"))
    model = obj(data, "model").get("display_name") or "?"
    if data.get("fast_mode"):
        model += " ⚡"
    effort = str(obj(data, "effort").get("level") or "").strip()
    seg["project"] = "%s%s%s%s" % (PROJ, BOLD, project, RESET)
    seg["model"] = "%s%s%s%s" % (LBL, model, (" " + effort) if effort else "", RESET)

    # context window
    ctx_pct = num(obj(data, "context_window").get("used_percentage"))
    if ctx_pct is not None:
        seg["ctx"] = "%sctx%s %s%.0f%%%s" % (LBL, RESET, color_for(ctx_pct), ctx_pct, RESET)

    # weekly numbers (shared across sessions) and this session's slice of them
    cost = num(obj(data, "cost").get("total_cost_usd"))
    try:
        tokens = session_tokens(data)
    except Exception:
        tokens = None
    rl = obj(data, "rate_limits")
    five = obj(rl, "five_hour")
    week = obj(rl, "seven_day")
    try:
        week_pct, week_reset = fresh_week(data)
    except Exception:
        week_pct, week_reset = num(week.get("used_percentage")), num(week.get("resets_at"))
    try:
        sess_pct = session_week_pct(data, cost, week_pct, week_reset)
    except Exception:
        sess_pct = None

    # session: estimated share of the week, plan dollars (only if configured), tokens
    bits = []
    if sess_pct is not None:
        bits.append("%s~%.1f%%%s" % (VAL, sess_pct, SEC))
        if plan_week:
            bits.append("~$%.2f" % (plan_week * sess_pct / 100))
    if tokens is not None:
        bits.append(fmt_tokens(tokens))
    if bits:
        seg["session"] = "%s%s %s%s%s" % (LBL, labels["session"], SEC, " ".join(bits), RESET)
        if len(bits) > 1:
            short["session"] = "%s%s %s%s%s" % (LBL, labels["session"], SEC, bits[0], RESET)

    # 5-hour limit: % and only the reset time
    five_pct, five_reset = num(five.get("used_percentage")), num(five.get("resets_at"))
    if five_pct is not None or five_reset:
        txt = "%s5h%s " % (LBL, RESET)
        txt += ("%s%.0f%%%s" % (color_for(five_pct), five_pct, RESET) if five_pct is not None
                else "%s--%s" % (LBL, RESET))
        short["5h"] = txt
        if five_reset:
            txt += " %s↻%s%s" % (SEC, fmt_clock(five_reset), RESET)
        seg["5h"] = txt

    # weekly limit: % (colored above the threshold) and plan dollars in gray (if configured)
    if week_pct is None:
        week_pct = num(week.get("used_percentage"))
    if week_pct is not None:
        short["week"] = "%s%s%s %s%.0f%%%s" % (LBL, labels["week"], RESET, color_for(week_pct), week_pct, RESET)
        seg["week"] = short["week"]
        if plan_week:
            seg["week"] += " %s$%.2f/$%.0f%s" % (SEC, plan_week * week_pct / 100, plan_week, RESET)

    # numbers for the menu bar app (never lets a failure reach the line)
    try:
        save_for_panel(data, ctx_pct, five_pct, five_reset, week_pct, week_reset)
    except Exception:
        pass

    # optional market ticker (no network access unless one is configured)
    try:
        ticker_segment(cfg, seg, short)
    except Exception:
        pass

    return fit(seg, short)


def line(seg):
    out = seg.get("project", "")
    if "model" in seg:
        out += "  " + seg["model"]
    rest = [seg[k] for k in ORDER[2:] if k in seg]
    return SEP.join([out] + rest)


def fit(seg, short):
    try:
        cols = int(os.environ.get("COLUMNS") or 0)
    except ValueError:
        cols = 0
    if cols > 20:
        limit = cols - 6                       # margin Claude Code leaves at the sides
        for action, key in TRIMS:
            if visible_width(line(seg)) <= limit:
                break
            if action == "drop":
                seg.pop(key, None)
            elif key in short and key in seg:
                seg[key] = short[key]
    return line(seg)


def main():
    try:
        data = json.load(sys.stdin)
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except Exception:
        print("statusline: could not read input")
        return
    try:
        out = build(data)
    except Exception:
        out = "statusline"
    print(out)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("statusline")
    sys.exit(0)
