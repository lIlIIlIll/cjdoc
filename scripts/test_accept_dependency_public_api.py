"""Public CLI preparation boundaries; no compiler or generation is exercised here."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('accept_dependency_public_api.py')
CALLER = SCRIPT.parent.parent / 'tests/fixtures/projects/dependency_public_api/src/main.cj'


class PublicApiAcceptancePreparationTests(unittest.TestCase):
    def prepare(self, output, *options):
        environment = os.environ.copy()
        # Preparation must not need compiler/package-manager executables or the SDK.
        environment['PATH'] = ''
        environment.pop('CANGJIE_STDX_PATH', None)
        return subprocess.run([sys.executable, str(SCRIPT), '--binary', sys.executable,
            '--output', str(output), '--prepare-only', *options], env=environment,
            capture_output=True, text=True, timeout=30)

    def test_preparation_writes_real_separate_caller_without_claiming_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'prepared'
            result = self.prepare(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((output / 'prepared.json').read_text(encoding='utf-8'))
            self.assertEqual(report['state'], 'prepared')
            self.assertEqual(report['verification'], 'not run')
            self.assertEqual(report['callerSourceSha256'], hashlib.sha256(CALLER.read_bytes()).hexdigest())
            self.assertEqual((output / 'public-caller/src/main.cj').read_bytes(), CALLER.read_bytes())
            self.assertFalse((output / 'evidence.json').exists())
            self.assertFalse((output / 'public-caller/bin').exists())
            self.assertFalse((output / 'public-artifacts').exists())
            self.assertEqual(list((output / 'evidence').iterdir()), [])
            self.assertEqual(len(list(output.glob('library-*/src/api.cj'))), 2)
            self.assertEqual(len(list(output.glob('consumer-*/src/api.cj'))), 2)
            self.assertNotIn('PASS:', result.stdout)

    def test_existing_output_is_never_reused_or_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'existing'
            output.mkdir()
            sentinel = output / 'user-owned'
            sentinel.write_text('keep', encoding='utf-8')
            result = self.prepare(output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('new task-private directory', result.stderr)
            self.assertEqual(sentinel.read_text(encoding='utf-8'), 'keep')
            self.assertEqual(list(output.iterdir()), [sentinel])

    def test_expected_binary_pin_is_checked_before_claiming_a_prepared_caller(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'wrong-binary'
            result = self.prepare(output, '--binary-sha256', '0' * 64)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('expected complete bytes', result.stderr)
            self.assertFalse((output / 'prepared.json').exists())
            self.assertFalse((output / 'public-caller').exists())
            self.assertFalse((output / 'evidence.json').exists())


if __name__ == '__main__':
    unittest.main()
