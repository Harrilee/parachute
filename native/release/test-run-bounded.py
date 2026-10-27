#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name('run-bounded.py')


class PackagingProcessTests(unittest.TestCase):
    def run_command(self, root, source, timeout=5):
        log = Path(root) / 'command.log'
        result = subprocess.run([sys.executable, str(RUNNER), '--timeout', str(timeout), '--log', str(log),
                                 '--', sys.executable, '-c', source], capture_output=True, text=True, timeout=15)
        return result, log.read_text()

    def test_success_and_output_are_retained(self):
        with tempfile.TemporaryDirectory() as root:
            result, log = self.run_command(root, "print('packaging output')")
            self.assertEqual(result.returncode, 0)
            self.assertIn('packaging output', log)
            self.assertEqual(json.loads(log.splitlines()[-1])['exitCode'], 0)

    def test_nonzero_exit_is_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            result, log = self.run_command(root, "import sys; print('package failed'); sys.exit(7)")
            self.assertEqual(result.returncode, 7)
            self.assertIn('package failed', log)

    def test_timeout_kills_own_group_and_preserves_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            with tempfile.TemporaryDirectory() as root:
                child_marker = Path(root) / 'child-survived'
                source = ('import signal,subprocess,sys,time; '
                          'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                          'subprocess.Popen([sys.executable,"-c",'
                          + repr('import os,time,pathlib; print("childpid=" + str(os.getpid()), flush=True); time.sleep(7); pathlib.Path(' + repr(str(child_marker)) + ').touch()')
                          + ']); time.sleep(30)')
                result, log = self.run_command(root, source, timeout=0.2)
                self.assertEqual(result.returncode, 124)
                self.assertIn('Timed-out process:', log)
                self.assertIsNone(unrelated.poll())
                child_pid = next(line.split('=', 1)[1] for line in log.splitlines() if line.startswith('childpid='))
                child_status = subprocess.run(['ps', '-o', 'stat=', '-p', child_pid], text=True, capture_output=True).stdout.strip()
                self.assertTrue(not child_status or child_status.startswith('Z'), child_status)
                self.assertFalse(child_marker.exists())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
