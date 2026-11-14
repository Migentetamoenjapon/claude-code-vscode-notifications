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
