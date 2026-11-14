#!/usr/bin/env python3
"""Bring forward the editor window where a Claude Code session runs.

    focus_session.py --host <bundle-id> --cwd <session folder> [--pid <claude pid>]

Two steps:

1. With a PID, leave a request in state/focus-request.json (`{"at": <epoch>, "pids": [<claude pid>, its
   parents...]}`, written atomically). The CCNotify "Focus Terminal" extension, running in every window of
   VS Code and its forks, looks for the terminal whose shell is in that list, shows it and raises its window.
2. Ask macOS to open the most specific folder the editor already has open that contains `cwd`
   (`open -b <host> <folder>`): if a window already has it, the editor just focuses it, no new window.
   If no open folder matches (e.g. a window without a folder) or the host is another app (Terminal, iTerm2...),
   the app is simply brought to the front (`open -b <host>`).

Never runs a shell string; every command is an argv list. Python 3.9+, standard library only.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from urllib.parse import unquote, urlparse

DEFAULT_HOST = "com.microsoft.VSCode"

# bundle id -> folder name under ~/Library/Application Support
EDITOR_SUPPORT_DIRS = {
    "com.microsoft.VSCode": "Code",
    "com.microsoft.VSCodeInsiders": "Code - Insiders",
    "com.vscodium": "VSCodium",
    "com.todesktop.230313mzl4w4u92": "Cursor",
    "com.exafunction.windsurf": "Windsurf",
}


def resolve_home(env=None, script_dir=None):
    env = os.environ if env is None else env
    if env.get("CCNOTIFY_HOME"):
        return os.path.expanduser(env["CCNOTIFY_HOME"])
    script_dir = script_dir or os.path.dirname(os.path.abspath(__file__))
    parent = os.path.dirname(script_dir)
    if os.path.basename(script_dir) == "bin" and os.path.isfile(os.path.join(parent, "config.example.json")):
        return parent
    claude_dir = env.get("CLAUDE_CONFIG_DIR") or "~/.claude"
    return os.path.join(os.path.expanduser(claude_dir), "ccnotify")


def storage_path(host, env=None):
    """The editor's own storage.json (it lists the folders open in each window)."""
    env = os.environ if env is None else env
    folder = EDITOR_SUPPORT_DIRS.get(host)
    if not folder:
        return None
    base = env.get("CCNOTIFY_APP_SUPPORT") or os.path.expanduser("~/Library/Application Support")
    return os.path.join(base, folder, "User", "globalStorage", "storage.json")


def process_chain(pid, run=subprocess.run, limit=15):
    """The process and all its parents (the shell of the editor's terminal is among them)."""
    pids = []
    while pid > 1 and len(pids) < limit:
        pids.append(pid)
        try:
            out = run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True,
                      timeout=2).stdout.strip()
            pid = int(out)
        except (OSError, ValueError, subprocess.SubprocessError):
            break
    return pids


def request_terminal(home, pid, run=subprocess.run, now=None):
    """Atomically write state/focus-request.json for the editor extension."""
    pids = process_chain(pid, run)
    if not pids:
        return False
    state = os.path.join(home, "state")
    target = os.path.join(state, "focus-request.json")
    tmp = "%s.%d.tmp" % (target, os.getpid())
    try:
        os.makedirs(state, mode=0o700, exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"at": time.time() if now is None else now, "pids": pids}, f)
        os.replace(tmp, target)
        return True
    except OSError:
        return False


def open_folders(path):
    """Folders the editor has open in its windows, according to its own storage.json."""
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as f:
            windows = json.load(f).get("windowsState", {})
    except (OSError, ValueError, AttributeError):
        return []
    if not isinstance(windows, dict):
        return []
    entries = [windows.get("lastActiveWindow") or {}] + list(windows.get("openedWindows") or [])
    folders = []
    for entry in entries:
        uri = entry.get("folder") if isinstance(entry, dict) else None
        if isinstance(uri, str) and uri.startswith("file://"):
            folders.append(unquote(urlparse(uri).path).rstrip("/"))
    return folders


def most_specific_folder(folders, cwd):
    """The open folder that contains `cwd`, the deepest one if several do; None if none does."""
    cwd = cwd.rstrip("/")
    candidates = [f for f in folders if f and (cwd == f or cwd.startswith(f + "/"))]
    return max(candidates, key=len) if candidates else None


def focus(host, cwd, pid=0, home=None, env=None, run=subprocess.run):
    """Do both steps. Returns the `open` argv that was run (for tests and logs)."""
    env = os.environ if env is None else env
    host = host or DEFAULT_HOST
    family = host in EDITOR_SUPPORT_DIRS
    if pid and family:
        request_terminal(home or resolve_home(env), pid, run)
    command = ["open", "-b", host]
    if family:
        folder = most_specific_folder(open_folders(storage_path(host, env)), cwd or "")
        if folder:
            command.append(folder)
    try:
        run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass
    return command


def main(argv=None):
    parser = argparse.ArgumentParser(description="Bring forward the editor window running a Claude Code session.")
    parser.add_argument("--host", default=DEFAULT_HOST, help="bundle id of the app hosting the session")
    parser.add_argument("--cwd", default="", help="working folder of the session")
    parser.add_argument("--pid", type=int, default=0, help="PID of the Claude Code process")
    args = parser.parse_args(argv)
    focus(args.host, args.cwd, args.pid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
