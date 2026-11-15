"""Tests for hooks/notify.py. Everything runs against a temp CCNOTIFY_HOME and a fake subprocess runner."""
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOKS = os.path.join(HERE, "..", "hooks")
sys.path.insert(0, HOOKS)

import notify  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
NOW = float(int(time.time()))  # housekeeping compares with real file mtimes


def fixture(name):
    return os.path.join(FIXTURES, name)


def payload(name, **overrides):
    with open(fixture(name), encoding="utf-8") as f:
        data = json.load(f)
    data.update(overrides)
    return data


class Result(object):
    def __init__(self, returncode=0, stdout=""):
        self.returncode, self.stdout = returncode, stdout


class FakeRun(object):
    def __init__(self, table=None, open_rc=0):
        self.calls = []
        self.table = table or {}
        self.open_rc = open_rc

    def __call__(self, cmd, **kwargs):
        self.calls.append(cmd)
        if cmd[0] == "ps":
            pid = int(cmd[-1])
            field = cmd[3].rstrip("=")
            row = self.table.get(pid)
            return Result(0, str(row[field]) if row else "")
        if cmd[0] == "open":
            return Result(self.open_rc)
        return Result(0, "")

    def named(self, name):
        return [c for c in self.calls if c[0] == name]


class HookTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = os.path.join(self._tmp.name, "ccnotify")
        os.makedirs(self.home)
        self.run_ = FakeRun()

    def write_config(self, config):
        with open(os.path.join(self.home, "config.json"), "w", encoding="utf-8") as f:
            json.dump(config, f)

    def hook(self, config=None, app=True, now=NOW, env=None, run=None):
        if config is not None:
            self.write_config(config)
        if app:
            os.makedirs(os.path.join(self.home, "CCNotify.app"), exist_ok=True)
        environment = {"__CFBundleIdentifier": "com.microsoft.VSCode",
                       "CLAUDE_CONFIG_DIR": os.path.join(self._tmp.name, "claude")}  # never the real one
        environment.update(env or {})
        return notify.Hook(self.home, env=environment, now=now, run=run or self.run_)

    def queued(self):
        folder = os.path.join(self.home, "state", "queue")
        if not os.path.isdir(folder):
            return []
        out = []
        for name in sorted(os.listdir(folder)):
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                out.append(json.load(f))
        return out

    def session(self, sid):
        with open(os.path.join(self.home, "state", "sessions", sid + ".json"), encoding="utf-8") as f:
            return json.load(f)

    def log_text(self):
        with open(os.path.join(self.home, "state", "ccnotify.log"), encoding="utf-8") as f:
            return f.read()


