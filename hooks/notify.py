#!/usr/bin/env python3
"""CCNotify hook logic for Claude Code.

    notify.py stop | notification | prompt | session-start | session-end      (hook JSON on stdin)

- stop          popup "done" (unless background agents/workflows are still running in that session)
- notification  popup only when Claude needs you: permission_prompt, elicitation_*, agent_needs_input;
                an idle_prompt repairs a row left on "thinking" (no popup)
- prompt        menu bar: session -> thinking
- session-start menu bar: drop the previous session of the same Claude process (/clear); creates no row
- session-end   menu bar: remove the session

Popups are rendered by CCNotify.app: a JSON file is queued in state/queue/ and the app is opened with
`open -n -g CCNotify.app --args <json>`. Without the app, falls back to `osascript display notification`.
Session states for the menu bar go to state/sessions/<id>.json. Decisions (never message text) are appended
to state/ccnotify.log.

This script must never get in Claude Code's way: whatever happens it exits 0 and prints nothing.
Undocumented-format parsing lives in ccnotify_transcript.py. Python 3.9+, standard library only.
"""
import contextlib
import copy
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import uuid

import ccnotify_transcript as transcript_parser

KINDS = ("done", "permission", "question", "agent")
EVENTS = ("stop", "notification", "prompt", "session-start", "session-end")
DEFAULT_HOST = "com.microsoft.VSCode"
TEXT_CAP = 20000
LOG_MAX_BYTES = 1_000_000
STALE_QUEUE_SECONDS = 3600
STALE_STATE_SECONDS = 7 * 24 * 3600
DEDUPE_WINDOW_SECONDS = 120
JOB_ID = re.compile(r"[A-Za-z0-9_-]{4,40}")  # short id of a background session, as `claude attach` takes it

DEFAULT_CONFIG = {
    "language": "auto",
    "popup": {
        "enabled": True,
        "seconds": 60,
        "width": 460,
        "max_height_ratio": 0.6,
        "max_stacked": 4,
        "sticky_needs_you": True,
        "font_size": 13,
        "private": False,
        "style": "color",         # "color" | "neutral" | "mono"; anything else means "color"
        "compact_lines": 2,       # lines shown by older popups in the stack
    },
    "sounds": {
        "done": {"sound": "Glass", "volume": 0.5, "only_when_away": True, "min_turn_seconds": 15},
        "permission": {"sound": "Submarine", "volume": 0.8, "only_when_away": False},
        "question": {"sound": "Ping", "volume": 0.8, "only_when_away": False},
        "agent": {"sound": "Purr", "volume": 0.7, "only_when_away": False},
    },
    "quiet_hours": {"enabled": False, "from": "22:00", "to": "07:00"},
    "events": {"done": True, "permission": True, "question": True, "agent": True},
    "statusline": {},
    "project_names": {},          # folder name -> label shown for that project, e.g. {"long-repository-name": "repo"}
}

STRINGS = {
    "en": {
        "permission_ask": "Asks permission to use **{tool}**",
        "permission_generic": "Asks for your permission",
        "needs_fallback": "Waiting for you to continue",
        "done_fallback": "Ready to read",
        "home": "Home",
        "label_done": "Done",
        "label_permission": "Needs permission",
        "label_question": "Question",
        "label_agent": "Agent asks",
    },
    "es": {
        "permission_ask": "Pide permiso para usar **{tool}**",
        "permission_generic": "Pide tu permiso",
        "needs_fallback": "Te está esperando para seguir",
        "done_fallback": "Listo para leer",
        "home": "Inicio",
        "label_done": "Terminó",
        "label_permission": "Pide permiso",
        "label_question": "Pregunta",
        "label_agent": "Un agente pregunta",
    },
}


# ----------------------------------------------------------------------------- paths and config

