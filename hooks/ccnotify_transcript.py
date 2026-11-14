"""Everything in CCNotify that depends on undocumented Claude Code formats.

Transcript JSONL layout, the wording of notification messages and the text of background-task results can
change between Claude Code releases. All of that parsing lives here, in one place, with unit tests on small
sample transcripts (tests/fixtures/). Every function is defensive: bad input returns an empty / neutral value,
never raises.

Documented hook fields (`notification_type`, `last_assistant_message`, ...) are preferred by notify.py;
this module is the fallback and the home of the fragile heuristics.
Python 3.9+, standard library only.
"""
import calendar
import json
import os
import re
import time

# Tool results that mean "work was started in the background". Background Bash commands (a dev server, say)
# are deliberately not listed: they can stay alive for hours and must not silence the "done" popup.
BACKGROUND_LAUNCH_MARKERS = ("Async agent launched", "Workflow launched in background")
INTERRUPT_PREFIX = "[Request interrupted by user"

_PERMISSION_RE = re.compile(r"^Claude needs your permission to use (.+)$", re.S)
_AGENT_INPUT_RE = re.compile(r"^(.+?) needs your input:\s*(.*)$", re.S)
_TASK_DONE_RE = re.compile(r"<tool-use-id>(toolu_\w+)</tool-use-id>")
_AGENT_ID_RE = re.compile(r"agentId: (\w+)")
_TRANSCRIPT_DIR_RE = re.compile(r"Transcript dir: (\S+)")

# Keys of a tool's input that best describe what it is about to do, most useful first.
_DETAIL_KEYS = ("description", "command", "file_path", "url", "pattern", "prompt")


# ----------------------------------------------------------------------------- reading

def read_tail_lines(path, max_bytes):
    """Last `max_bytes` of a (possibly huge) JSONL file as a list of lines. A partial first line is dropped."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            start = max(0, size - max_bytes)
            f.seek(start)
            data = f.read()
    except (OSError, TypeError, ValueError):
        return []
    lines = data.decode("utf-8", "ignore").splitlines()
    if start > 0 and lines:
        lines = lines[1:]
    return lines


def _loads(line):
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    return entry if isinstance(entry, dict) else None


def content_text(content):
    """Plain text of a message `content` that may be a string or a list of blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and isinstance(block.get("text"), str):
                parts.append(block["text"])
        return " ".join(parts)
    return ""