class ConfigAndHelpers(unittest.TestCase):
    def test_merge_keeps_defaults_and_overrides(self):
        merged = notify.merge_config(notify.DEFAULT_CONFIG, {"popup": {"seconds": 30},
                                                             "sounds": {"done": {"sound": "Ping"}}})
        self.assertEqual(merged["popup"]["seconds"], 30)
        self.assertEqual(merged["popup"]["width"], 460)
        self.assertEqual(merged["sounds"]["done"]["sound"], "Ping")
        self.assertEqual(merged["sounds"]["done"]["volume"], 0.5)
        self.assertEqual(merged["sounds"]["permission"]["sound"], "Submarine")

    def test_merge_rejects_wrong_types(self):
        merged = notify.merge_config(notify.DEFAULT_CONFIG, {"popup": {"seconds": "soon", "enabled": 1},
                                                             "events": "all", "language": 5})
        self.assertEqual(merged["popup"]["seconds"], 60)
        self.assertIs(merged["popup"]["enabled"], True)
        self.assertEqual(merged["events"]["done"], True)
        self.assertEqual(merged["language"], "auto")

    def test_example_config_matches_defaults(self):
        with open(os.path.join(HERE, "..", "config.example.json"), encoding="utf-8") as f:
            example = json.load(f)
        self.assertEqual(notify.merge_config(notify.DEFAULT_CONFIG, example), notify.DEFAULT_CONFIG)

    def test_language_detection(self):
        es = FakeRun()
        es_run = lambda cmd, **kw: Result(0, '(\n    "es-PA",\n    "en-US"\n)\n')  # noqa: E731
        en_run = lambda cmd, **kw: Result(0, '(\n    "en-US",\n    "es-PA"\n)\n')  # noqa: E731
        self.assertEqual(notify.detect_language("auto", es_run), "es")
        self.assertEqual(notify.detect_language("auto", en_run), "en")
        self.assertEqual(notify.detect_language("auto", es), "en")
        self.assertEqual(notify.detect_language("es", en_run), "es")

    def test_resolve_home(self):
        self.assertEqual(notify.resolve_home({"CCNOTIFY_HOME": "/tmp/x"}), "/tmp/x")
        self.assertEqual(notify.resolve_home({"CLAUDE_CONFIG_DIR": "/tmp/cfg"}, script_dir="/elsewhere"),
                         "/tmp/cfg/ccnotify")

    def test_resolve_home_from_install_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "bin"))
            open(os.path.join(tmp, "config.example.json"), "w").close()
            self.assertEqual(notify.resolve_home({}, script_dir=os.path.join(tmp, "bin")), tmp)

    def test_one_line_and_cap(self):
        self.assertEqual(notify.one_line("**Bold** and `code`\n\n- item one\n- item two"),
                         "Bold and code item one item two")
        self.assertLessEqual(len(notify.popup_text("word " * 10000)), 20000)

    def test_quiet_hours_wrap_midnight(self):
        config = notify.merge_config(notify.DEFAULT_CONFIG, {"quiet_hours": {"enabled": True}})

        def at(h, m):
            return time.mktime((2026, 11, 14, h, m, 0, 0, 0, -1))
        self.assertTrue(notify.in_quiet_hours(config, at(23, 30)))
        self.assertTrue(notify.in_quiet_hours(config, at(6, 59)))
        self.assertFalse(notify.in_quiet_hours(config, at(7, 0)))
        self.assertFalse(notify.in_quiet_hours(config, at(12, 0)))
        self.assertFalse(notify.in_quiet_hours(notify.DEFAULT_CONFIG, at(23, 30)))

    def test_sound_rules(self):
        config = notify.DEFAULT_CONFIG
        self.assertEqual(notify.sound_settings("done", config, NOW, turn_seconds=5)[0], "")
        self.assertEqual(notify.sound_settings("done", config, NOW, turn_seconds=60), ("Glass", 0.5, True))
        self.assertEqual(notify.sound_settings("done", config, NOW, turn_seconds=None)[0], "Glass")
        self.assertEqual(notify.sound_settings("permission", config, NOW, turn_seconds=1)[0], "Submarine")

    def test_find_claude_pid_native_and_node(self):
        table = {
            300: {"ppid": 200, "comm": "/bin/sh", "args": "sh -c notify.sh stop"},
            200: {"ppid": 100, "comm": "/usr/local/bin/node", "args": "node /x/node_modules/@anthropic-ai/claude-code/cli.js"},
            100: {"ppid": 1, "comm": "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", "args": "x"},
        }
        self.assertEqual(notify.find_claude_pid(FakeRun(table), start_pid=300), 200)
        table[200] = {"ppid": 100, "comm": "/Users/you/.local/bin/claude", "args": "claude"}
        self.assertEqual(notify.find_claude_pid(FakeRun(table), start_pid=300), 200)
        table[200] = {"ppid": 100, "comm": "/usr/local/bin/node", "args": "node /x/other-tool.js"}
        self.assertEqual(notify.find_claude_pid(FakeRun(table), start_pid=300), 0)
        table[200] = {"ppid": 100, "comm": "bun", "args": "bun run /x/claude/cli.js"}
        self.assertEqual(notify.find_claude_pid(FakeRun(table), start_pid=300), 200)

    def test_find_claude_pid_background_sessions_use_their_own_process(self):
        # Background sessions hang from one shared daemon. The hook must report the session's own process
        # (which renames itself, or is the versioned native binary), never the daemon.
        daemon = {"ppid": 50, "comm": "/Users/you/.local/bin/claude", "args": "claude daemon run"}
        table = {
            300: {"ppid": 250, "comm": "/bin/sh", "args": "sh -c notify.sh stop"},
            250: {"ppid": 240, "comm": "claude bg-spare", "args": "claude bg-spare --bg-spare /tmp/x.sock"},
            240: {"ppid": 200, "comm": "claude bg-pty-host", "args": "claude bg-pty-host /tmp/x.sock"},
            200: daemon,
        }
        self.assertEqual(notify.find_claude_pid(FakeRun(table), start_pid=300), 250)
        table[250] = {"ppid": 240, "comm": "/Users/you/.local/share/claude/versions/2.1.0",
                      "args": "/Users/you/.local/share/claude/versions/2.1.0 --session-id abc"}
        self.assertEqual(notify.find_claude_pid(FakeRun(table), start_pid=300), 250)

    def test_is_claude_process(self):
        self.assertTrue(notify.is_claude_process("claude"))
        self.assertTrue(notify.is_claude_process("claude bg-spare"))
        self.assertTrue(notify.is_claude_process("/Users/you/.local/share/claude/versions/2.1.0"))
        self.assertFalse(notify.is_claude_process("/usr/local/bin/claude-helper"))
        self.assertFalse(notify.is_claude_process("/bin/zsh"))
        self.assertFalse(notify.is_claude_process("/usr/local/bin/node", "node /x/other-tool.js"))


