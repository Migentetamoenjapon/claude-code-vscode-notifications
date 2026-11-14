// CCNotify Focus Terminal: minimal VS Code extension (also works in Insiders, VSCodium, Cursor, Windsurf).
//
// Every editor window runs its own copy and watches a request file:
//   <CCNOTIFY_HOME>/state/focus-request.json  ->  {"at": <epoch seconds>, "pids": [<pid>, ...]}
// written by hooks/focus_session.py when you click a popup or a menu bar item; "pids" is the Claude Code
// process and its parents. The window that owns a terminal whose shell is in that list:
//   1. shows that terminal (opens the panel if it was closed and gives it focus), and
//   2. raises its own window by asking macOS to open its own workspace/folder with its own editor app
//      (if the window already has it, the editor just focuses it: no new window).
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

function requestFiles() {
  const homes = [];
  if (process.env.CCNOTIFY_HOME) homes.push(process.env.CCNOTIFY_HOME);
  homes.push(path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude"), "ccnotify"));
  return Array.from(new Set(homes)).map((home) => path.join(home, "state", "focus-request.json"));
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
    for (const terminal of vscode.window.terminals) {
      let pid;
      try {
        pid = await terminal.processId;
      } catch (e) {
        continue;
      }
      if (!pid || !pids.has(pid)) continue;
      terminal.show(false);
      const target = ownWindowTarget();
      if (bundleId && target) {
        execFile("/usr/bin/open", ["-b", bundleId, target], () => {});
      }
      return;
    }
  }

  // watchFile (polls every 0.3 s) rather than fs.watch: it survives the file being replaced atomically.
  for (const file of requestFiles()) {
    fs.watchFile(file, { interval: 300 }, () => { check(file); });
    context.subscriptions.push({ dispose: () => fs.unwatchFile(file) });
  }
}

function deactivate() {}

module.exports = { activate, deactivate };
