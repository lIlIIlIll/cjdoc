"""Diagnostic boundaries; fixtures do not prove a native failure or a fix."""
import hashlib
import io
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import release076_diagnostic as diagnostic


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.archive = self.root / 'candidate.tar'
        self.marker = self.root / 'marker.json'
        self.binary = b'fixture executable bytes, never executed'
        self.manifest = {'checkoutCommit': diagnostic.COMMIT, 'checkoutTree': diagnostic.TREE,
                         'mainBinary': {'sha256': hashlib.sha256(self.binary).hexdigest()}}
        self.members = {'target/release/bin/main': self.binary,
            'target/release/bin/chir-worker-main': b'fixture worker',
            'target/ci-build/build-manifest.json': json.dumps(self.manifest).encode()}
        self.write_archive()
        self.patched = patch.multiple(diagnostic, TAR_SHA=diagnostic.sha(self.archive),
            TAR_SIZE=self.archive.stat().st_size, BINARY_SHA=hashlib.sha256(self.binary).hexdigest())
        self.patched.start()
        self.addCleanup(self.patched.stop)
        self.marker.write_text(json.dumps({'commit': diagnostic.COMMIT, 'tree': diagnostic.TREE,
            'runId': 40536370055, 'runAttempt': 1, 'repository': 'lIlIIlIll/cjdoc',
            'candidateTarSha256': diagnostic.TAR_SHA, 'candidateTarSize': diagnostic.TAR_SIZE,
            'schemaVersion': 'cjdoc.linux-candidate-ready/1',
            'artifactName': 'cjdoc-linux-candidate-40536370055-1'}))

    def write_archive(self, symlink=False):
        with tarfile.open(self.archive, 'w') as archive:
            for name, data in self.members.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o755 if name.endswith('/main') else 0o644
                if symlink and name.endswith('/main'):
                    member.type = tarfile.SYMTYPE
                    member.linkname = '../../unrelated'
                    member.size = 0
                    archive.addfile(member)
                else:
                    archive.addfile(member, io.BytesIO(data))

    def extract(self):
        return diagnostic.extract_candidate(self.archive, self.marker, self.source)

    def reseal(self):
        digest = diagnostic.sha(self.archive)
        marker = json.loads(self.marker.read_text())
        marker.update(candidateTarSha256=digest, candidateTarSize=self.archive.stat().st_size)
        self.marker.write_text(json.dumps(marker))
        return patch.multiple(diagnostic, TAR_SHA=digest, TAR_SIZE=self.archive.stat().st_size)

    def test_complete_sealed_candidate_is_extracted_without_execution(self):
        self.assertEqual(self.extract(), self.manifest)
        self.assertEqual((self.source / 'target/release/bin/main').read_bytes(), self.binary)

    def test_wrong_run_attempt_revision_and_tree_are_refused(self):
        original = self.marker.read_text()
        for key, value in [('runAttempt', 2), ('commit', '0' * 40), ('tree', '0' * 40),
                           ('runId', 40546453166)]:
            with self.subTest(key=key):
                marker = json.loads(original)
                marker[key] = value
                self.marker.write_text(json.dumps(marker))
                with self.assertRaisesRegex(ValueError, 'marker identity'):
                    self.extract()
                self.assertFalse((self.source / 'target').exists())

    def test_modified_archive_is_rejected_before_output_creation(self):
        data = self.archive.read_bytes()
        self.archive.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
        with self.assertRaisesRegex(ValueError, 'tar identity'):
            self.extract()
        self.assertFalse((self.source / 'target').exists())

    def test_extra_member_is_rejected_even_with_a_valid_fixture_seal(self):
        self.members['../outside'] = b'fixture'
        self.write_archive()
        with self.reseal(), self.assertRaisesRegex(ValueError, 'members'):
            self.extract()
        self.assertFalse((self.source / 'target').exists())
        self.assertFalse((self.root / 'outside').exists())

    def test_symlink_member_is_rejected_before_extraction(self):
        self.write_archive(symlink=True)
        with self.reseal(), self.assertRaisesRegex(ValueError, 'members'):
            self.extract()
        self.assertFalse((self.source / 'target').exists())

    def test_existing_target_and_symlink_are_preserved(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'keep').write_text('keep')
        target = self.source / 'target'
        for link in (False, True):
            with self.subTest(link=link):
                if link:
                    target.symlink_to(outside, target_is_directory=True)
                else:
                    target.mkdir()
                with self.assertRaisesRegex(ValueError, 'already exists'):
                    self.extract()
                self.assertEqual((outside / 'keep').read_text(), 'keep')
                target.unlink() if link else target.rmdir()

    def test_wrong_manifest_commit_and_binary_are_refused(self):
        for key in ('checkoutCommit', 'mainBinary'):
            with self.subTest(key=key):
                manifest = dict(self.manifest)
                manifest[key] = '0' * 40 if key == 'checkoutCommit' else {'sha256': '0' * 64}
                self.members['target/ci-build/build-manifest.json'] = json.dumps(manifest).encode()
                self.write_archive()
                with self.reseal(), self.assertRaisesRegex(ValueError, 'manifest differs'):
                    self.extract()
                self.assertFalse((self.source / 'target').exists())