class StopEvent(HookTestCase):
    def test_done_popup_content(self):
        hook = self.hook({"language": "en"})
        hook.handle("prompt", payload("payload_stop.json", prompt="Fix it"))
        later = self.hook({"language": "en"}, now=NOW + 60)
        later.handle("stop", payload("payload_stop.json", transcript_path=fixture("transcript_text.jsonl")))
        (popup,) = self.queued()
        self.assertEqual(popup["kind"], "done")
        self.assertEqual(popup["title"], "my-project")
        self.assertIn("All **tests** pass now.", popup["text"])
        self.assertEqual(popup["sound"], "Glass")
        self.assertEqual(popup["volume"], 0.5)
        self.assertTrue(popup["only_when_away"])
        self.assertEqual(popup["focus"], {"host": "com.microsoft.VSCode", "cwd": "/Users/you/my-project"})
        self.assertEqual(popup["transcript_size"], os.path.getsize(fixture("transcript_text.jsonl")))
        self.assertEqual(popup["event_at"], NOW + 60)
        self.assertEqual(popup["language"], "en")
        self.assertEqual(popup["id"], "sess-stop-00")
        self.assertEqual(popup["session"], "sess-stop-0004")
        for key in ("seconds", "width", "max_height_ratio", "max_stacked", "sticky_needs_you", "font_size"):
            self.assertIn(key, popup)
        opened = self.run_.named("open")
        self.assertEqual(len(opened), 1)
        self.assertEqual(opened[0][:4], ["open", "-n", "-g", os.path.join(self.home, "CCNotify.app")])
        self.assertEqual(opened[0][4], "--args")
        state = self.session("sess-stop-0004")
        self.assertEqual(state["state"], "wrote")
        self.assertEqual(state["updated_at"], NOW + 60)
        self.assertEqual(state["project"], "my-project")

    def test_short_turn_is_silent_but_still_shown(self):
        self.hook({"language": "en"}).handle("prompt", payload("payload_stop.json"))
        self.hook(now=NOW + 5).handle("stop", payload("payload_stop.json"))
        (popup,) = self.queued()
        self.assertEqual(popup["sound"], "")

    def test_last_message_falls_back_to_transcript(self):
        data = payload("payload_stop.json", transcript_path=fixture("transcript_text.jsonl"))
        del data["last_assistant_message"]
        self.hook({"language": "en"}).handle("stop", data)
        (popup,) = self.queued()
        self.assertIn("fixed `b.py`", popup["text"])

    def test_text_is_capped(self):
        self.hook({"language": "en"}).handle("stop", payload("payload_stop.json",
                                                              last_assistant_message="lorem ipsum " * 5000))
        (popup,) = self.queued()
        self.assertLessEqual(len(popup["text"]), 20000)
        self.assertGreater(len(popup["text"]), 19000)

    def test_background_tasks_suppress_popup(self):
        import calendar
        now = calendar.timegm(time.strptime("2026-11-14T12:05:00", "%Y-%m-%dT%H:%M:%S"))
        self.hook({"language": "en"}, now=now).handle(
            "stop", payload("payload_stop.json", transcript_path=fixture("transcript_bg_mixed.jsonl")))
        self.assertEqual(self.queued(), [])
        state = self.session("sess-stop-0004")
        self.assertEqual((state["state"], state["tasks"]), ("thinking", 1))
        self.assertIn("1 background task(s), no popup", self.log_text())

    def test_interrupted_turn_has_no_popup(self):
        self.hook({"language": "en"}).handle(
            "stop", payload("payload_stop.json", transcript_path=fixture("transcript_interrupted.jsonl")))
        self.assertEqual(self.queued(), [])
        self.assertIn("interrupted", self.log_text())

    def test_done_toggle_and_popup_toggle(self):
        self.hook({"events": {"done": False}}).handle("stop", payload("payload_stop.json"))
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.session("sess-stop-0004")["state"], "wrote")  # menu bar still updated
        self.hook({"popup": {"enabled": False}}).handle("stop", payload("payload_stop.json"))
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.run_.named("open"), [])

    def test_quiet_hours_mute_sound(self):
        config = {"language": "en", "quiet_hours": {"enabled": True, "from": "00:00", "to": "23:59"}}
        self.hook(config).handle("stop", payload("payload_stop.json"))
        (popup,) = self.queued()
        self.assertEqual(popup["sound"], "")

    def test_private_mode_keeps_text_out_of_files(self):
        self.hook({"language": "en", "popup": {"private": True}}).handle("stop", payload("payload_stop.json"))
        (popup,) = self.queued()
        self.assertEqual(popup["text"], "")
        self.assertTrue(popup["private"])
        self.assertNotIn("tests", json.dumps(self.session("sess-stop-0004")))


