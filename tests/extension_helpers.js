// Checks the editor extension's "is this terminal attached to that background session right now?" logic.
// Run with: node tests/extension_helpers.js   (no VS Code needed: the `vscode` module is stubbed)
const assert = require("assert");
const Module = require("module");
const path = require("path");

const load = Module._load;
Module._load = (request, ...rest) => (request === "vscode" ? {} : load(request, ...rest));
const {
  isAttachedTo, processTable, projectName, commandsUnder, isAgentsView, projectFolder, folderContains, priority,
  waitMs, claimPath, claimRequest,
} = require(path.join(__dirname, "..", "vscode-extension", "extension.js"));

const table = new Map([
  [100, { ppid: 1, command: "/Users/you/.local/bin/claude attach aaaa1111" }], // opened by a click, still there
  [200, { ppid: 1, command: "/Users/you/.local/bin/claude agents" }], // was `attach bbbb2222`; ← made it the agent view
  [300, { ppid: 1, command: "/bin/zsh -il" }], // fallback terminal: the shell ran the command
  [301, { ppid: 300, command: "claude attach cccc3333" }],
  [400, { ppid: 1, command: "/bin/zsh -il" }],
  [401, { ppid: 400, command: "claude attach aaaa11112" }], // a longer id must not match a shorter one
]);

assert.strictEqual(isAttachedTo(table, 100, "aaaa1111"), true);
assert.strictEqual(isAttachedTo(table, 100, "bbbb2222"), false);
assert.strictEqual(isAttachedTo(table, 200, "bbbb2222"), false, "a terminal that moved to the agent view is not reused");
assert.strictEqual(isAttachedTo(table, 300, "cccc3333"), true, "a command started from the terminal's shell counts");
assert.strictEqual(isAttachedTo(table, 400, "aaaa1111"), false);
assert.strictEqual(isAttachedTo(table, 999, "aaaa1111"), false);

// Terminal tab name: the project name from CCNotify, else the project folder of cwd (worktree-aware).
const os = require("os");
assert.strictEqual(projectName({ project: "repo", cwd: "/work/my-app" }), "repo");
assert.strictEqual(projectName({ project: "  repo  " }), "repo");
assert.strictEqual(projectName({ project: "a\u0000b\nc\u009fd" }), "a b c d", "control characters are removed");
assert.strictEqual(projectName({ project: "x".repeat(200) }).length, 60);
assert.strictEqual(projectName({ cwd: "/work/my-app" }), "my-app");
assert.strictEqual(projectName({ cwd: "/work/my-app/" }), "my-app");
assert.strictEqual(projectName({ cwd: "/work/my-app/.claude/worktrees/kit" }), "my-app");
assert.strictEqual(projectName({ cwd: "/work/my-app/.claude/worktrees/kit/" }), "my-app");
assert.strictEqual(projectName({ project: "", cwd: "/work/my-app" }), "my-app", "empty project falls back");
assert.strictEqual(projectName({ project: "   ", cwd: "/work/my-app" }), "my-app");
assert.strictEqual(projectName({ project: 5, cwd: "/work/my-app" }), "my-app", "non-string project is ignored");
assert.strictEqual(projectName({ project: ["x"], cwd: "/work/my-app" }), "my-app");
assert.strictEqual(projectName({}), "Claude");
assert.strictEqual(projectName({ cwd: os.homedir() }), "Claude", "the account name is never shown");
assert.strictEqual(projectName({ cwd: os.homedir() + "/.claude/worktrees/kit" }), "Claude");

// Descendants, not only direct children: shell -> wrapper -> claude attach.
const deep = new Map([
  [500, { ppid: 1, command: "/bin/zsh -il" }],
  [501, { ppid: 500, command: "node wrapper.js" }],
  [502, { ppid: 501, command: "claude attach dddd4444" }],
  [503, { ppid: 501, command: "claude agents" }],
]);
assert.deepStrictEqual(commandsUnder(deep, 500).sort(), ["/bin/zsh -il", "claude agents", "claude attach dddd4444", "node wrapper.js"]);
assert.strictEqual(isAttachedTo(deep, 500, "dddd4444"), true, "a grandchild counts");
assert.deepStrictEqual(commandsUnder(deep, 999), []);

