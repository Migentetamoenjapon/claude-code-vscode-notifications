// Checks the editor extension's "is this terminal attached to that background session right now?" logic.
// Run with: node tests/extension_helpers.js   (no VS Code needed: the `vscode` module is stubbed)
const assert = require("assert");
const Module = require("module");
const path = require("path");

const load = Module._load;
Module._load = (request, ...rest) => (request === "vscode" ? {} : load(request, ...rest));
const { isAttachedTo, processTable, projectName } = require(path.join(__dirname, "..", "vscode-extension", "extension.js"));

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

processTable().then((real) => {
  assert.ok(real.size > 0, "ps returned no processes");
  const self = real.get(process.pid);
  assert.ok(self && /extension_helpers\.js/.test(self.command), "this process is in the table with its command");
  console.log("extension helpers: ok");
});