class NotificationEvent(HookTestCase):
    def test_permission(self):
        self.hook({"language": "en"}).handle("notification", payload("payload_permission.json"))
        (popup,) = self.queued()
        self.assertEqual(popup["kind"], "permission")
        self.assertEqual(popup["text"], "Asks permission to use **Bash**\n```\nDelete the build folder\n```")
        self.assertEqual(popup["sound"], "Submarine")
        self.assertEqual(self.session("sess-perm-0001")["state"], "needs")

    def test_permission_spanish(self):
        self.hook({"language": "es"}).handle("notification", payload("payload_permission.json"))
        (popup,) = self.queued()
        self.assertTrue(popup["text"].startswith("Pide permiso para usar **Bash**"))
        self.assertEqual(popup["language"], "es")

    def test_fenced_detail_cannot_break_out(self):
        data = payload("payload_permission.json")
        data["notification_data"]["tool_input"] = {"command": "echo ```x```"}
        self.hook({"language": "en"}).handle("notification", data)
        (popup,) = self.queued()
        self.assertEqual(popup["text"].count("```"), 2)

    def test_idle_prompt_is_ignored(self):
        self.hook({"language": "en"}).handle("notification", payload("payload_idle.json"))
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.run_.named("open"), [])
        self.assertIn("idle_prompt ignored", self.log_text())

    def test_question_kind(self):
        data = payload("payload_idle.json", notification_type="elicitation_dialog", message="Pick a color")
        self.hook({"language": "en"}).handle("notification", data)
        (popup,) = self.queued()
        self.assertEqual((popup["kind"], popup["text"], popup["sound"]), ("question", "Pick a color", "Ping"))

    def test_agent_question_title_and_text(self):
        self.hook({"language": "en"}).handle("notification", payload("payload_agent_input.json"))
        (popup,) = self.queued()
        self.assertEqual(popup["kind"], "agent")
        self.assertEqual(popup["title"], "my-project · reviewer")
        self.assertEqual(popup["text"], "Which branch should I compare against?")

    def test_agent_question_repeating_a_recent_done_is_dropped(self):
        question = "Which branch should I compare against?"
        self.hook({"language": "en"}).handle(
            "stop", payload("payload_stop.json", session_id="job-session", last_assistant_message=question))
        self.assertEqual(len(self.queued()), 1)
        self.hook(now=NOW + 5).handle("notification", payload("payload_agent_input.json"))
        self.assertEqual(len(self.queued()), 1)
        self.assertIn("duplicate of job-session", self.log_text())
        self.hook(now=NOW + 300).handle("notification", payload("payload_agent_input.json"))
        self.assertEqual(len(self.queued()), 2)

    def claude_dir_with_job(self, job, name, updated="2026-01-01T00:00:00Z"):
        claude_dir = os.path.join(self._tmp.name, "claude")
        os.makedirs(os.path.join(claude_dir, "jobs", job), exist_ok=True)
        with open(os.path.join(claude_dir, "jobs", job, "state.json"), "w", encoding="utf-8") as f:
            json.dump({"name": name, "updatedAt": updated}, f)
        return {"CLAUDE_CONFIG_DIR": claude_dir}

    def test_agent_question_click_opens_the_background_session(self):
        # The agent view relays the question; the popup and the menu bar must point at the job itself.
        self.claude_dir_with_job("aaaa1111", "reviewer", "2026-01-01T00:00:00Z")
        env = self.claude_dir_with_job("bbbb2222", "reviewer", "2026-02-01T00:00:00Z")  # same name, newer
        self.claude_dir_with_job("cccc3333", "someone-else")
        self.hook({"language": "en"}, env=env).handle("notification", payload("payload_agent_input.json"))
        (popup,) = self.queued()
        self.assertEqual(popup["focus"]["job"], "bbbb2222")
        self.assertEqual(self.session("sess-main-0002")["focus"]["job"], "bbbb2222")

    def test_agent_question_from_an_unknown_name_keeps_the_plain_focus(self):
        env = self.claude_dir_with_job("cccc3333", "someone-else")
        self.hook({"language": "en"}, env=env).handle("notification", payload("payload_agent_input.json"))
        (popup,) = self.queued()
        self.assertNotIn("job", popup["focus"])

    def test_agent_question_reworded_after_the_jobs_own_done_is_dropped(self):
        # The job announced its own "done"; the agent view then sends the same ask in other words.
        env = self.claude_dir_with_job("aaaa1111", "reviewer")
        job_env = dict(env, CLAUDE_JOB_DIR="/Users/you/.claude/jobs/aaaa1111")
        self.hook({"language": "en"}, env=job_env).handle(
            "stop", payload("payload_stop.json", session_id="job-session", last_assistant_message="All set."))
        self.assertEqual(len(self.queued()), 1)
        self.hook(now=NOW + 5, env=env).handle("notification", payload("payload_agent_input.json"))
        self.assertEqual(len(self.queued()), 1)
        self.assertIn("duplicate of job-session", self.log_text())
        self.hook(now=NOW + 300, env=env).handle("notification", payload("payload_agent_input.json"))
        self.assertEqual(len(self.queued()), 2)

    def test_per_kind_toggle(self):
        self.hook({"events": {"permission": False}}).handle("notification", payload("payload_permission.json"))
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.session("sess-perm-0001")["state"], "needs")

    def test_custom_sound_path_and_volume(self):
        config = {"language": "en", "sounds": {"permission": {"sound": "/Users/you/beep.aiff", "volume": 2,
                                                              "only_when_away": True}}}
        self.hook(config).handle("notification", payload("payload_permission.json"))
        (popup,) = self.queued()
        self.assertEqual((popup["sound"], popup["volume"], popup["only_when_away"]),
                         ("/Users/you/beep.aiff", 1.0, True))