// Agent view matcher.
for (const yes of ["claude agents", "/Users/you/.local/bin/claude agents", "claude agents --foo", "node /x/claude agents", "claude   agents"]) {
  assert.strictEqual(isAgentsView(yes), true, yes);
}
for (const no of ["claude attach x", "claude agentsx", "claude", "myclaude agents", "claude-agents", "claude attach agents", "", undefined]) {
  assert.strictEqual(isAgentsView(no), false, String(no));
}

// Folder-contains.
assert.strictEqual(folderContains("/a/my-app", "/a/my-app"), true, "equal");
assert.strictEqual(folderContains("/a/my-app/", "/a/my-app"), true, "trailing slash");
assert.strictEqual(folderContains("/a", "/a/my-app/src"), true, "inside");
assert.strictEqual(folderContains("/a/my", "/a/my-app"), false, "sibling with the same prefix");
assert.strictEqual(folderContains("/a/my-app", "/a"), false, "parent is not inside");
assert.strictEqual(folderContains("", "/a/my-app"), false, "empty folder");
assert.strictEqual(folderContains("/a/my-app", ""), false, "empty target");
assert.strictEqual(folderContains(undefined, undefined), false);

// Project folder (worktree cut).
assert.strictEqual(projectFolder("/a/my-app/.claude/worktrees/kit"), "/a/my-app");
assert.strictEqual(projectFolder("/a/my-app/.claude/worktrees/kit/"), "/a/my-app");
assert.strictEqual(projectFolder("/a/my-app/"), "/a/my-app");
assert.strictEqual(projectFolder(undefined), "");
assert.strictEqual(folderContains("/a/my-app", projectFolder("/a/my-app/.claude/worktrees/kit")), true);

// Priority ordering: 1 attach, 2 agent view, 3 project, 4 other; and the wait that follows.
assert.strictEqual(priority({ hasAttach: true, hasAgentsView: true, hasProject: true }), 1);
assert.strictEqual(priority({ hasAttach: false, hasAgentsView: true, hasProject: true }), 2);
assert.strictEqual(priority({ hasAttach: false, hasAgentsView: false, hasProject: true }), 3);
assert.strictEqual(priority({ hasAttach: false, hasAgentsView: false, hasProject: false }), 4);
assert.deepStrictEqual([0, 1, 2, 3, 4].map(waitMs), [0, 600, 1200, 1800, 2400]);

// Claims: exclusive per request, stale ones cleaned.
const fs = require("fs");
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ccnotify-claims-"));
assert.strictEqual(path.basename(claimPath(dir, "1700000000.5abc")), "focus-1700000000.5.claim", "only digits and dots stay");
assert.strictEqual(claimRequest(dir, 1700000000.5), true, "first claim wins");
assert.strictEqual(claimRequest(dir, 1700000000.5), false, "second claim loses");
assert.strictEqual(claimRequest(dir, 1700000009.25), true, "a different request is independent");
assert.strictEqual(claimRequest(path.join(dir, "missing"), 1), true, "other errors: act anyway");
const stale = claimPath(dir, 1600000000);
fs.writeFileSync(stale, "");
const old = new Date(Date.now() - 120000);
fs.utimesSync(stale, old, old);
const keep = path.join(dir, "other.txt");
fs.writeFileSync(keep, "");
fs.utimesSync(keep, old, old);
assert.strictEqual(claimRequest(dir, 1700000020), true);
assert.strictEqual(fs.existsSync(stale), false, "claims older than 60 s are removed");
assert.strictEqual(fs.existsSync(claimPath(dir, 1700000000.5)), true, "recent claims stay");
assert.strictEqual(fs.existsSync(keep), true, "other files are never touched");
fs.rmSync(dir, { recursive: true, force: true });

processTable().then((real) => {
  assert.ok(real.size > 0, "ps returned no processes");
  const self = real.get(process.pid);
  assert.ok(self && /extension_helpers\.js/.test(self.command), "this process is in the table with its command");
  console.log("extension helpers: ok");
});