def resolve_home(env=None, script_dir=None):
    """CCNOTIFY_HOME, else the install dir this script lives in (<home>/bin), else <claude config>/ccnotify."""
    env = os.environ if env is None else env
    if env.get("CCNOTIFY_HOME"):
        return os.path.expanduser(env["CCNOTIFY_HOME"])
    script_dir = script_dir or os.path.dirname(os.path.abspath(__file__))
    parent = os.path.dirname(script_dir)
    if os.path.basename(script_dir) == "bin" and os.path.isfile(os.path.join(parent, "config.example.json")):
        return parent
    claude_dir = env.get("CLAUDE_CONFIG_DIR") or "~/.claude"
    return os.path.join(os.path.expanduser(claude_dir), "ccnotify")


class Paths(object):
    def __init__(self, home):
        self.home = home
        self.config = os.path.join(home, "config.json")
        self.app = os.path.join(home, "CCNotify.app")
        self.state = os.path.join(home, "state")
        self.queue = os.path.join(self.state, "queue")
        self.sessions = os.path.join(self.state, "sessions")
        self.seen = os.path.join(self.state, "seen")
        self.ended = os.path.join(self.state, "ended")
        self.active = os.path.join(self.state, "active")
        self.lock = os.path.join(self.sessions, ".lock")
        self.log = os.path.join(self.state, "ccnotify.log")


WORKTREE_MARK = "/.claude/worktrees/"


def project_folder(cwd):
    """The project folder of a session folder: a Claude Code worktree (<project>/.claude/worktrees/<name>)
    stands for the project it belongs to. Trailing slashes are dropped."""
    trimmed = str(cwd or "").rstrip("/")
    cut = trimmed.find(WORKTREE_MARK)
    if cut >= 0:
        trimmed = trimmed[:cut]
    return trimmed.rstrip("/")


def display_name(folder, names=None):
    """The folder's own name, or the label the user gave it in `project_names` (bad entries are ignored).
    Kept in step with statusline/statusline.py and hooks/focus_session.py."""
    base = os.path.basename(folder)
    nick = names.get(base) if isinstance(names, dict) else None
    if isinstance(nick, str) and nick.strip():
        return nick.strip()
    return base


def _compatible(default, value):
    if isinstance(default, bool):
        return isinstance(value, bool)
    if isinstance(default, (int, float)):
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, type(default))


def merge_config(defaults, user):
    """Defaults overlaid with the user's config. A value of the wrong type falls back to the default."""
    result = copy.deepcopy(defaults)
    if not isinstance(user, dict):
        return result
    for key, value in user.items():
        if key not in defaults:
            result[key] = value
        elif isinstance(defaults[key], dict):
            if isinstance(value, dict):
                result[key] = merge_config(defaults[key], value) if defaults[key] else value
        elif _compatible(defaults[key], value):
            result[key] = value
    return result


def load_config(paths):
    try:
        with open(paths.config, encoding="utf-8") as f:
            user = json.load(f)
    except (OSError, ValueError):
        user = {}
    return merge_config(DEFAULT_CONFIG, user)


def detect_language(setting, run=subprocess.run):
    if setting in ("en", "es"):
        return setting
    try:
        out = run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True,
                  timeout=3).stdout
        match = re.search(r'[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*', out)
        if match and match.group(0).lower().startswith("es"):
            return "es"
    except (OSError, subprocess.SubprocessError):
        pass
    return "en"


# ----------------------------------------------------------------------------- filesystem helpers

def mkdir_private(path):
    if os.path.isdir(path):
        return
    os.mkdir(path, 0o700)
    os.chmod(path, 0o700)


def ensure_dirs(paths):
    os.makedirs(paths.home, exist_ok=True)
    for path in (paths.state, paths.queue, paths.sessions, paths.seen, paths.ended):
        mkdir_private(path)