class Fallback(HookTestCase):
    def test_osascript_when_app_missing(self):
        self.hook({"language": "en"}, app=False).handle("notification", payload("payload_permission.json"))
        self.assertEqual(self.queued(), [])
        (call,) = self.run_.named("osascript")
        self.assertIn("my-project", call)
        self.assertIn("Needs permission", call)
        self.assertIn("sound name (item 4 of argv)", " ".join(call))
        self.assertEqual(call[-1], "Submarine")

    def test_osascript_when_open_fails(self):
        run = FakeRun(open_rc=1)
        self.hook({"language": "en"}, run=run).handle("stop", payload("payload_stop.json"))
        self.assertEqual(len(run.named("osascript")), 1)
        self.assertEqual(self.queued(), [])  # the queued file was removed

    def test_osascript_never_receives_text_in_the_script(self):
        text = 'say "hi" & `rm -rf /` $(x)'
        self.hook({"language": "en"}, app=False).handle(
            "stop", payload("payload_stop.json", last_assistant_message=text))
        (call,) = self.run_.named("osascript")
        scripts = [call[i + 1] for i, a in enumerate(call) if a == "-e"]
        self.assertFalse(any("rm -rf" in s for s in scripts))
        self.assertTrue(any("rm -rf" in arg for arg in call[len(call) - 4:]))  # it travels as an argument


