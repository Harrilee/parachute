#!/usr/bin/env python3
"""Exercise ticket-network retries without signing or contacting Apple."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("stapler_retry", Path(__file__).with_name("stapler-retry.py"))
stapler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stapler)


def response(code=0, output="The validate action worked!"):
    return subprocess.CompletedProcess([], code, output.encode())


NETWORK = 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'


class StaplerRetryTests(unittest.TestCase):
    def invoke(self, responses, operation="validate"):
        with patch.object(stapler.subprocess, "run", side_effect=responses) as run, \
                patch.object(stapler.time, "sleep") as sleep, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = stapler.run_stapler(operation, "/tmp/app with spaces.app")
        return status, run, sleep

    def test_success_requires_one_call_and_preserves_argument_array(self):
        status, run, sleep = self.invoke([response()])
        self.assertEqual(status, 0)
        self.assertEqual(run.call_args.args[0], ["xcrun", "stapler", "validate", "/tmp/app with spaces.app"])
        self.assertEqual(run.call_args.kwargs["timeout"], 120)
        sleep.assert_not_called()

    def test_transient_network_retries_staple_then_requires_real_success(self):
        status, run, sleep = self.invoke([response(68, NETWORK), response()], "staple")
        self.assertEqual(status, 0)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(5)

    def test_repeated_network_error_stops_after_three_attempts(self):
        status, run, sleep = self.invoke([response(68, NETWORK)] * 3)
        self.assertEqual(status, 68)
        self.assertEqual(run.call_count, 3)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [5, 15])

    def test_invalid_ticket_or_signature_does_not_retry(self):
        for code, output in [(68, "Could not validate ticket"),
                             (65, "The signature is invalid"),
                             (68, 'Error Domain=NSURLErrorDomain Code=-1202 "Certificate untrusted"'),
                             (65, NETWORK)]:
            with self.subTest(code=code, output=output):
                status, run, sleep = self.invoke([response(code, output)])
                self.assertEqual(status, code)
                self.assertEqual(run.call_count, 1)
                sleep.assert_not_called()

    def test_network_failure_followed_by_invalid_ticket_fails_closed(self):
        status, run, sleep = self.invoke([response(68, NETWORK), response(65, "Invalid ticket")])
        self.assertEqual(status, 65)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(5)

    def test_deadline_fails_instead_of_claiming_success(self):
        status, run, sleep = self.invoke([subprocess.TimeoutExpired(["xcrun"], 120, output=b"partial")])
        self.assertEqual(status, 124)
        self.assertEqual(run.call_count, 1)
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
