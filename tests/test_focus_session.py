"""Tests for hooks/focus_session.py."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hooks"))

import focus_session as fs  # noqa: E402


class Result(object):
    def __init__(self, stdout=""):
        self.returncode, self.stdout = 0, stdout


class FakeRun(object):
    """ps returns the parent from a table; `open` calls are recorded."""

    def __init__(self, parents=None):
        self.parents = parents or {}
        self.calls = []

    def __call__(self, cmd, **kwargs):
        self.calls.append(cmd)
        if cmd[0] == "ps":
            return Result(str(self.parents.get(int(cmd[-1]), "")))
        return Result()

    def opens(self):
        return [c for c in self.calls if c[0] == "open"]


def storage(folders):
    return {"windowsState": {"lastActiveWindow": {"folder": "file://" + folders[0]},
                             "openedWindows": [{"folder": "file://" + f} for f in folders[1:]]}}


class FocusSession(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.support = os.path.join(self._tmp.name, "support")
        self.home = os.path.join(self._tmp.name, "ccnotify")
        self.env = {"CCNOTIFY_APP_SUPPORT": self.support, "CCNOTIFY_HOME": self.home}

    def write_storage(self, folder, data):
        path = os.path.join(self.support, folder, "User", "globalStorage")
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "storage.json"), "w", encoding="utf-8") as f:
            json.dump(data, f)

    def test_storage_paths_per_editor(self):
        expected = {"com.microsoft.VSCode": "Code", "com.microsoft.VSCodeInsiders": "Code - Insiders",
                    "com.vscodium": "VSCodium", "com.todesktop.230313mzl4w4u92": "Cursor",
                    "com.exafunction.windsurf": "Windsurf"}
        for host, folder in expected.items():
            self.assertEqual(fs.storage_path(host, self.env),
                             os.path.join(self.support, folder, "User", "globalStorage", "storage.json"))
        self.assertIsNone(fs.storage_path("com.apple.Terminal", self.env))

    def test_most_specific_folder(self):
        folders = ["/Users/you/code", "/Users/you/code/my-project", "/Users/you/other"]
        self.assertEqual(fs.most_specific_folder(folders, "/Users/you/code/my-project/src"),
                         "/Users/you/code/my-project")
        self.assertEqual(fs.most_specific_folder(folders, "/Users/you/code/my-project"),
                         "/Users/you/code/my-project")
        self.assertEqual(fs.most_specific_folder(folders, "/Users/you/code/zzz"), "/Users/you/code")
        self.assertIsNone(fs.most_specific_folder(folders, "/Users/you/code-other"))  # not a path prefix match
        self.assertIsNone(fs.most_specific_folder(folders, "/tmp"))

    def test_open_folders_decodes_uris(self):
        self.write_storage("Code", storage(["/Users/you/my%20project", "/Users/you/b"]))
        self.assertEqual(fs.open_folders(fs.storage_path("com.microsoft.VSCode", self.env)),
                         ["/Users/you/my project", "/Users/you/b"])

    def test_open_folders_tolerates_garbage(self):
        self.assertEqual(fs.open_folders("/nonexistent/storage.json"), [])
        self.write_storage("Code", {"windowsState": "nope"})
        self.assertEqual(fs.open_folders(fs.storage_path("com.microsoft.VSCode", self.env)), [])

    def test_focus_opens_matching_folder_with_the_editors_own_storage(self):
        self.write_storage("Cursor", storage(["/Users/you/my-project"]))
        self.write_storage("Code", storage(["/Users/you/not-this"]))
        run = FakeRun()
        command = fs.focus("com.todesktop.230313mzl4w4u92", "/Users/you/my-project/src", 0, self.home,
                           self.env, run)
        self.assertEqual(command, ["open", "-b", "com.todesktop.230313mzl4w4u92", "/Users/you/my-project"])
        self.assertEqual(run.opens(), [command])

    def test_focus_without_matching_folder_just_raises_the_app(self):
        self.write_storage("Code", storage(["/Users/you/other"]))
        run = FakeRun()
        self.assertEqual(fs.focus("com.microsoft.VSCode", "/Users/you/my-project", 0, self.home, self.env, run),
                         ["open", "-b", "com.microsoft.VSCode"])

    def test_other_hosts_are_only_brought_to_front(self):
        run = FakeRun()
        self.assertEqual(fs.focus("com.apple.Terminal", "/Users/you/my-project", 123, self.home, self.env, run),
                         ["open", "-b", "com.apple.Terminal"])
        self.assertFalse(os.path.exists(os.path.join(self.home, "state", "focus-request.json")))

    def test_focus_request_file(self):
        run = FakeRun(parents={300: 200, 200: 100, 100: 1})
        fs.focus("com.microsoft.VSCode", "/Users/you/my-project", 300, self.home, self.env, run)
        path = os.path.join(self.home, "state", "focus-request.json")
        with open(path, encoding="utf-8") as f:
            request = json.load(f)
        self.assertEqual(request["pids"], [300, 200, 100])
        self.assertIsInstance(request["at"], float)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual([n for n in os.listdir(os.path.dirname(path)) if n.endswith(".tmp")], [])

    def test_background_job_request_and_no_folder_open(self):
        # A background session: the request carries the job id so the extension can `claude attach` it,
        # and the job's own folder is NOT opened (it could raise a different window).
        self.write_storage("Code", storage(["/Users/you/my-project"]))
        run = FakeRun(parents={300: 200, 200: 100, 100: 1})
        command = fs.focus("com.microsoft.VSCode", "/Users/you/my-project", 300, self.home, self.env, run,
                           job="a3b56e59")
        self.assertEqual(command, ["open", "-b", "com.microsoft.VSCode"])
        with open(os.path.join(self.home, "state", "focus-request.json"), encoding="utf-8") as f:
            request = json.load(f)
        self.assertEqual(request["job"], "a3b56e59")
        self.assertEqual(request["cwd"], "/Users/you/my-project")
        self.assertIn("claude", request)  # absolute path, or "" when claude is not in a known place

    def request_for(self, cwd, config=None):
        if config is not None:
            os.makedirs(self.home, exist_ok=True)
            with open(os.path.join(self.home, "config.json"), "w", encoding="utf-8") as f:
                json.dump(config, f)
        fs.focus("com.microsoft.VSCode", cwd, 300, self.home, self.env, FakeRun(parents={300: 1}), job="a3b56e59")
        with open(os.path.join(self.home, "state", "focus-request.json"), encoding="utf-8") as f:
            return json.load(f)

    def test_job_request_carries_the_project_name(self):
        self.assertEqual(self.request_for("/work/my-app/.claude/worktrees/kit")["project"], "my-app")
        self.assertEqual(self.request_for("/work/my-app/")["project"], "my-app")
        names = {"project_names": {"long-repository-name": "repo"}}
        self.assertEqual(self.request_for("/work/long-repository-name/.claude/worktrees/base", names)["project"],
                         "repo")

    def test_project_label_ignores_malformed_config(self):
        for bad in ([1], 5, "x", {"my-app": 5}, {"my-app": ""}):
            self.assertEqual(self.request_for("/work/my-app", {"project_names": bad})["project"], "my-app", bad)
        with open(os.path.join(self.home, "config.json"), "w", encoding="utf-8") as f:
            f.write("[not json")
        self.assertEqual(self.request_for("/work/my-app")["project"], "my-app")
        with open(os.path.join(self.home, "config.json"), "w", encoding="utf-8") as f:
            f.write("[1, 2]")
        self.assertEqual(self.request_for("/work/my-app")["project"], "my-app")

    def test_home_folder_sends_no_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = os.path.realpath(tmp)
            with mock.patch.dict(os.environ, {"HOME": home}):
                self.assertNotIn("project", self.request_for(home))
                self.assertNotIn("project", self.request_for(home + "/.claude/worktrees/kit"))

    def test_invalid_job_id_is_ignored(self):
        self.write_storage("Code", storage(["/Users/you/my-project"]))
        run = FakeRun(parents={300: 1})
        command = fs.focus("com.microsoft.VSCode", "/Users/you/my-project", 300, self.home, self.env, run,
                           job="x; rm -rf /")
        self.assertEqual(command, ["open", "-b", "com.microsoft.VSCode", "/Users/you/my-project"])
        with open(os.path.join(self.home, "state", "focus-request.json"), encoding="utf-8") as f:
            self.assertNotIn("job", json.load(f))

    def test_process_chain_stops_at_init_and_limit(self):
        self.assertEqual(fs.process_chain(5, FakeRun({5: 4, 4: 1})), [5, 4])
        loop = FakeRun({n: n + 1 for n in range(2, 100)})
        self.assertEqual(len(fs.process_chain(2, loop, limit=15)), 15)

    def test_cli_runs_without_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_bin = os.path.join(tmp, "bin")
            os.makedirs(fake_bin)
            record = os.path.join(tmp, "args.txt")
            with open(os.path.join(fake_bin, "open"), "w") as f:
                f.write('#!/bin/sh\necho "$@" > "%s"\n' % record)
            os.chmod(os.path.join(fake_bin, "open"), 0o755)
            env = dict(os.environ, PATH=fake_bin + ":/usr/bin:/bin", CCNOTIFY_HOME=os.path.join(tmp, "h"),
                       CCNOTIFY_APP_SUPPORT=os.path.join(tmp, "none"))
            script = os.path.join(HERE, "..", "hooks", "focus_session.py")
            result = subprocess.run([sys.executable, script, "--host", "com.apple.Terminal", "--cwd", "/tmp"],
                                    env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(record, encoding="utf-8") as f:
                self.assertEqual(f.read().strip(), "-b com.apple.Terminal")


if __name__ == "__main__":
    unittest.main()