class SessionStateEvents(HookTestCase):
    def test_prompt_marks_thinking_and_seen(self):
        self.hook({"language": "en"}).handle("prompt", payload("payload_stop.json", prompt="  Do  the\nthing "))
        state = self.session("sess-stop-0004")
        self.assertEqual((state["state"], state["request"], state["turn_started_at"]),
                         ("thinking", "Do the thing", NOW))
        self.assertTrue(os.path.exists(os.path.join(self.home, "state", "seen", "sess-stop-0004")))

    def test_session_start_registers_without_overwriting(self):
        self.hook({"language": "en"}).handle("session-start", payload("payload_stop.json"))
        self.assertEqual(self.session("sess-stop-0004")["summary"], "New session")
        self.hook(now=NOW + 1).handle("prompt", payload("payload_stop.json", prompt="x"))
        self.hook(now=NOW + 2).handle("session-start", payload("payload_stop.json"))
        self.assertEqual(self.session("sess-stop-0004")["state"], "thinking")

    def test_clear_replaces_previous_session_of_same_process(self):
        hook = self.hook({"language": "en"})
        hook._pid = 4242
        hook.handle("session-start", payload("payload_stop.json", session_id="old-session"))
        other = self.hook(now=NOW + 1)
        other._pid = 4242
        other.handle("session-start", payload("payload_stop.json", session_id="new-session"))
        names = sorted(n for n in os.listdir(os.path.join(self.home, "state", "sessions")) if n.endswith(".json"))
        self.assertEqual(names, ["new-session.json"])
        self.assertEqual(self.session("new-session")["focus"]["pid"], 4242)

    def test_background_jobs_sharing_a_process_do_not_wipe_each_other(self):
        # Two background sessions reported under the same pid: starting one must not remove the other.
        a = self.hook({"language": "en"}, env={"CLAUDE_JOB_DIR": "/Users/you/.claude/jobs/aaaa1111"})
        a._pid = 4242
        a.handle("session-start", payload("payload_stop.json", session_id="job-a"))
        b = self.hook(now=NOW + 1, env={"CLAUDE_JOB_DIR": "/Users/you/.claude/jobs/bbbb2222"})
        b._pid = 4242
        b.handle("session-start", payload("payload_stop.json", session_id="job-b"))
        names = sorted(n for n in os.listdir(os.path.join(self.home, "state", "sessions")) if n.endswith(".json"))
        self.assertEqual(names, ["job-a.json", "job-b.json"])
        self.assertEqual(self.session("job-b")["focus"]["job"], "bbbb2222")

    def test_new_session_and_interrupted_turn_are_not_unread(self):
        self.hook({"language": "en"}).handle("session-start", payload("payload_stop.json"))
        seen = os.path.join(self.home, "state", "seen", "sess-stop-0004")
        self.assertTrue(os.path.exists(seen))
        os.remove(seen)
        self.hook(now=NOW + 5).handle(
            "stop", payload("payload_stop.json", transcript_path=fixture("transcript_interrupted.jsonl")))
        self.assertTrue(os.path.exists(seen))

    def test_other_process_sessions_survive(self):
        a = self.hook({"language": "en"})
        a._pid = 1
        a.handle("session-start", payload("payload_stop.json", session_id="a"))
        b = self.hook()
        b._pid = 2
        b.handle("session-start", payload("payload_stop.json", session_id="b"))
        self.assertTrue(os.path.exists(os.path.join(self.home, "state", "sessions", "a.json")))

    def test_session_end_removes_state_and_blocks_late_writes(self):
        self.hook({"language": "en"}).handle("prompt", payload("payload_stop.json", prompt="x"))
        self.hook(now=NOW + 10).handle("session-end", payload("payload_stop.json"))
        path = os.path.join(self.home, "state", "sessions", "sess-stop-0004.json")
        self.assertFalse(os.path.exists(path))
        self.assertFalse(os.path.exists(os.path.join(self.home, "state", "seen", "sess-stop-0004")))
        # a slow async `stop` from before the end must not resurrect the session, nor pop up
        self.hook(now=NOW + 5).handle("stop", payload("payload_stop.json"))
        self.assertFalse(os.path.exists(path))
        self.assertEqual(self.queued(), [])
        # resuming the same session later works
        self.hook(now=NOW + 20).handle("prompt", payload("payload_stop.json", prompt="again"))
        self.assertTrue(os.path.exists(path))

    def test_older_event_does_not_overwrite_newer_state(self):
        paths = notify.Paths(self.home)
        notify.ensure_dirs(paths)
        self.assertTrue(notify.write_session(paths, "s", {"state": "thinking"}, 200.0))
        self.assertFalse(notify.write_session(paths, "s", {"state": "wrote"}, 100.0))
        self.assertEqual(self.session("s")["state"], "thinking")
        self.assertTrue(notify.write_session(paths, "s", {"state": "wrote"}, 300.0))
        self.assertEqual((self.session("s")["state"], self.session("s")["updated_at"]), ("wrote", 300.0))

    def test_late_stop_after_prompt_is_superseded(self):
        self.hook({"language": "en"}, now=NOW + 2).handle("prompt", payload("payload_stop.json", prompt="next"))
        self.hook(now=NOW).handle("stop", payload("payload_stop.json"))
        self.assertEqual(self.session("sess-stop-0004")["state"], "thinking")
        self.assertEqual(self.queued(), [])

    def test_session_id_cannot_escape_the_sessions_folder(self):
        self.hook({"language": "en"}).handle("prompt", payload("payload_stop.json", session_id="../../evil"))
        self.assertEqual(os.listdir(os.path.join(self.home, "state", "sessions")).count("evil.json"), 0)
        self.assertFalse(os.path.exists(os.path.join(self._tmp.name, "evil.json")))

    def test_home_directory_is_not_named_after_the_user(self):
        hook = self.hook({"language": "en"})
        home_dir = os.path.expanduser("~")
        hook.handle("prompt", payload("payload_stop.json", cwd=home_dir, prompt="x"))
        self.assertEqual(self.session("sess-stop-0004")["project"], "Home")


