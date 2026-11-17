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
//
// 1.3.0: newer Claude Code versions host sessions under a background daemon, so the pid chain in the request is
// [session, pty host, daemon] with no terminal shell in it, and the conversation is browsed in the agent view
// (`claude agents`) inside some terminal. No window finds an "owner" terminal then, and a click used to do nothing.
// Now, if the request has a valid "job" and nobody owns it, ONE window handles it, chosen by priority: 1 it already
// has a terminal running `claude attach <job>`; 2 it has a terminal running the agent view; 3 one of its folders
// contains the session's project folder (a worktree counts as its project); 4 any window. Windows cannot talk to
// each other, so each waits priority x 600 ms and then "claims" the request by creating, atomically
// (open flag "wx"), <state dir>/focus-<at>.claim next to the request file: only the first one succeeds and acts,
// the others stop. The owner window (priority 0) claims at once. Any other error creating the file counts as
// success (better to act than to lose the click). Claim files older than 60 s are removed on each claim.
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
const AGENTS_VIEW = /(^|\s|\/)claude\s+agents(\s|$)/;
const PRIORITY_STEP_MS = 600;
const CLAIM_MAX_AGE_MS = 60000;

/** Name for a terminal tab: the project name CCNotify computed (request.project), else the name of the
 *  project folder of request.cwd (a Claude Code worktree stands for the project it belongs to). */
function projectName(request) {
  const given = request && typeof request.project === "string"
    ? request.project.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim().slice(0, 60).trim() : "";
  if (given) return given;
  const folder = projectFolder(request && request.cwd);
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

/** The commands of a process and of all its descendants (a terminal runs a shell; claude runs inside it). */
function commandsUnder(table, pid) {
  const children = new Map();
  for (const [child, entry] of table) {
    if (!children.has(entry.ppid)) children.set(entry.ppid, []);
    children.get(entry.ppid).push(child);
  }
  const commands = [];
  const pending = [Number(pid)];
  const seen = new Set();
  while (pending.length && commands.length < 200) {
    const current = pending.pop();
    if (seen.has(current)) continue;
    seen.add(current);
    const entry = table.get(current);
    if (entry) commands.push(entry.command);
    for (const child of children.get(current) || []) pending.push(child);
  }
  return commands;
}

/** Is this terminal (its own process, or a command started from its shell) running `claude attach <job>` now? */
function isAttachedTo(table, pid, job) {
  const attached = new RegExp(`(^|\\s)attach\\s+${job}$`); // `job` matched JOB_ID: no regex metacharacters
  return commandsUnder(table, pid).some((command) => attached.test(command));
}

/** Is this command the agent view (`claude agents`)? Not `claude attach x`, not `claude agentsx`. */
function isAgentsView(command) {
  return AGENTS_VIEW.test(String(command));
}

/** The project folder of a session: a Claude Code worktree (<project>/.claude/worktrees/<x>) stands for its project. */
function projectFolder(cwd) {
  let folder = String(cwd || "").replace(/\/+$/, "");
  const cut = folder.indexOf(WORKTREE_MARK);
  if (cut >= 0) folder = folder.slice(0, cut).replace(/\/+$/, "");
  return folder;
}

/** Does `folder` contain `target`? (equal, or target starts with folder + "/"; never for an empty path) */
function folderContains(folder, target) {
  const a = String(folder || "").replace(/\/+$/, "");
  const b = String(target || "").replace(/\/+$/, "");
  return !!a && !!b && (b === a || b.startsWith(a + "/"));
}

/** Priority of a window with no owner terminal (lower acts first): 1 has the conversation open, 2 shows the agent
 *  view, 3 has the project open, 4 anything else. */
function priority({ hasAttach, hasAgentsView, hasProject }) {
  if (hasAttach) return 1;
  if (hasAgentsView) return 2;
  if (hasProject) return 3;
  return 4;
}

function waitMs(p) {
  return p * PRIORITY_STEP_MS;
}

function claimPath(dir, at) {
  return path.join(dir, `focus-${String(at).replace(/[^0-9.]/g, "")}.claim`);
}

/** Best effort: remove claim files older than 60 s. */
function cleanClaims(dir, nowMs) {
  try {
    for (const name of fs.readdirSync(dir)) {
      if (!/^focus-[0-9.]*\.claim$/.test(name)) continue;
      const file = path.join(dir, name);
      try {
        if (nowMs - fs.statSync(file).mtimeMs > CLAIM_MAX_AGE_MS) fs.unlinkSync(file);
      } catch (e) { /* another window removed it */ }
    }
  } catch (e) { /* unreadable folder */ }
}

/** Claim a request by creating a file atomically: only the first window succeeds. EEXIST = lost; any other error
 *  (disk, permissions) = proceed, better to act than to lose the click. */
function claimRequest(dir, at, nowMs) {
  cleanClaims(dir, nowMs === undefined ? Date.now() : nowMs);
  try {
    fs.closeSync(fs.openSync(claimPath(dir, at), "wx"));
    return true;
  } catch (e) {
    return !(e && e.code === "EEXIST");
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

  /** Raise this window: open its own workspace/folder with its own editor app. Without a folder there is no way to
   *  point at this window, so the editor app is just activated. */
  function raiseWindow() {
    if (!bundleId) return;
    const target = ownWindowTarget();
    execFile("/usr/bin/open", target ? ["-b", bundleId, target] : ["-b", bundleId], () => {});
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
    const dir = path.dirname(file);
    const job = request.job && JOB_ID.test(String(request.job)) ? String(request.job) : "";

    if (owner) {
      if (!claimRequest(dir, request.at)) return; // priority 0: the owner claims at once
      if (job) {
        (await terminalForJob(request)).show(false);
      } else {
        owner.show(false);
      }
      raiseWindow();
      return;
    }
    if (!job) return; // a normal session runs in another window: that copy of the extension handles it

    // Nobody owns it (session hosted by the background daemon): every window computes its priority, waits and claims.
    const table = await processTable();
    let hasAttach = false;
    let hasAgentsView = false;
    for (const terminal of vscode.window.terminals) {
      if (terminal.exitStatus !== undefined) continue;
      const pid = await processIdOf(terminal);
      if (!pid) continue;
      if (isAttachedTo(table, pid, job)) hasAttach = true;
      if (commandsUnder(table, pid).some(isAgentsView)) hasAgentsView = true;
    }
    const project = projectFolder(request.cwd);
    const home = os.homedir();
    const hasProject = (vscode.workspace.workspaceFolders || []).some((folder) =>
      folder.uri.scheme === "file" && folder.uri.fsPath !== home && folderContains(folder.uri.fsPath, project));
    await sleep(waitMs(priority({ hasAttach, hasAgentsView, hasProject })));
    if (!claimRequest(dir, request.at)) return; // another window got there first
    (await terminalForJob(request)).show(false);
    raiseWindow();
  }

  // watchFile (polls every 0.3 s) rather than fs.watch: it survives the file being replaced atomically.
  for (const file of requestFiles()) {
    fs.watchFile(file, { interval: 300 }, () => { check(file); });
    context.subscriptions.push({ dispose: () => fs.unwatchFile(file) });
  }
}

function deactivate() {}

module.exports = {
  activate, deactivate, processTable, isAttachedTo, projectName, commandsUnder, isAgentsView, projectFolder,
  folderContains, priority, waitMs, claimPath, cleanClaims, claimRequest,
};