def atomic_write(path, text):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.remove(tmp)
        raise


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def safe_name(value):
    """A session id as a file name: no separators, no dots-only names."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", value or "")[:128].lstrip(".")
    return cleaned or "unknown"


def log(paths, now, *fields):
    """One line per decision, append-only, rotated at 1 MB. Never message text."""
    try:
        with contextlib.suppress(OSError):
            if os.path.getsize(paths.log) >= LOG_MAX_BYTES:
                os.replace(paths.log, paths.log + ".1")
        line = " | ".join([time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))] + [str(x) for x in fields])
        fd = os.open(paths.log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def housekeeping(paths, now):
    """Drop queued popups older than 1 h and state files of long-gone sessions."""
    def sweep(folder, max_age, suffix=None):
        try:
            names = os.listdir(folder)
        except OSError:
            return
        for name in names:
            if name.startswith(".") or (suffix and not name.endswith(suffix)):
                continue
            path = os.path.join(folder, name)
            try:
                if now - os.path.getmtime(path) > max_age:
                    os.remove(path)
            except OSError:
                pass
    sweep(paths.queue, STALE_QUEUE_SECONDS, ".json")
    sweep(paths.sessions, STALE_STATE_SECONDS, ".json")
    sweep(paths.seen, STALE_STATE_SECONDS)
    sweep(paths.ended, STALE_STATE_SECONDS)


# ----------------------------------------------------------------------------- text helpers

def truncate(text, limit):
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0].rstrip(",.;:") + "…"


def one_line(text, limit=230):
    """Single plain line (menu bar summary, osascript notification)."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"[*_`#>|]", "", text)
    text = re.sub(r"^\s*(?:[-•]|\d+[.)])\s+", "", text, flags=re.M)
    text = re.sub(r"\s+", " ", text).strip().lstrip("-[ ")
    return truncate(text, limit)


def popup_text(text, limit=TEXT_CAP):
    """Markdown for the popup: kept as is, only whitespace tidied and capped at 20,000 characters."""
    text = re.sub(r"[ \t]+\n", "\n", text or "")
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return truncate(text, limit)


def tr(lang, key, **kwargs):
    return STRINGS.get(lang, STRINGS["en"])[key].format(**kwargs)


def format_permission(lang, tool, detail):
    if not tool:
        return tr(lang, "permission_generic")
    text = tr(lang, "permission_ask", tool=tool)
    if detail:
        # Fenced, so a * or _ in the command is not drawn as italics
        text += "\n```\n%s\n```" % detail.replace("```", "'''")
    return text


# ----------------------------------------------------------------------------- sounds and quiet hours

def _minutes(value, fallback):
    match = re.match(r"^\s*(\d{1,2}):(\d{2})\s*$", str(value))
    if not match:
        return fallback
    return (int(match.group(1)) % 24) * 60 + min(int(match.group(2)), 59)


def in_quiet_hours(config, now):
    quiet = config["quiet_hours"]
    if not quiet.get("enabled"):
        return False
    start, end = _minutes(quiet.get("from"), 22 * 60), _minutes(quiet.get("to"), 7 * 60)
    local = time.localtime(now)
    current = local.tm_hour * 60 + local.tm_min
    if start == end:
        return False
    if start < end:
        return start <= current < end
    return current >= start or current < end


def sound_settings(kind, config, now, turn_seconds=None):
    """(sound, volume, only_when_away) for a popup kind. sound "" = silent."""
    spec = config["sounds"].get(kind) or {}
    sound = spec.get("sound", "")
    sound = sound if isinstance(sound, str) else ""
    volume = spec.get("volume", 0.5)
    volume = min(1.0, max(0.0, float(volume))) if isinstance(volume, (int, float)) else 0.5
    if in_quiet_hours(config, now):
        sound = ""
    if kind == "done" and turn_seconds is not None:
        minimum = spec.get("min_turn_seconds", 15)
        if isinstance(minimum, (int, float)) and turn_seconds < minimum:
            sound = ""
    return sound, volume, bool(spec.get("only_when_away", False))


# ----------------------------------------------------------------------------- process detection

def _ps_field(run, pid, field):
    try:
        out = run(["ps", "-ww", "-o", field + "=", "-p", str(pid)], capture_output=True, text=True,
                  timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.strip()


def is_claude_process(comm, args=""):
    """Does this `ps` comm (and args) look like a Claude Code process?

    - an executable named `claude`;
    - a process that renamed itself, e.g. "claude bg-spare" (background sessions do);
    - the native install's versioned binary, e.g. ~/.local/share/claude/versions/2.1.0;
    - `node`/`bun` whose command line mentions claude (npm installs run Claude Code under node).
    """
    base = os.path.basename(comm)
    if base.split(" ", 1)[0] == "claude":
        return True
    if "/claude/versions/" in comm:
        return True
    return base in ("node", "bun") and "claude" in args.lower()


def find_claude_pid(run=subprocess.run, start_pid=None, max_depth=10):
    """PID of the Claude Code process running this hook (the session's own process), or 0.

    Walks up the parents and returns the first one that is Claude Code. It must be the session's own
    process, not a shared ancestor: background sessions all hang from one daemon, and taking the daemon
    would make every session look like the same process.
    """
    pid = os.getppid() if start_pid is None else start_pid
    for _ in range(max_depth):
        if pid <= 1:
            return 0
        comm = _ps_field(run, pid, "comm")
        base = os.path.basename(comm)
        if is_claude_process(comm, _ps_field(run, pid, "args") if base in ("node", "bun") else ""):
            return pid
        try:
            pid = int(_ps_field(run, pid, "ppid"))
        except ValueError:
            return 0
    return 0


# ----------------------------------------------------------------------------- session store

@contextlib.contextmanager
def sessions_lock(paths):
    fd = os.open(paths.lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def session_path(paths, sid):
    return os.path.join(paths.sessions, safe_name(sid) + ".json")


def read_session(paths, sid):
    return read_json(session_path(paths, sid))


def write_session(paths, sid, fields, event_at):
    """Merge `fields` into the session state under an exclusive lock.

    Returns False (and writes nothing) when the stored state is newer than this event (an async hook that
    finished late) or when the session already ended after this event.
    """
    with sessions_lock(paths):
        ended = read_json(os.path.join(paths.ended, safe_name(sid))).get("at", 0)
        if isinstance(ended, (int, float)) and event_at <= ended:
            return False
        data = read_session(paths, sid)
        stored = data.get("updated_at", 0)
        if isinstance(stored, (int, float)) and stored > event_at:
            return False
        data.update(fields)
        data.update(session=sid, updated_at=event_at)
        atomic_write(session_path(paths, sid), json.dumps(data, ensure_ascii=False))
        return True


def remove_session(paths, sid, event_at):
    with sessions_lock(paths):
        with contextlib.suppress(OSError):
            os.remove(session_path(paths, sid))
        with contextlib.suppress(OSError):
            os.remove(os.path.join(paths.seen, safe_name(sid)))
        atomic_write(os.path.join(paths.ended, safe_name(sid)), json.dumps({"at": event_at}))


def drop_sessions_of_pid(paths, pid, keep_sid, job=""):
    """/clear starts a new session inside the same Claude process: the previous one goes away.

    Only sessions of the same background job (or, for a normal session, of no job) are dropped, so a
    process shared by several sessions can never wipe its siblings.
    """
    with sessions_lock(paths):
        for name in os.listdir(paths.sessions):
            if not name.endswith(".json"):
                continue
            data = read_json(os.path.join(paths.sessions, name))
            focus = data.get("focus")
            other_job = focus.get("job", "") if isinstance(focus, dict) else ""
            if data.get("pid") == pid and data.get("session") != keep_sid and other_job == job:
                with contextlib.suppress(OSError):
                    os.remove(os.path.join(paths.sessions, name))


def mark_seen(paths, sid, now):
    atomic_write(os.path.join(paths.seen, safe_name(sid)), "%s\n" % now)


def job_by_name(jobs_dir, name):
    """Short id (the one `claude attach` takes) of the background session with that name, or "".

    The agent view announces "<name> needs your input" without the id; every background session keeps its
    name in <claude config>/jobs/<id>/state.json. If several share the name, the most recently updated wins.
    """
    best = ("", "")
    if not name:
        return ""
    try:
        ids = os.listdir(jobs_dir)
    except OSError:
        return ""
    for job in ids:
        if not JOB_ID.fullmatch(job):
            continue
        state = read_json(os.path.join(jobs_dir, job, "state.json"))
        if state.get("name") == name:
            updated = str(state.get("updatedAt") or "")
            if not best[0] or updated > best[1]:
                best = (job, updated)
    return best[0]


def session_of_job(paths, job, exclude_sid):
    """Id of the session that is the background job `job` itself, or "".

    The agent view speaks for a job but is a session of its own; the job's record is the one with that job id in
    its focus and a transcript that exists on disk. If several match, the most recently updated wins.
    """
    if not job:
        return ""
    best, best_at = "", -1.0
    try:
        names = os.listdir(paths.sessions)
    except OSError:
        return ""
    for name in names:
        if not name.endswith(".json"):
            continue
        data = read_json(os.path.join(paths.sessions, name))
        sid = data.get("session")
        sid = sid if isinstance(sid, str) and sid else name[:-len(".json")]
        focus = data.get("focus")
        if sid == exclude_sid or not isinstance(focus, dict) or focus.get("job") != job:
            continue
        transcript = data.get("transcript")
        if not isinstance(transcript, str) or not os.path.isfile(transcript):
            continue
        updated = data.get("updated_at", 0)
        updated = updated if isinstance(updated, (int, float)) else 0
        if updated > best_at:
            best, best_at = sid, updated
    return best


def recent_done_elsewhere(paths, question, own_sid, now, window=DEDUPE_WINDOW_SECONDS, job=""):
    """Does this agent_needs_input repeat a "done" that another session just announced?

    A background job announces its own Stop and, a second later, the session that launched it sends
    "<name> needs your input: <the same question>". That second popup would never close (you answer in the
    job, not in the launching session). Returns the other session's short id, or "".

    With `job` it is enough that this very job announced a "done" inside the window: the agent view rewords
    the question, so comparing the text alone misses it.
    """
    key = one_line(question, 2000).rstrip("…")[:80].strip()
    if len(key) < 4 and not job:
        return ""
    try:
        names = os.listdir(paths.sessions)
    except OSError:
        return ""
    for name in names:
        if not name.endswith(".json"):
            continue
        data = read_json(os.path.join(paths.sessions, name))
        if data.get("session") == own_sid:
            continue
        done_at = data.get("done_at", 0)
        if not isinstance(done_at, (int, float)) or now - done_at > window:
            continue
        focus = data.get("focus")
        same_job = bool(job) and isinstance(focus, dict) and focus.get("job") == job
        if same_job or (len(key) >= 4 and key in (data.get("done_text") or "")):
            return str(data.get("session", name))[:12]
    return ""


# ----------------------------------------------------------------------------- delivery

def fallback_notification(run, title, subtitle, message, sound):
    """macOS notification through osascript (no third-party tools). Arguments go through argv, never the script."""
    script = ["on run argv",
              "display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)"
              + (" sound name (item 4 of argv)" if sound else ""),
              "end run"]
    cmd = ["osascript"]
    for line in script:
        cmd += ["-e", line]
    cmd += [title, subtitle, message] + ([sound] if sound else [])
    try:
        return run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def deliver_popup(paths, run, popup, subtitle, short_text):
    """Queue the popup JSON and open the app; if the app is missing or fails, fall back to osascript."""
    if os.path.isdir(paths.app):
        queued = os.path.join(paths.queue, uuid.uuid4().hex + ".json")
        try:
            atomic_write(queued, json.dumps(popup, ensure_ascii=False))
            result = run(["open", "-n", "-g", paths.app, "--args", queued],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            if result.returncode == 0:
                return "popup"
        except (OSError, subprocess.SubprocessError):
            pass
        with contextlib.suppress(OSError):
            os.remove(queued)
    sound = popup.get("sound") or ""
    sound = "" if sound.startswith("/") else sound  # osascript only knows sound names
    fallback_notification(run, popup["title"], subtitle, short_text, sound)
    return "osascript"


# ----------------------------------------------------------------------------- the hook

class Hook(object):
    def __init__(self, home, env=None, now=None, run=subprocess.run):
        self.env = os.environ if env is None else env
        self.paths = Paths(home)
        self.config = load_config(self.paths)
        self.now = time.time() if now is None else now
        self.run = run
        self.lang = detect_language(self.config["language"], run)
        self._pid = None

    @property
    def claude_pid(self):
        if self._pid is None:  # computed once per hook run
            self._pid = find_claude_pid(self.run)
        return self._pid

    def project_name(self, cwd):
        folder = project_folder(cwd)
        if not folder:
            return "Claude"
        if os.path.realpath(folder) == os.path.realpath(os.path.expanduser("~")):
            return tr(self.lang, "home")  # do not show the macOS account name
        return display_name(folder, self.config.get("project_names")) or "Claude"

    def handle(self, event, payload):
        """Run one hook event; returns the decision string that was logged."""
        if event not in EVENTS:
            return "unknown-event"
        paths = self.paths
        ensure_dirs(paths)
        housekeeping(paths, self.now)
        cwd = payload.get("cwd") or self.env.get("PWD") or ""
        project = self.project_name(cwd)
        sid = payload.get("session_id") or project
        transcript_path = payload.get("transcript_path") or ""
        host = self.env.get("__CFBundleIdentifier") or DEFAULT_HOST
        private = bool(self.config["popup"]["private"])

        if event == "session-end":
            remove_session(paths, sid, self.now)
            return self.record(project, sid, event, "removed")

        focus = {"host": host, "cwd": cwd}
        pid = self.claude_pid
        if pid:
            focus["pid"] = pid
        # Background sessions (`claude --bg`) have no terminal of their own: they are children of the main
        # session. Their short id (the name of CLAUDE_JOB_DIR) lets the extension run `claude attach <id>`.
        job = os.path.basename(str(self.env.get("CLAUDE_JOB_DIR", "")).rstrip("/"))
        if JOB_ID.fullmatch(job or ""):
            focus["job"] = job
        base = {"project": project, "cwd": cwd, "transcript": transcript_path, "host": host,
                "focus": focus, "pid": pid}

        if event == "session-start":
            if pid:
                drop_sessions_of_pid(paths, pid, sid, focus.get("job", ""))
            # No row yet: a session that is never used (or the agent view itself) would only clutter the menu.
            # The first prompt, stop or own notification creates it.
            return self.record(project, sid, event, "no row")

        if event == "prompt":
            request = "" if private else one_line(payload.get("prompt") or "", 160)
            write_session(paths, sid, dict(base, state="thinking", since=self.now, tasks=0, request=request,
                                           turn_started_at=self.now), self.now)
            mark_seen(paths, sid, self.now)  # you are in the conversation: nothing pending is unseen
            return self.record(project, sid, event, "thinking")

        if event == "notification":
            return self.on_notification(payload, project, sid, base)
        return self.on_stop(payload, project, sid, base)

    def record(self, project, sid, event, decision):
        log(self.paths, self.now, project, sid[:12], event, decision)
        return decision

    # -- notification -------------------------------------------------------

    def on_notification(self, payload, project, sid, base):
        kind = transcript_parser.classify_notification(payload)
        ntype = payload.get("notification_type") or "untyped"
        if kind is None:
            if transcript_parser.is_idle_notification(payload):
                return self.on_idle(project, sid, base)
            return self.record(project, sid, "notification", "%s ignored" % ntype)
        message = payload.get("message") or ""
        agent = ""
        if kind == "permission":
            tool, detail = transcript_parser.permission_request(payload)
            text = format_permission(self.lang, tool, detail)
        elif kind == "agent":
            agent, question = transcript_parser.split_agent_question(message)
            # The agent view speaks for a background session: the click must open that session, not the
            # agent view that relayed the question.
            jobs_dir = os.path.join(os.path.expanduser(self.env.get("CLAUDE_CONFIG_DIR") or "~/.claude"), "jobs")
            job = job_by_name(jobs_dir, agent)
            if job:
                base = dict(base, focus=dict(base["focus"], job=job))
            other = recent_done_elsewhere(self.paths, question, sid, self.now, job=job)
            if other:
                return self.record(project, sid, "notification", "%s duplicate of %s" % (ntype, other))
            text = question
        else:
            text = message
        text = text.strip() or tr(self.lang, "needs_fallback")
        summary = "" if self.config["popup"]["private"] else one_line(text.replace("```", " "), 160)
        shown_sid = sid
        if kind == "agent":
            # One row per conversation: the agent view never gets a row of its own (nothing would ever clear
            # it). The question goes onto the job's own row, if it has one.
            target = session_of_job(self.paths, job, sid)
            if target:
                if not write_session(self.paths, target, {"state": "needs", "since": self.now, "summary": summary},
                                     self.now):
                    return self.record(project, sid, "notification", "%s superseded" % ntype)
                shown_sid = target  # closing the popup marks the job's row as seen
        elif not write_session(self.paths, sid, dict(base, state="needs", since=self.now, summary=summary),
                               self.now):
            return self.record(project, sid, "notification", "%s superseded" % ntype)
        title = "%s · %s" % (project, agent) if agent else project
        return self.show(kind, title, text, project, shown_sid, base, "notification", ntype)

    def on_idle(self, project, sid, base):
        """Claude went idle but the row still says "thinking": its Stop hook never arrived. Repair the row.

        No popup and no sound: this is bookkeeping, not news. Anything else (row not "thinking", background
        tasks still running) is ignored as before.
        """
        transcript_path = base["transcript"]
        record = read_session(self.paths, sid)
        if record.get("state") != "thinking" or (
                transcript_path and transcript_parser.running_background_tasks(transcript_path, self.now)):
            return self.record(project, sid, "notification", "idle_prompt ignored")
        since = record.get("since")
        if isinstance(since, (int, float)) and transcript_parser.assistant_entry_after(transcript_path, since):
            text = transcript_parser.last_assistant_text(transcript_path)
            summary = "" if self.config["popup"]["private"] else one_line(text, 160)
            if not write_session(self.paths, sid, {"state": "wrote", "since": self.now, "tasks": 0,
                                                   "summary": summary}, self.now):
                return self.record(project, sid, "notification", "idle_prompt superseded")
            return self.record(project, sid, "notification", "idle_prompt fixed: answered without a stop")
        if not write_session(self.paths, sid, {"state": "wrote", "tasks": 0}, self.now):
            return self.record(project, sid, "notification", "idle_prompt superseded")
        mark_seen(self.paths, sid, self.now)  # nothing was written: nothing unread
        return self.record(project, sid, "notification", "idle_prompt fixed: no answer")

    # -- stop ---------------------------------------------------------------

    def on_stop(self, payload, project, sid, base):
        transcript_path = base["transcript"]
        text = payload.get("last_assistant_message") or ""
        if not text and transcript_path:
            text = transcript_parser.last_assistant_text(transcript_path)
        summary = "" if self.config["popup"]["private"] else one_line(text, 160)
        pending = transcript_parser.running_background_tasks(transcript_path, self.now) if transcript_path else 0
        if pending:
            write_session(self.paths, sid, dict(base, state="thinking", since=self.now, tasks=pending,
                                                summary=summary), self.now)
            return self.record(project, sid, "stop", "%d background task(s), no popup" % pending)
        previous = read_session(self.paths, sid)
        started = previous.get("turn_started_at")
        turn_seconds = self.now - started if isinstance(started, (int, float)) else None
        done_text = "" if self.config["popup"]["private"] else one_line(text, 2000)
        written = write_session(self.paths, sid, dict(base, state="wrote", since=self.now, tasks=0,
                                                      summary=summary, done_text=done_text, done_at=self.now),
                                self.now)
        if not written:
            return self.record(project, sid, "stop", "superseded")
        if transcript_path and transcript_parser.was_interrupted(transcript_path):
            mark_seen(self.paths, sid, self.now)  # you stopped it yourself: nothing unread
            return self.record(project, sid, "stop", "interrupted, no popup")
        text = text.strip() or tr(self.lang, "done_fallback")
        return self.show("done", project, text, project, sid, base, "stop",
                         payload.get("stop_reason") or "-", turn_seconds)

    # -- popup --------------------------------------------------------------

    def show(self, kind, title, text, project, sid, base, event, detail, turn_seconds=None):
        config = self.config
        if not config["events"].get(kind, True):
            return self.record(project, sid, event, "%s disabled in config" % kind)
        if not config["popup"]["enabled"]:
            return self.record(project, sid, event, "%s popups disabled in config" % kind)
        sound, volume, only_when_away = sound_settings(kind, config, self.now, turn_seconds)
        transcript_path = base["transcript"]
        try:
            size = os.path.getsize(transcript_path) if transcript_path else 0
        except OSError:
            size = 0
        private = bool(config["popup"]["private"])
        popup_cfg = config["popup"]
        popup = {
            "title": title, "kind": kind, "text": "" if private else popup_text(text),
            "id": sid[:12], "session": sid, "host": base["host"], "focus": base["focus"],
            "transcript": transcript_path, "transcript_size": size, "event_at": self.now,
            "language": self.lang, "sound": sound, "volume": volume, "only_when_away": only_when_away,
            "seconds": popup_cfg["seconds"], "width": popup_cfg["width"],
            "max_height_ratio": popup_cfg["max_height_ratio"], "max_stacked": popup_cfg["max_stacked"],
            "sticky_needs_you": popup_cfg["sticky_needs_you"], "font_size": popup_cfg["font_size"],
            "private": private,
            "style": popup_cfg["style"] if popup_cfg["style"] in ("color", "neutral", "mono") else "color",
            "compact_lines": popup_cfg["compact_lines"],
        }
        subtitle = tr(self.lang, "label_" + kind)
        short = subtitle if private else (one_line(text.replace("```", " ")) or subtitle)
        how = deliver_popup(self.paths, self.run, popup, subtitle, short)
        return self.record(project, sid, event, "%s %s %s%s" % (kind, how, detail,
                                                                 "" if sound else " (silent)"))


def main(argv=None, stdin=None, env=None, run=subprocess.run, now=None):
    argv = sys.argv[1:] if argv is None else argv
    event = argv[0] if argv else "stop"
    try:
        raw = (sys.stdin if stdin is None else stdin).read()
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            payload = {}
    except (ValueError, OSError):
        payload = {}
    env = os.environ if env is None else env
    try:
        hook = Hook(resolve_home(env), env=env, now=now, run=run)
        hook.handle(event, payload)
    except Exception as exc:  # never get in Claude Code's way
        try:
            log(Paths(resolve_home(env)), time.time() if now is None else now, "-", "-", event,
                "error %s" % type(exc).__name__)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
