// CCNotify Focus Terminal: minimal VS Code extension (also works in Insiders, VSCodium, Cursor, Windsurf).
//
// Every editor window runs its own copy and watches a request file:
//   <CCNOTIFY_HOME>/state/focus-request.json
//   -> {"at": <epoch seconds>, "pids": [<pid>, ...], "job"?: "<id>", "cwd"?: "...", "claude"?: "<path>",
//       "project"?: "<name for the terminal tab>"}
// written by hooks/focus_session.py when you click a popup or a menu bar item; "pids" is the Claude Code
// process and its parents. The window that owns a terminal whose shell is in that list handles it:
//   - Normal session: shows that terminal (opens the panel if it was closed and gives it focus).
//   - Background session ("job", started with `claude --bg`): it has no terminal of its own (it is a child of
//     the main session), so the window shows the terminal that is running `claude attach <job>` right now or,
//     if there is none, opens a new one that runs it. It never types into the main session's terminal.
//     A terminal is never reused by its name: pressing ← inside `claude attach` turns it into the agent view,
//     where you can open any other conversation, while the tab keeps its old name. So every click asks `ps`
//     what each terminal is running. Terminals that moved on are left alone: you may be using them.
//   - In both cases it raises its own window by asking macOS to open its own workspace/folder with its own
//     editor app (if the window already has it, the editor just focuses it: no new window).
// Requests older than 10 s are ignored, so opening the editor never jumps to a stale terminal.
const vscode = require("vscode");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFile } = require("child_process");

// vscode.env.uriScheme -> bundle id of the editor application
const BUNDLE_IDS = {
  vscode: "com.microsoft.VSCode",
  "vscode-insiders": "com.microsoft.VSCodeInsiders",
  vscodium: "com.vscodium",
  cursor: "com.todesktop.230313mzl4w4u92",
  windsurf: "com.exafunction.windsurf",
};
const MAX_AGE_SECONDS = 10;
const JOB_ID = /^[A-Za-z0-9_-]{4,40}$/;
const WORKTREE_MARK = "/.claude/worktrees/";

/** Name for a terminal tab: the project name CCNotify computed (request.project), else the name of the
 *  project folder of request.cwd (a Claude Code worktree stands for the project it belongs to). */
function projectName(request) {
  const given = request && typeof request.project === "string"
    ? request.project.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim().slice(0, 60).trim() : "";
  if (given) return given;
  let folder = request && request.cwd ? String(request.cwd).replace(/\/+$/, "") : "";
  const cut = folder.indexOf(WORKTREE_MARK);
  if (cut >= 0) folder = folder.slice(0, cut).replace(/\/+$/, "");
  if (!folder || folder === os.homedir()) return "Claude"; // never show the macOS account name
  return path.basename(folder) || "Claude";
}

function requestFiles() {
  const homes = [];
  if (process.env.CCNOTIFY_HOME) homes.push(process.env.CCNOTIFY_HOME);
  homes.push(path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude"), "ccnotify"));
  return Array.from(new Set(homes)).map((home) => path.join(home, "state", "focus-request.json"));
}

/** pid -> {ppid, command} of every process right now (empty if `ps` fails). */
function processTable() {
  return new Promise((resolve) => {
    execFile("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="], { timeout: 3000, maxBuffer: 8 * 1024 * 1024 },
      (error, stdout) => {
        const table = new Map();
        if (!error) {
          for (const line of String(stdout).split("\n")) {
            const match = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
            if (match) table.set(Number(match[1]), { ppid: Number(match[2]), command: match[3].trim() });
          }
        }
        resolve(table);
      });
  });
}

/** Is this terminal (its own process, or a command started from its shell) running `claude attach <job>` now? */
function isAttachedTo(table, pid, job) {
  const attached = new RegExp(`(^|\\s)attach\\s+${job}$`); // `job` matched JOB_ID: no regex metacharacters
  const own = table.get(pid);
  if (own && attached.test(own.command)) return true;
  for (const entry of table.values()) {
    if (entry.ppid === pid && attached.test(entry.command)) return true;
  }
  return false;
}

function activate(context) {
  const bundleId = BUNDLE_IDS[vscode.env.uriScheme];
  let handled = 0;

  function ownWindowTarget() {
    const workspaceFile = vscode.workspace.workspaceFile;
    if (workspaceFile && workspaceFile.scheme === "file") return workspaceFile.fsPath;
    const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
    if (folder && folder.uri.scheme === "file") return folder.uri.fsPath;
    return null;
  }

  async function processIdOf(terminal) {
    try {
      return await terminal.processId;
    } catch (e) {
      return undefined;
    }
  }

  /** The terminal that is attached to the job right now, or a new one running `claude attach <job>`. */
  async function terminalForJob(request) {
    const job = String(request.job);
    const table = await processTable();
    for (const candidate of vscode.window.terminals) {
      if (candidate.exitStatus !== undefined) continue;
      const pid = await processIdOf(candidate);
      if (pid && isAttachedTo(table, pid, job)) return candidate;
    }
    const tag = `(${job})`;
    const cwd = request.cwd && fs.existsSync(String(request.cwd)) ? String(request.cwd) : undefined;
    const name = `${projectName(request)} ${tag}`;
    const iconPath = new vscode.ThemeIcon("comment-discussion");
    const claude = typeof request.claude === "string" ? request.claude : "";
    let terminal;
    if (claude && path.isAbsolute(claude) && fs.existsSync(claude)) {
      // The terminal runs `claude attach` itself: it closes when you leave the session.
      terminal = vscode.window.createTerminal({ name, shellPath: claude, shellArgs: ["attach", job], cwd, iconPath });
    } else {
      // claude is not in a known place: let the user's own shell (with its full PATH) find it.
      // The text goes to this new terminal only, and `job` matched JOB_ID, so it is a plain word.
      terminal = vscode.window.createTerminal({ name, cwd, iconPath });
      terminal.sendText(`claude attach ${job}`, true);
    }
    return terminal;
  }

  async function check(file) {
    let request;
    try {
      request = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
      return;
    }
    const at = Number(request && request.at) || 0;
    if (at <= handled || Date.now() / 1000 - at > MAX_AGE_SECONDS) return;
    handled = at;
    const pids = new Set((request.pids || []).map(Number));
    let owner;
    for (const terminal of vscode.window.terminals) {
      const pid = await processIdOf(terminal);
      if (pid && pids.has(pid)) {
        owner = terminal;
        break;
      }
    }
    if (!owner) return; // the session doesn't run in this window: another copy of the extension handles it
    if (request.job && JOB_ID.test(String(request.job))) {
      (await terminalForJob(request)).show(false);
    } else {
      owner.show(false);
    }
    const target = ownWindowTarget();
    if (bundleId && target) {
      execFile("/usr/bin/open", ["-b", bundleId, target], () => {});
    }
  }

  // watchFile (polls every 0.3 s) rather than fs.watch: it survives the file being replaced atomically.
  for (const file of requestFiles()) {
    fs.watchFile(file, { interval: 300 }, () => { check(file); });
    context.subscriptions.push({ dispose: () => fs.unwatchFile(file) });
  }
}

function deactivate() {}

module.exports = { activate, deactivate, processTable, isAttachedTo, projectName };