class Housekeeping(HookTestCase):
    def test_old_queue_files_are_deleted(self):
        paths = notify.Paths(self.home)
        notify.ensure_dirs(paths)
        old, fresh = os.path.join(paths.queue, "old.json"), os.path.join(paths.queue, "fresh.json")
        for p in (old, fresh):
            open(p, "w").close()
        os.utime(old, (NOW - 7200, NOW - 7200))
        os.utime(fresh, (NOW - 60, NOW - 60))
        self.hook({"language": "en"}).handle("session-end", payload("payload_stop.json"))
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(fresh))


class PrivacyAndLog(HookTestCase):
    def test_permissions_and_log_has_no_message_text(self):
        self.hook({"language": "en"}).handle("prompt", payload("payload_stop.json", prompt="secret request"))
        self.hook(now=NOW + 60).handle("stop", payload("payload_stop.json",
                                                       last_assistant_message="secret answer"))
        state = os.path.join(self.home, "state")
        for root, dirs, files in os.walk(state):
            for d in dirs:
                self.assertEqual(stat.S_IMODE(os.stat(os.path.join(root, d)).st_mode), 0o700, d)
            for f in files:
                self.assertEqual(stat.S_IMODE(os.stat(os.path.join(root, f)).st_mode), 0o600, f)
        self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o700)
        log = self.log_text()
        self.assertNotIn("secret", log)
        self.assertIn("stop", log)

    def test_log_rotates_at_one_megabyte(self):
        paths = notify.Paths(self.home)
        notify.ensure_dirs(paths)
        with open(paths.log, "w") as f:
            f.write("x" * (notify.LOG_MAX_BYTES + 1))
        notify.log(paths, NOW, "p", "s", "stop", "popup")
        self.assertTrue(os.path.exists(paths.log + ".1"))
        self.assertLess(os.path.getsize(paths.log), 1000)


