"""Tests for hooks/ccnotify_transcript.py (the fragile, undocumented-format parsing)."""
import calendar
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hooks"))

import ccnotify_transcript as tp  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")


def fixture(name):
    return os.path.join(FIXTURES, name)


def epoch(stamp):
    return calendar.timegm(__import__("time").strptime(stamp, "%Y-%m-%dT%H:%M:%S"))


class LastAssistantText(unittest.TestCase):
    def test_finds_newest_text_block(self):
        text = tp.last_assistant_text(fixture("transcript_text.jsonl"))
        self.assertTrue(text.startswith("All **tests** pass now."))

    def test_skips_assistant_entries_without_text(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write('{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}\n')
            f.write('{"type":"assistant","message":{"content":[{"type":"tool_use","id":"x","name":"Bash"}]}}\n')
            path = f.name
        self.addCleanup(os.remove, path)
        self.assertEqual(tp.last_assistant_text(path), "first")

    def test_missing_file_and_garbage_lines(self):
        self.assertEqual(tp.last_assistant_text("/nonexistent/x.jsonl"), "")
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write("not json\n[1,2]\n")
            path = f.name
        self.addCleanup(os.remove, path)
        self.assertEqual(tp.last_assistant_text(path), "")

    def test_tail_read_drops_partial_first_line(self):
        lines = tp.read_tail_lines(fixture("transcript_text.jsonl"), 150)
        self.assertTrue(all(line.startswith("{") and line.endswith("}") for line in lines))


class Interrupts(unittest.TestCase):
    def test_interrupted(self):
        self.assertTrue(tp.was_interrupted(fixture("transcript_interrupted.jsonl")))

    def test_normal_turn_is_not_interrupted(self):
        self.assertFalse(tp.was_interrupted(fixture("transcript_text.jsonl")))

    def test_missing_file(self):
        self.assertFalse(tp.was_interrupted("/nonexistent/x.jsonl"))


class AssistantEntryAfter(unittest.TestCase):
    def test_newest_assistant_entry_is_compared_with_the_time(self):
        path = fixture("transcript_text.jsonl")  # last assistant entry: 2026-11-14T11:58:30.000Z
        self.assertTrue(tp.assistant_entry_after(path, epoch("2026-11-14T11:58:00")))
        self.assertTrue(tp.assistant_entry_after(path, epoch("2026-11-14T11:58:29")))
        self.assertFalse(tp.assistant_entry_after(path, epoch("2026-11-14T11:58:30")))
        self.assertFalse(tp.assistant_entry_after(path, epoch("2026-11-14T12:00:00")))

    def test_fractions_of_a_second_count(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write('{"type":"assistant","message":{"content":[]},"timestamp":"2026-11-15T21:37:10.848Z"}\n')
            path = f.name
        self.addCleanup(os.remove, path)
        base = epoch("2026-11-15T21:37:10")
        self.assertTrue(tp.assistant_entry_after(path, base + 0.5))
        self.assertFalse(tp.assistant_entry_after(path, base + 0.9))

    def test_user_entries_and_unreadable_stamps_do_not_count(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write('{"type":"assistant","message":{"content":[]},"timestamp":"2026-11-15T10:00:00.000Z"}\n')
            f.write('{"type":"user","message":{"content":"hi"},"timestamp":"2026-11-15T11:00:00.000Z"}\n')
            f.write('{"type":"assistant","message":{"content":[]},"timestamp":"garbage"}\n')
            f.write('{"type":"assistant","isSidechain":true,"message":{"content":[]},'
                    '"timestamp":"2026-11-15T12:00:00.000Z"}\n')
            f.write("not json\n")
            path = f.name
        self.addCleanup(os.remove, path)
        self.assertTrue(tp.assistant_entry_after(path, epoch("2026-11-15T09:00:00")))
        self.assertFalse(tp.assistant_entry_after(path, epoch("2026-11-15T10:30:00")))  # a user entry is no answer

    def test_only_the_tail_is_read(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write('{"type":"assistant","message":{"content":[]},"timestamp":"2026-11-15T10:00:00.000Z"}\n')
            f.write('{"type":"user","message":{"content":"%s"}}\n' % ("x" * 5000))
            path = f.name
        self.addCleanup(os.remove, path)
        self.assertTrue(tp.assistant_entry_after(path, epoch("2026-11-15T09:00:00")))
        self.assertFalse(tp.assistant_entry_after(path, epoch("2026-11-15T09:00:00"), max_bytes=1000))

    def test_missing_file_and_bad_arguments(self):
        self.assertFalse(tp.assistant_entry_after("/nonexistent/x.jsonl", 0))
        self.assertFalse(tp.assistant_entry_after("", 0))
        self.assertFalse(tp.assistant_entry_after(fixture("transcript_text.jsonl"), None))


class BackgroundTasks(unittest.TestCase):
    def test_one_of_two_still_running(self):
        now = epoch("2026-11-14T12:05:00")
        self.assertEqual(tp.running_background_tasks(fixture("transcript_bg_mixed.jsonl"), now), 1)

    def test_stale_task_does_not_count(self):
        now = epoch("2026-11-14T13:30:00")  # launched 90 min ago, no signal since
        self.assertEqual(tp.running_background_tasks(fixture("transcript_bg_mixed.jsonl"), now), 0)

    def test_finished_task_does_not_count(self):
        now = epoch("2026-11-14T12:02:00")
        self.assertEqual(tp.running_background_tasks(fixture("transcript_bg_finished.jsonl"), now), 0)

    def test_no_tasks_in_plain_transcript(self):
        self.assertEqual(tp.running_background_tasks(fixture("transcript_text.jsonl")), 0)

    def test_empty_and_missing(self):
        self.assertEqual(tp.running_background_tasks(""), 0)
        self.assertEqual(tp.running_background_tasks("/nonexistent/x.jsonl"), 0)

    def test_recent_agent_transcript_keeps_task_alive(self):
        # launched long ago, but the agent's own transcript was written just now
        with tempfile.TemporaryDirectory() as tmp:
            transcript = os.path.join(tmp, "sess.jsonl")
            with open(fixture("transcript_bg_mixed.jsonl"), encoding="utf-8") as src:
                content = src.read().replace("<tool-use-id>toolu_AAA</tool-use-id>", "")
            with open(transcript, "w", encoding="utf-8") as f:
                f.write(content)
            os.makedirs(os.path.join(tmp, "sess", "subagents"))
            with open(os.path.join(tmp, "sess", "subagents", "agent-a111.jsonl"), "w") as f:
                f.write("{}\n")
            self.assertEqual(tp.running_background_tasks(transcript, os.path.getmtime(f.name) + 5), 1)


class Notifications(unittest.TestCase):
    def test_classify_typed(self):
        c = tp.classify_notification
        self.assertEqual(c({"notification_type": "permission_prompt"}), "permission")
        self.assertEqual(c({"notification_type": "elicitation_dialog"}), "question")
        self.assertEqual(c({"notification_type": "elicitation_url_dialog"}), "question")
        self.assertEqual(c({"notification_type": "agent_needs_input"}), "agent")

    def test_classify_ignored(self):
        c = tp.classify_notification
        for ntype in ("idle_prompt", "auth_success", "agent_completed", "something_new"):
            self.assertIsNone(c({"notification_type": ntype, "message": "x"}))

    def test_classify_untyped_by_wording(self):
        c = tp.classify_notification
        self.assertEqual(c({"message": "Claude needs your permission to use Edit"}), "permission")
        self.assertIsNone(c({"message": "Claude is waiting for your input"}))
        self.assertIsNone(c({}))

    def test_is_idle_notification(self):
        idle = tp.is_idle_notification
        self.assertTrue(idle({"notification_type": "idle_prompt", "message": "anything"}))
        self.assertTrue(idle({"message": "Claude is waiting for your input"}))
        self.assertFalse(idle({"message": "Claude is waiting for your input, please"}))
        self.assertFalse(idle({"notification_type": "permission_prompt",
                               "message": "Claude is waiting for your input"}))
        self.assertFalse(idle({"notification_type": "auth_success"}))
        self.assertFalse(idle({}))

    def test_permission_request_from_data(self):
        tool, detail = tp.permission_request({
            "notification_data": {"tool_name": "Bash", "tool_input": {"command": "ls", "description": "List"}}})
        self.assertEqual((tool, detail), ("Bash", "List"))  # description wins over command

    def test_permission_request_mcp_tool_name(self):
        tool, _ = tp.permission_request({"notification_data": {"tool_name": "mcp__server__do_thing"}})
        self.assertEqual(tool, "do_thing")

    def test_permission_request_from_message(self):
        tool, detail = tp.permission_request({"message": "Claude needs your permission to use Edit"})
        self.assertEqual((tool, detail), ("Edit", ""))

    def test_permission_request_nothing(self):
        self.assertEqual(tp.permission_request({"message": "hello", "notification_data": "bad"}), ("", ""))

    def test_split_agent_question(self):
        self.assertEqual(tp.split_agent_question("reviewer needs your input: Which branch?"),
                         ("reviewer", "Which branch?"))
        self.assertEqual(tp.split_agent_question("plain question"), ("", "plain question"))
        self.assertEqual(tp.split_agent_question(""), ("", ""))


if __name__ == "__main__":
    unittest.main()
