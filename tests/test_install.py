"""Tests for install.sh / uninstall.sh. Always against a temp home; apps, LaunchAgent and extension are skipped."""
import json
import os
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SAFE = ["--skip-build", "--skip-launchagent", "--skip-extension"]


class InstallTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = self._tmp.name
        self.fake_home = os.path.join(tmp, "home")
        self.claude = os.path.join(tmp, "claude")
        self.ccnotify = os.path.join(tmp, "claude", "ccnotify")
        os.makedirs(self.fake_home)
        os.makedirs(self.claude)
        self.settings = os.path.join(self.claude, "settings.json")
        self.env = dict(os.environ, HOME=self.fake_home, CLAUDE_CONFIG_DIR=self.claude,
                        CCNOTIFY_HOME=self.ccnotify,
                        CCNOTIFY_LAUNCHAGENTS_DIR=os.path.join(tmp, "LaunchAgents"))

    def sh(self, script, *args):
        return subprocess.run(["bash", os.path.join(ROOT, script)] + list(args), env=self.env,
                              capture_output=True, text=True, timeout=120)

    def install(self, *args):
        result = self.sh("install.sh", *(SAFE + list(args)))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def uninstall(self, *args):
        result = self.sh("uninstall.sh", "--skip-launchagent", "--skip-extension", *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def write_settings(self, data):
        with open(self.settings, "w", encoding="utf-8") as f:
            json.dump(data, f)

    def read_settings(self):
        with open(self.settings, encoding="utf-8") as f:
            return json.load(f)

    def backups(self):
        return [n for n in os.listdir(self.claude) if ".ccnotify-backup-" in n]

    def our_commands(self, data):
        return [h["command"] for groups in data.get("hooks", {}).values() for g in groups for h in g["hooks"]
                if "ccnotify/bin/notify.sh" in h["command"]]


class Install(InstallTestCase):
    def test_fresh_install(self):
        self.install()
        for name in ("notify.sh", "notify.py", "ccnotify_transcript.py", "focus_session.py"):
            self.assertTrue(os.path.isfile(os.path.join(self.ccnotify, "bin", name)), name)
        for name in ("notify.sh", "notify.py", "focus_session.py"):
            self.assertTrue(os.access(os.path.join(self.ccnotify, "bin", name), os.X_OK), name)
        self.assertTrue(os.path.isfile(os.path.join(self.ccnotify, "statusline", "statusline.py")))
        self.assertTrue(os.access(os.path.join(self.ccnotify, "statusline", "statusline.py"), os.X_OK))
        self.assertTrue(os.path.isfile(os.path.join(self.ccnotify, "vscode-extension", "extension.js")))
        config = os.path.join(self.ccnotify, "config.json")
        self.assertEqual(stat.S_IMODE(os.stat(config).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.ccnotify, "state")).st_mode), 0o700)
        hooks = self.read_settings()["hooks"]
        self.assertEqual(sorted(hooks), ["Notification", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"])
        hook = hooks["Stop"][0]["hooks"][0]
        self.assertEqual(hook["command"], '"%s/bin/notify.sh" stop' % self.ccnotify)
        self.assertIs(hook["async"], True)
        self.assertEqual(hook["timeout"], 10)
        self.assertEqual(hooks["UserPromptSubmit"][0]["hooks"][0]["command"].split()[-1], "prompt")
        self.assertEqual(hooks["SessionStart"][0]["hooks"][0]["command"].split()[-1], "session-start")
        self.assertNotIn("statusLine", self.read_settings())

    def test_installed_hook_runs(self):
        self.install()
        result = subprocess.run([os.path.join(self.ccnotify, "bin", "notify.sh"), "prompt"], input="{}",
                                text=True, env=dict(self.env, PATH="/usr/bin:/bin"), capture_output=True,
                                timeout=30)
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_idempotent_and_keeps_existing_config(self):
        self.install()
        with open(os.path.join(self.ccnotify, "config.json"), "w", encoding="utf-8") as f:
            json.dump({"language": "es"}, f)
        first = self.read_settings()
        before = self.backups()
        result = self.install()
        self.assertEqual(self.read_settings(), first)
        self.assertEqual(self.backups(), before)  # nothing changed, no new backup
        self.assertIn("no changes", result.stdout)
        with open(os.path.join(self.ccnotify, "config.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f), {"language": "es"})

    def test_merges_without_touching_other_hooks(self):
        self.write_settings({
            "model": "opus",
            "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/my-other-hook"}]}],
                "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "lint.sh"}]}],
            },
        })
        self.install()
        data = self.read_settings()
        self.assertEqual(data["model"], "opus")
        self.assertEqual(data["hooks"]["PreToolUse"][0]["hooks"][0]["command"], "lint.sh")
        stop_commands = [h["command"] for g in data["hooks"]["Stop"] for h in g["hooks"]]
        self.assertIn("/usr/local/bin/my-other-hook", stop_commands)
        self.assertEqual(len(self.our_commands(data)), 5)
        self.assertEqual(len(self.backups()), 1)

    def test_reinstall_with_new_home_replaces_the_old_entry(self):
        self.install()
        self.env["CCNOTIFY_HOME"] = os.path.join(self.claude, "other", "ccnotify")
        self.install()
        commands = self.our_commands(self.read_settings())
        self.assertEqual(len(commands), 5)
        self.assertTrue(all("/other/ccnotify/bin/notify.sh" in c for c in commands))

    def test_invalid_settings_json_is_not_touched(self):
        with open(self.settings, "w", encoding="utf-8") as f:
            f.write("{ not json")
        result = self.sh("install.sh", *SAFE)
        self.assertNotEqual(result.returncode, 0)
        with open(self.settings, encoding="utf-8") as f:
            self.assertEqual(f.read(), "{ not json")

    def test_statusline_opt_in(self):
        self.install()
        self.assertNotIn("statusLine", self.read_settings())
        self.install("--statusline")
        line = self.read_settings()["statusLine"]
        self.assertEqual(line, {"type": "command", "command": self.ccnotify + "/statusline/statusline.py",
                                "refreshInterval": 60})

    def test_statusline_refuses_to_replace_a_different_one(self):
        mine = {"type": "command", "command": "~/my-statusline.sh"}
        self.write_settings({"statusLine": mine})
        result = self.install("--statusline")
        self.assertEqual(self.read_settings()["statusLine"], mine)
        self.assertIn("NOT changed", result.stdout)
        self.install("--statusline", "--force")
        self.assertIn("ccnotify/statusline/statusline.py", self.read_settings()["statusLine"]["command"])

    def test_dry_run_changes_nothing(self):
        result = self.sh("install.sh", "--dry-run", "--statusline")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[dry-run]", result.stdout)
        self.assertFalse(os.path.exists(self.ccnotify))
        self.assertFalse(os.path.exists(self.settings))
        # (the python3 shim may create ~/Library/Caches by itself; nothing of ours may appear)
        found = [os.path.join(r, n) for r, d, f in os.walk(self.fake_home) for n in d + f if "ccnotify" in n.lower()]
        self.assertEqual(found, [])

    def test_unknown_option(self):
        self.assertEqual(self.sh("install.sh", "--nope").returncode, 2)


