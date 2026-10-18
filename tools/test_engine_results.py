"""Verify native-result handling rejects failures that have no failing route."""

import importlib.util
from pathlib import Path
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "tests/engine/run.py"
SPEC = importlib.util.spec_from_file_location("click2move_native_runner", RUNNER)
ENGINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ENGINE)


class NativeResultTests(unittest.TestCase):
    def parse(self, output, interval=1):
        return ENGINE.parse_vulcanus_result(output, interval, Path("native/run.log"))

    def test_complete_success_is_accepted_for_the_requested_interval(self):
        for interval in (1, 10):
            summary = f"64 interval={interval} reachable=10 failures=0"
            output = ("Running update 0\n"
                      "C2M_VULCANUS OK route 1 result=C ticks=198 hits=0 bumps=0 recoveries=0\n"
                      f"C2M_NATIVE_VULCANUS_DONE {summary}\nPerformed 40000 updates\n")
            self.assertEqual(self.parse(output, interval), summary)

    def test_insufficient_coverage_fails_without_any_failed_route(self):
        # Captured failure shape: the old runner printed FAIL then returned success.
        output = ("C2M_VULCANUS OK route 1 result=C ticks=198\n"
                  "C2M_VULCANUS UNREACHABLE route 2 result=F ticks=3\n"
                  "C2M_NATIVE_VULCANUS_DONE 8 interval=1 reachable=2 failures=1\n")
        with self.assertRaisesRegex(RuntimeError, "Native Vulcanus failed"):
            self.parse(output)

    def test_nonzero_final_failures_always_fail(self):
        with self.assertRaisesRegex(RuntimeError, "failures=1"):
            self.parse("C2M_NATIVE_VULCANUS_DONE 64 interval=1 reachable=10 failures=1")

    def test_route_failure_cannot_hide_behind_a_success_summary(self):
        output = ("C2M_VULCANUS FAIL route 47 result=C bumps=1 recoveries=1\n"
                  "C2M_NATIVE_VULCANUS_DONE 64 interval=1 reachable=10 failures=0")
        with self.assertRaisesRegex(RuntimeError, "route 47"):
            self.parse(output)

    def test_missing_duplicate_or_malformed_summary_fails(self):
        summary = "C2M_NATIVE_VULCANUS_DONE 64 interval=1 reachable=10 failures=0"
        for output in ("", summary + "\n" + summary, summary + " trailing text",
                       "C2M_NATIVE_VULCANUS_DONE 64 interval=1 reachable=10 failures=unknown"):
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                self.parse(output)

    def test_inconsistent_interval_or_coverage_fails(self):
        for summary in ("64 interval=10 reachable=10 failures=0",
                        "64 interval=1 reachable=2 failures=0",
                        "8 interval=1 reachable=10 failures=0"):
            with self.subTest(summary=summary), self.assertRaises(RuntimeError):
                self.parse("C2M_NATIVE_VULCANUS_DONE " + summary)


if __name__ == "__main__":
    unittest.main()
