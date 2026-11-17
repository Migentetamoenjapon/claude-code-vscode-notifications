"""The Colors switch of the menu bar's options page: it writes popup.style (color | mono) into config.json.

Runs the built menu bar app through its test hook CCNOTIFY_TEST_COLORS=on|off, so it needs the binary:
    scripts/build.sh /tmp/ccn-build
    CCNOTIFY_MENUBAR_BIN="/tmp/ccn-build/CCNotify Sessions.app/Contents/MacOS/ccnotify-sessions" \
        python3 -m unittest tests.test_menubar_colors
Without CCNOTIFY_MENUBAR_BIN the tests are skipped (building the Swift app takes minutes; CI builds it separately).
"""
import json
import os
import stat
import subprocess
import tempfile
import unittest

BIN = os.environ.get("CCNOTIFY_MENUBAR_BIN", "")


@unittest.skipUnless(BIN and os.path.exists(BIN), "set CCNOTIFY_MENUBAR_BIN to the built ccnotify-sessions binary")
class ColorsSwitchTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ccnotify-colors-")
        self.config = os.path.join(self.home, "config.json")

    def run_hook(self, value):
        env = dict(os.environ, CCNOTIFY_HOME=self.home, CCNOTIFY_TEST_COLORS=value)
        return subprocess.run([BIN], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, timeout=30)

    def read(self):
        with open(self.config) as f:
            return json.load(f)

    def test_creates_the_file_when_missing(self):
        self.assertEqual(self.run_hook("off").returncode, 0)
        self.assertEqual(self.read(), {"popup": {"style": "mono"}})
        mode = stat.S_IMODE(os.stat(self.config).st_mode)
        self.assertEqual(mode, 0o600)

    def test_on_writes_color(self):
        self.run_hook("off")
        self.assertEqual(self.run_hook("on").returncode, 0)
        self.assertEqual(self.read(), {"popup": {"style": "color"}})

    def test_keeps_every_other_key(self):
        original = {"language": "es", "popup": {"seconds": 30, "style": "neutral", "width": 500},
                    "sounds": {"done": {"sound": "Glass", "volume": 0.5}},
                    "quiet_hours": {"enabled": True, "from": "22:00", "to": "07:00"}}
        with open(self.config, "w") as f:
            json.dump(original, f)
        self.assertEqual(self.run_hook("off").returncode, 0)
        expected = json.loads(json.dumps(original))
        expected["popup"]["style"] = "mono"
        self.assertEqual(self.read(), expected)
        self.assertEqual(self.run_hook("on").returncode, 0)
        expected["popup"]["style"] = "color"
        self.assertEqual(self.read(), expected)

    def test_adds_popup_when_the_file_has_none(self):
        with open(self.config, "w") as f:
            json.dump({"language": "en"}, f)
        self.run_hook("off")
        self.assertEqual(self.read(), {"language": "en", "popup": {"style": "mono"}})

    def test_never_overwrites_a_file_that_is_not_json(self):
        with open(self.config, "w") as f:
            f.write("{ not json")
        self.assertEqual(self.run_hook("off").returncode, 2)
        with open(self.config) as f:
            self.assertEqual(f.read(), "{ not json")

    def test_indent_is_two_spaces(self):
        self.run_hook("off")
        with open(self.config) as f:
            self.assertIn('\n  "popup" : {\n    "style" : "mono"\n  }', f.read())


if __name__ == "__main__":
    unittest.main()
