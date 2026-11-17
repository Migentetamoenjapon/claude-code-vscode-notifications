"""Smoke tests for statusline/statusline.py (standard library only).

Run:  python3 -m unittest discover -s tests -p 'test_statusline.py'
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "statusline", "statusline.py")
ANSI = re.compile(r"\033\[[0-9;]*m")


def strip(s):
    return ANSI.sub("", s)


class StatuslineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write_config(self, cfg):
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump(cfg, f)

    def run_script(self, stdin_text, columns=None):
        env = dict(os.environ, CCNOTIFY_HOME=self.home)
        env.pop("COLUMNS", None)
        if columns:
            env["COLUMNS"] = str(columns)
        p = subprocess.run([sys.executable, SCRIPT], input=stdin_text, capture_output=True,
                           text=True, env=env, timeout=20)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stderr, "")
        self.assertTrue(p.stdout.endswith("\n"))
        lines = p.stdout.splitlines()
        self.assertEqual(len(lines), 1, p.stdout)
        return strip(lines[0])

    def sample_with_limits(self):
        transcript = os.path.join(self.home, "t.jsonl")
        with open(transcript, "w") as f:
            f.write(json.dumps({"type": "assistant", "message": {
                "id": "m1", "usage": {"input_tokens": 1200, "cache_creation_input_tokens": 3000,
                                      "output_tokens": 800}}}).replace(": ", ":").replace(", ", ",") + "\n")
        now = time.time()
        return {
            "session_id": "sess-1", "transcript_path": transcript,
            "workspace": {"project_dir": "/Users/you/my-project"},
            "model": {"display_name": "Sonnet"}, "effort": {"level": "high"},
            "context_window": {"used_percentage": 52.3},
            "cost": {"total_cost_usd": 1.25},
            "rate_limits": {"five_hour": {"used_percentage": 12, "resets_at": now + 3600},
                            "seven_day": {"used_percentage": 45, "resets_at": now + 3 * 86400}},
        }

    def project_of(self, project_dir, names=None):
        cfg = {"language": "en"}
        if names is not None:
            cfg["project_names"] = names
        self.write_config(cfg)
        return self.run_script(json.dumps({"workspace": {"project_dir": project_dir},
                                           "model": {"display_name": "Opus"}})).split(" ")[0]

    def test_project_name_plain_worktree_and_slash(self):
        self.assertEqual(self.project_of("/work/my-app"), "my-app")
        self.assertEqual(self.project_of("/work/my-app/"), "my-app")
        self.assertEqual(self.project_of("/work/my-app/.claude/worktrees/kit"), "my-app")
        self.assertEqual(self.project_of("/work/my-app/.claude/worktrees/kit/"), "my-app")

    def test_project_names_nicknames(self):
        names = {"long-repository-name": "repo"}
        self.assertEqual(self.project_of("/work/long-repository-name", names), "repo")
        self.assertEqual(self.project_of("/work/long-repository-name/.claude/worktrees/base", names), "repo")
        self.assertEqual(self.project_of("/work/my-app", names), "my-app")

    def test_malformed_project_names_are_ignored(self):
        for bad in ([1], 5, "repo", None):
            self.assertEqual(self.project_of("/work/my-app", bad), "my-app", bad)
        for bad in (5, ["x"], "", "  ", None):
            self.assertEqual(self.project_of("/work/my-app", {"my-app": bad}), "my-app", bad)

    def test_minimal_input(self):
        out = self.run_script(json.dumps({"model": {"display_name": "Opus"}}))
        self.assertIn("Opus", out)

    def test_empty_object_and_bad_json(self):
        self.assertTrue(self.run_script("{}"))
        self.assertTrue(self.run_script("not json"))
        self.assertTrue(self.run_script(""))
        self.assertTrue(self.run_script("[1, 2]"))

    def test_wrong_types_do_not_crash(self):
        weird = {"workspace": "x", "model": 5, "context_window": {"used_percentage": "a"},
                 "rate_limits": {"five_hour": None, "seven_day": {"used_percentage": "n"}},
                 "cost": {"total_cost_usd": "free"}, "session_id": 7}
        self.assertTrue(self.run_script(json.dumps(weird)))

    def test_with_rate_limits_english(self):
        self.write_config({"language": "en"})
        out = self.run_script(json.dumps(self.sample_with_limits()))
        for piece in ("my-project", "Sonnet high", "ctx 52%", "5h 12%", "wk 45%", "session"):
            self.assertIn(piece, out)
        self.assertNotIn("$", out)            # no plan configured -> no dollar figures

    def test_plan_dollars_and_spanish(self):
        self.write_config({"language": "es", "statusline": {"plan_monthly_usd": 100}})
        out = self.run_script(json.dumps(self.sample_with_limits()))
        self.assertIn("sesión", out)
        self.assertIn("sem 45%", out)
        self.assertRegex(out, r"\$\d+\.\d\d/\$23")

    def test_narrow_columns_trims(self):
        self.write_config({"language": "en", "statusline": {"plan_monthly_usd": 100}})
        sample = json.dumps(self.sample_with_limits())
        wide = self.run_script(sample, columns=200)
        narrow = self.run_script(sample, columns=40)
        self.assertLess(len(narrow), len(wide))
        self.assertIn("wk 45%", narrow)       # the weekly % is never dropped

    # -- numbers handed to the menu bar app

    def state_path(self, *parts):
        return os.path.join(self.home, "state", *parts)

    def test_context_file_written_with_pct(self):
        sample = self.sample_with_limits()
        sample["session_id"] = "sess/odd id"
        self.run_script(json.dumps(sample))
        path = self.state_path("context", "sess_odd_id.json")   # same safe-name rule as notify.py
        with open(path) as f:
            saved = json.load(f)
        self.assertEqual(saved["pct"], 52.3)
        self.assertAlmostEqual(saved["at"], time.time(), delta=60)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.state_path("context")).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.state_path()).st_mode & 0o777, 0o700)

    def test_usage_file_written_with_both_windows(self):
        sample = self.sample_with_limits()
        self.run_script(json.dumps(sample))
        path = self.state_path("usage.json")
        with open(path) as f:
            saved = json.load(f)
        limits = sample["rate_limits"]
        self.assertEqual(saved["five_hour"], {"pct": 12.0, "resets_at": limits["five_hour"]["resets_at"]})
        self.assertEqual(saved["seven_day"], {"pct": 45.0, "resets_at": limits["seven_day"]["resets_at"]})
        self.assertAlmostEqual(saved["at"], time.time(), delta=60)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_usage_keeps_the_newer_window_and_the_higher_pct(self):
        sample = self.sample_with_limits()
        self.run_script(json.dumps(sample))
        stale = json.loads(json.dumps(sample))                 # another session with an older snapshot
        stale["rate_limits"]["five_hour"]["used_percentage"] = 3
        self.run_script(json.dumps(stale))
        with open(self.state_path("usage.json")) as f:
            self.assertEqual(json.load(f)["five_hour"]["pct"], 12.0)
        newer = json.loads(json.dumps(sample))                 # the 5-hour window rolled over
        newer["rate_limits"]["five_hour"] = {"used_percentage": 1,
                                             "resets_at": sample["rate_limits"]["five_hour"]["resets_at"] + 18000}
        self.run_script(json.dumps(newer))
        with open(self.state_path("usage.json")) as f:
            five = json.load(f)["five_hour"]
        self.assertEqual((five["pct"], five["resets_at"]),
                         (1.0, sample["rate_limits"]["five_hour"]["resets_at"] + 18000))

    def test_one_window_only_and_missing_reset(self):
        self.run_script(json.dumps({"session_id": "s1", "model": {"display_name": "Opus"},
                                    "rate_limits": {"five_hour": {"used_percentage": 20}}}))
        with open(self.state_path("usage.json")) as f:
            saved = json.load(f)
        self.assertEqual(saved["five_hour"], {"pct": 20.0, "resets_at": None})
        self.assertNotIn("seven_day", saved)
        self.assertFalse(os.path.exists(self.state_path("context", "s1.json")))   # no context % in that input

    def test_nothing_written_when_data_is_absent(self):
        self.run_script(json.dumps({"session_id": "s1", "model": {"display_name": "Opus"}}))
        self.assertFalse(os.path.exists(self.state_path("usage.json")))
        self.assertFalse(os.path.exists(self.state_path("context")))
        self.run_script(json.dumps({"model": {"display_name": "Opus"}, "context_window": {"used_percentage": 10}}))
        self.assertFalse(os.path.exists(self.state_path("context")))               # no session id: no file name

    def test_malformed_input_writes_nothing_and_does_not_crash(self):
        for bad in ("not json", "", "[1, 2]", json.dumps({"session_id": 7, "context_window": "x",
                                                          "rate_limits": {"five_hour": {"used_percentage": "a"}}})):
            self.run_script(bad)
        self.assertFalse(os.path.exists(self.state_path("usage.json")))
        self.assertFalse(os.path.exists(self.state_path("context")))

    def test_unwritable_state_does_not_crash_the_line(self):
        os.makedirs(self.state_path())
        with open(self.state_path("context"), "w") as f:       # a file where the folder should be
            f.write("x")
        out = self.run_script(json.dumps(self.sample_with_limits()))
        self.assertIn("ctx 52%", out)

    def test_no_ticker_means_no_network_files(self):
        self.run_script(json.dumps(self.sample_with_limits()))
        cache = os.path.join(self.home, "state", "statusline")
        self.assertFalse([n for n in os.listdir(cache) if n.startswith("ticker")])

    def test_ticker_reads_local_cache(self):
        # A fresh cached quote is shown without any network access.
        self.write_config({"language": "en", "statusline": {"ticker": "ABC", "ticker_refresh_closed_s": 99999}})
        cache = os.path.join(self.home, "state", "statusline")
        os.makedirs(cache)
        with open(os.path.join(cache, "ticker-ABC.json"), "w") as f:
            json.dump({"chart": {"result": [{"meta": {
                "regularMarketPrice": 101.5, "chartPreviousClose": 100.0,
                "regularMarketTime": 1700000000}}]}}, f)
        out = self.run_script(json.dumps({"model": {"display_name": "Opus"}}))
        self.assertIn("ABC 101.50 +1.50%", out)


if __name__ == "__main__":
    unittest.main()
