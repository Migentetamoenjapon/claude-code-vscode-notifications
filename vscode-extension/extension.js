// CCNotify Focus Terminal: minimal VS Code extension (also works in Insiders, VSCodium, Cursor, Windsurf).
//
// Every editor window runs its own copy and watches a request file:
//   <CCNOTIFY_HOME>/state/focus-request.json
//   -> {"at": <epoch seconds>, "pids": [<pid>, ...], "job"?: "<id>", "cwd"?: "...", "claude"?: "<path>"}
// written by hooks/focus_session.py when you click a popup or a menu bar item; "pids" is the Claude Code
// process and its parents. The window that owns a terminal whose shell is in that list handles it:
//   - Normal session: shows that terminal (opens the panel if it was closed and gives it focus).
//   - Background session ("job", started with `claude --bg`): it has no terminal of its own (it is a child of
//     the main session), so the window opens or reuses a terminal that runs `claude attach <job>` directly
//     and shows it. It never types into the main session's terminal.
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

function requestFiles() {
  const homes = [];
  if (process.env.CCNOTIFY_HOME) homes.push(process.env.CCNOTIFY_HOME);
  homes.push(path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude"), "ccnotify"));
  return Array.from(new Set(homes)).map((home) => path.join(home, "state", "focus-request.json"));
}

function activate(context) {
  const bundleId = BUNDLE_IDS[vscode.env.uriScheme];
  const jobTerminals = new Map(); // job id -> terminal running `claude attach <job>`
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

  /** A live terminal already attached to the job, or a new one running `claude attach <job>`. */
  function terminalForJob(request) {
    const job = String(request.job);
    const known = jobTerminals.get(job);
    if (known && known.exitStatus === undefined && vscode.window.terminals.includes(known)) return known;
    // After a window reload the map is empty, but the terminal we created is still there under its name.
    const tag = `(${job})`;
    const byName = vscode.window.terminals.find((t) => t.name.endsWith(tag) && t.exitStatus === undefined);
    if (byName) {
      jobTerminals.set(job, byName);
      return byName;
    }
    const cwd = request.cwd && fs.existsSync(String(request.cwd)) ? String(request.cwd) : undefined;
    const project = request.cwd ? path.basename(String(request.cwd)) : "Claude";
    const name = `${project} ${tag}`;
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
    jobTerminals.set(job, terminal);
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
      terminalForJob(request).show(false);
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
  context.subscriptions.push(vscode.window.onDidCloseTerminal((t) => {
    for (const [job, terminal] of jobTerminals) if (terminal === t) jobTerminals.delete(job);
  }));
}

function deactivate() {}

module.exports = { activate, deactivate };