def last_assistant_text(path, max_bytes=400_000):
    """Fallback when the hook payload has no `last_assistant_message`: the newest assistant text block."""
    for line in reversed(read_tail_lines(path, max_bytes)):
        entry = _loads(line)
        if not entry or entry.get("type") != "assistant":
            continue
        message = entry.get("message")
        blocks = message.get("content") if isinstance(message, dict) else None
        if not isinstance(blocks, list):
            continue
        text = "\n".join(b.get("text", "") for b in blocks
                         if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
        if text.strip():
            return text
    return ""


def was_interrupted(path, max_bytes=200_000):
    """True when the newest conversation entry is the user's interrupt marker (the turn was cut by the user)."""
    for line in reversed(read_tail_lines(path, max_bytes)):
        entry = _loads(line)
        if not entry or entry.get("type") not in ("user", "assistant") or entry.get("isSidechain"):
            continue
        if entry.get("type") != "user":
            return False
        message = entry.get("message")
        text = content_text(message.get("content") if isinstance(message, dict) else "")
        return text.strip().startswith(INTERRUPT_PREFIX)
    return False


# ----------------------------------------------------------------------------- background work

def _latest_signal(path):
    """Newest write time of an agent transcript file, or of anything inside a workflow directory."""
    try:
        if os.path.isdir(path):
            with os.scandir(path) as it:
                return max((e.stat().st_mtime for e in it), default=None)
        return os.path.getmtime(path)
    except OSError:
        return None


def _parse_timestamp(value):
    try:
        return calendar.timegm(time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return None


def running_background_tasks(transcript, now=None, max_silence=15 * 60, tail_mb=25):
    """Number of background agents/workflows launched in this session that are still working.

    A task is finished when its `<task-notification>` (which carries the tool-use id) shows up. It counts as
    alive when its own transcript was written less than `max_silence` seconds ago (or, without one, when it was
    launched less than that long ago), so a task lost without a trace (restarted session) cannot silence the
    popups forever. Only the tail of the transcript is read: they can be hundreds of MB and hooks have 10 s.
    """
    if not transcript:
        return 0
    now = time.time() if now is None else now
    session_dir = transcript[:-len(".jsonl")] if transcript.endswith(".jsonl") else transcript
    launched, finished = {}, set()
    for line in read_tail_lines(transcript, tail_mb * 1_000_000):
        if "<task-notification>" in line:
            finished.update(_TASK_DONE_RE.findall(line))
        if not any(marker in line for marker in BACKGROUND_LAUNCH_MARKERS):
            continue
        entry = _loads(line)
        message = entry.get("message") if entry else None
        blocks = message.get("content") if isinstance(message, dict) else None
        if not isinstance(blocks, list):
            continue
        for block in blocks:
            if not (isinstance(block, dict) and block.get("type") == "tool_result"):
                continue
            text = content_text(block.get("content"))
            if not text.startswith(BACKGROUND_LAUNCH_MARKERS):
                continue
            agent = _AGENT_ID_RE.search(text)
            folder = _TRANSCRIPT_DIR_RE.search(text)
            if agent:
                signal = os.path.join(session_dir, "subagents", "agent-%s.jsonl" % agent.group(1))
            else:
                signal = folder.group(1) if folder else ""
            launched[block.get("tool_use_id")] = (signal, entry.get("timestamp", ""))
    alive = 0
    for tool_use_id, (signal, started) in launched.items():
        if tool_use_id in finished:
            continue
        last = _latest_signal(signal) if signal else None
        if last is None:
            last = _parse_timestamp(started)
            if last is None:
                continue
        if now - last < max_silence:
            alive += 1
    return alive


# ----------------------------------------------------------------------------- notifications

def classify_notification(payload):
    """Popup kind for a Notification hook payload, or None when it should be ignored.

    permission_prompt -> permission, elicitation_* -> question, agent_needs_input -> agent.
    Everything else (idle_prompt, auth_success, quotas...) is ignored. Without `notification_type`
    (older Claude Code) only the permission wording is recognised.
    """
    ntype = payload.get("notification_type") or ""
    if ntype:
        if ntype == "permission_prompt":
            return "permission"
        if ntype.startswith("elicitation_"):
            return "question"
        if ntype == "agent_needs_input":
            return "agent"
        return None
    message = payload.get("message") or ""
    if isinstance(message, str) and message.startswith("Claude needs your permission"):
        return "permission"
    return None


def permission_request(payload):
    """(tool, detail) for a permission prompt. `tool` is "" when nothing could be extracted."""
    data = payload.get("notification_data")
    data = data if isinstance(data, dict) else {}
    tool = data.get("tool_name") or ""
    tool_input = data.get("tool_input")
    detail = ""
    if isinstance(tool_input, dict):
        for key in _DETAIL_KEYS:
            if tool_input.get(key):
                detail = str(tool_input[key])
                break
    if not tool:
        match = _PERMISSION_RE.match(payload.get("message") or "")
        if match:
            tool = match.group(1).strip()
    if tool.startswith("mcp__"):
        tool = tool.split("__")[-1]  # mcp__server__action -> action
    return tool, detail


def split_agent_question(message):
    """'name needs your input: question' -> ('name', 'question'). Without that shape: ('', message)."""
    message = message or ""
    match = _AGENT_INPUT_RE.match(message)
    if match:
        return match.group(1).strip(), match.group(2)
    return "", message