class TraceSelectionTests(unittest.TestCase):
    source = Path('/workspace')
    binary = source / 'target/release/bin/main'
    private = Path('/diagnostic/private')

    def result(self, *, code=2, project=None, duplicate=False, measure=-11):
        project = project or self.source
        fields = [sys.executable, str(self.source / 'scripts/measure_command.py'), str(self.binary),
            'generate', '--project', str(project), '--format', 'json', '--output',
            str(self.private / 'performance-fixture/self/run-00-cold'), '--jobs', '1', '--no-cache']
        line = 'perf_gate.py: error: command failed (245): ' + ' '.join(fields)
        if duplicate:
            line += '\n' + line
        return subprocess.CompletedProcess([], code, b'',
            (line + '\n' + json.dumps({'exitCode': measure})).encode())

    def selected(self, result):
        return diagnostic.runtime_crash(result, self.source, self.binary, self.private)

    def test_only_unique_original_self_cold_sigsegv_is_selected(self):
        self.assertTrue(self.selected(self.result()))

    def test_success_different_failure_profile_and_duplicate_are_refused(self):
        for result in (self.result(code=0), self.result(project=Path('/other')),
                       self.result(duplicate=True), self.result(measure=1)):
            with self.subTest(result=result):
                self.assertFalse(self.selected(result))

    def test_unrelated_sigsegv_without_bound_command_does_not_trace(self):
        result = subprocess.CompletedProcess([], 2, b'', b'{"exitCode": -11}')
        self.assertFalse(self.selected(result))


@unittest.skipUnless(sys.platform == 'linux', 'POSIX process-group contract')
class ProcessTests(unittest.TestCase):
    def assert_process_exited(self, pid):
        try:
            descriptor = os.pidfd_open(pid)
        except ProcessLookupError:
            return
        try:
            # A bounded kernel wait observes exit directly, without racing /proc
            # removal or interpreting transient scheduler state letters.
            self.assertEqual(select.select([descriptor], [], [], 5)[0], [descriptor])
        finally:
            os.close(descriptor)

    def test_original_failure_code_and_output_survive(self):
        result, timeout = diagnostic.run_bounded([sys.executable, '-c',
            'import sys;print("failure evidence");sys.exit(37)'], Path.cwd(), os.environ.copy(), 5)
        self.assertEqual(result.returncode, 37)
        self.assertFalse(timeout)
        self.assertIn(b'failure evidence', result.stdout)

    def test_timeout_terminates_the_descendant_group(self):
        program = ('import subprocess,sys,time;'
            'p=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"]);'
            'print(p.pid,flush=True);time.sleep(60)')
        result, timeout = diagnostic.run_bounded([sys.executable, '-c', program],
            Path.cwd(), os.environ.copy(), 0.5)
        self.assertTrue(timeout)
        self.assertEqual(result.returncode, 124)
        pid = int(result.stdout.strip())
        self.assert_process_exited(pid)

    def test_timeout_also_terminates_a_descendant_in_another_process_group(self):
        program = ('import subprocess,sys,time;'
            'p=subprocess.Popen([sys.executable,"-c","import os,time;os.setpgrp();time.sleep(60)"]);'
            'print(p.pid,flush=True);time.sleep(60)')
        result, timeout = diagnostic.run_bounded([sys.executable, '-c', program],
            Path.cwd(), os.environ.copy(), 0.5)
        self.assertTrue(timeout)
        self.assertEqual(result.returncode, 124)
        pid = int(result.stdout.strip())
        self.assert_process_exited(pid)


class SourceBindingTests(unittest.TestCase):
    def test_workflow_is_read_only_frozen_and_first_attempt_only(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / '.github/workflows/release076-evidence.yml').read_text()
        self.assertIn('branches: [diag/release076-evidence]', workflow)
        self.assertIn('if: ${{ github.run_attempt == 1 }}', workflow)
        self.assertIn('ref: ' + diagnostic.COMMIT, workflow)
        self.assertIn('ref: ' + diagnostic.LIBRARY_COMMIT, workflow)
        self.assertIn('actions: read', workflow)
        self.assertNotIn(': write', workflow)
        self.assertEqual(workflow.count('run-id: 40536370055'), 2)
        self.assertIn('retention-days: 3', workflow)
        self.assertNotIn('public/*', workflow)
        self.assertNotIn('/private/', workflow)

    def test_original_workflow_body_and_compilation_policy_are_preserved(self):
        root = Path(__file__).resolve().parents[1]
        script = diagnostic.release_stage(root)
        self.assertIn('python scripts/verify_release.py >/dev/null', script)
        self.assertIn('python scripts/release_build_parameters.py --repo .', script)
        self.assertEqual(script.count('bash scripts/check.sh'), 1)
        self.assertIn('. scripts/with_sts_cjpm.sh', script)
        self.assertNotIn('${{', script)
        self.assertEqual(subprocess.run(['bash', '-n'], input=script.encode(), capture_output=True).returncode, 0)

    def test_changed_original_workflow_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.github/workflows').mkdir(parents=True)
            (root / '.github/workflows/release.yml').write_text('untrusted replacement')
            with self.assertRaisesRegex(ValueError, 'workflow identity'):
                diagnostic.release_stage(root)


if __name__ == '__main__':
    unittest.main()