class Uninstall(InstallTestCase):
    def test_removes_only_what_install_added(self):
        other = {"type": "command", "command": "/usr/local/bin/my-other-hook"}
        self.write_settings({"theme": "dark", "hooks": {"Stop": [{"hooks": [other]}]}})
        self.install("--statusline")
        self.uninstall()
        data = self.read_settings()
        self.assertEqual(data, {"theme": "dark", "hooks": {"Stop": [{"hooks": [other]}]}})
        self.assertFalse(os.path.exists(os.path.join(self.ccnotify, "bin")))
        self.assertTrue(os.path.exists(os.path.join(self.ccnotify, "config.json")))
        self.assertTrue(os.path.isdir(os.path.join(self.ccnotify, "state")))

    def test_keeps_a_statusline_that_is_not_ours(self):
        mine = {"type": "command", "command": "~/my-statusline.sh"}
        self.install()
        data = self.read_settings()
        data["statusLine"] = mine
        self.write_settings(data)
        self.uninstall()
        self.assertEqual(self.read_settings()["statusLine"], mine)
        self.assertEqual(self.our_commands(self.read_settings()), [])

    def test_purge(self):
        self.install()
        self.uninstall("--purge")
        self.assertFalse(os.path.exists(self.ccnotify))
        self.assertEqual(self.read_settings(), {})

    def test_dry_run_and_missing_settings(self):
        self.install()
        before = self.read_settings()
        result = self.uninstall("--dry-run", "--purge")
        self.assertIn("[dry-run]", result.stdout)
        self.assertEqual(self.read_settings(), before)
        self.assertTrue(os.path.isdir(self.ccnotify))
        os.remove(self.settings)
        self.uninstall()


if __name__ == "__main__":
    unittest.main()