class MainEntry(unittest.TestCase):
    def test_main_never_raises_on_garbage(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"CCNOTIFY_HOME": os.path.join(tmp, "h")}
            for raw in ("", "not json", "[1,2,3]", '{"cwd": 5, "session_id": null}'):
                self.assertEqual(notify.main(["stop"], io.StringIO(raw), env, FakeRun(), NOW), 0)
            self.assertEqual(notify.main(["bogus"], io.StringIO("{}"), env, FakeRun(), NOW), 0)

    def test_wrapper_script_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = os.path.join(tmp, "ccnotify")
            fake_bin = os.path.join(tmp, "bin")
            os.makedirs(os.path.join(home, "CCNotify.app"))
            os.makedirs(fake_bin)
            record = os.path.join(tmp, "open-args.txt")
            with open(os.path.join(fake_bin, "open"), "w") as f:
                f.write('#!/bin/sh\necho "$@" > "%s"\n' % record)
            os.chmod(os.path.join(fake_bin, "open"), 0o755)
            with open(os.path.join(home, "config.json"), "w") as f:
                json.dump({"language": "en"}, f)
            env = dict(os.environ, CCNOTIFY_HOME=home, PATH=fake_bin + ":/usr/bin:/bin",
                       __CFBundleIdentifier="com.microsoft.VSCodeInsiders")
            with open(fixture("payload_permission.json"), "rb") as stdin:
                result = subprocess.run([os.path.join(HOOKS, "notify.sh"), "notification"], stdin=stdin,
                                        env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            with open(record, encoding="utf-8") as f:
                args = f.read().split()
            self.assertEqual(args[:3], ["-n", "-g", os.path.join(home, "CCNotify.app")])
            queue_dir = os.path.join(home, "state", "queue")
            with open(os.path.join(queue_dir, os.listdir(queue_dir)[0]), encoding="utf-8") as f:
                popup = json.load(f)
            self.assertEqual(popup["host"], "com.microsoft.VSCodeInsiders")


if __name__ == "__main__":
    unittest.main()
