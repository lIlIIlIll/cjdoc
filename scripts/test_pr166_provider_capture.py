"""Fixed-profile boundaries; local fixtures do not prove native compiler behavior."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import full_gate_codegen_capture as full
from ir_hardlinks import CaptureMissed
import native_backend_trace as backend
import pipeline_codegen_capture as pipeline
import pr166_provider_capture as profile
import test_native_backend_trace as fixtures


class ProviderProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.temporary = self.root / 'compiler-temp'
        self.temporary.mkdir()
        self.output = self.root / 'output'
        self.output.mkdir()
        self.environment = dict(os.environ, GITHUB_WORKSPACE=str(self.source),
            RUNNER_TEMP=str(self.root), TMPDIR=str(self.temporary), TMP=str(self.temporary),
            TEMP=str(self.temporary), CJDOC_ORIGINAL_BASH=shutil.which('bash'),
            CJDOC_PYTHON='python', CJDOC_STDX_PATH='fixture-stdx')
        self.environment.pop('CJDOC_STS_INVOCATION_LOG', None)

    def attempt(self):
        with patch.dict(os.environ, self.environment, clear=True):
            return profile.Pr166ProviderAttempt(self.source, self.output, 'macos-arm64')

    def test_fixed_merge_tree_head_and_original_stage_body_are_bound(self):
        attempt = self.attempt()
        self.assertEqual(attempt.evidence['sourceCommit'], profile.MERGE)
        self.assertEqual(attempt.evidence['sourceTree'], profile.TREE)
        self.assertEqual(attempt.evidence['sourceHead'], profile.HEAD)
        entry = attempt.evidence['entryProfile']
        self.assertEqual(entry['name'], profile.PROFILE)
        self.assertEqual(entry['sourceTreeEqualsOriginalPrMergeTree'], profile.TREE)
        self.assertEqual(entry['originalPrMergeCommit'], profile.MERGE)
        self.assertFalse(entry['productCleanupFixIncluded'])
        original = object.__new__(full.FullGateAttempt)
        original.selected = 'macos-arm64'
        self.assertEqual(attempt.stage_script(), original.stage_script())

    def test_both_integrity_snapshots_use_the_new_fixed_tree(self):
        attempt = self.attempt()
        attempt.git.snapshot = Mock(return_value={'fixture': True})
        attempt.authenticate = Mock(side_effect=ValueError('fixture stop before compiler'))
        self.assertEqual(attempt.execute(), 2)
        self.assertEqual(attempt.evidence['targetInvocations'], 0)
        self.assertEqual(attempt.git.snapshot.call_count, 2)
        for call in attempt.git.snapshot.call_args_list:
            self.assertEqual(call.args, (self.source, profile.MERGE, profile.TREE))

    def test_new_profile_module_and_tests_are_in_controller_identity(self):
        identity = self.attempt().identity()
        paths = {row['path'] for row in identity['candidateFiles']}
        self.assertIn('scripts/test_sdk_cache_identity.py', paths)
        self.assertTrue({'scripts/pr166_provider_capture.py',
                         'scripts/test_pr166_provider_capture.py'} <= paths)

    def links(self, cls):
        retained = self.root / 'retained'
        retained.mkdir()
        return cls(self.temporary, retained)

    def test_capture_scope_is_cjdoc_and_markdown_only(self):
        for cls in (profile.ProviderDependencyLinks, profile.ProviderCompilerTempLinks):
            with self.subTest(cls=cls.__name__):
                directory = self.temporary / 'cangjie-tmp-fixture'
                directory.mkdir()
                links = self.links(cls)
                for name in ('cjdoc.opt.bc', 'markdown.opt.bc', 'yjson.opt.bc'):
                    path = directory / name
                    path.write_bytes(name.encode())
                links.scan()
                for path in directory.iterdir():
                    path.unlink()
                directory.rmdir()
                try:
                    self.assertEqual({row['name'] for row in links.finish()}, profile.NAMES)
                finally:
                    shutil.rmtree(self.root / 'retained')

    def test_cjdoc_ir_outside_macos_compiler_namespace_is_refused(self):
        (self.temporary / 'cjdoc.opt.bc').write_bytes(b'fixture')
        with self.assertRaises(CaptureMissed):
            self.links(profile.ProviderCompilerTempLinks).scan()

    def test_existing_ir_size_budget_remains_enforced(self):
        directory = self.temporary / 'cangjie-tmp-fixture'
        directory.mkdir()
        path = directory / 'cjdoc.opt.bc'
        with path.open('wb') as stream:
            stream.truncate(64 * 1024 * 1024 + 1)
        links = self.links(profile.ProviderCompilerTempLinks)
        links.scan()
        path.unlink()
        with self.assertRaisesRegex(CaptureMissed, 'per-file budget'):
            links.finish()


class ProviderBackendTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.BackendTraceTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def request(self, selected='macos-arm64', scope=profile.PROFILE, package='cjdoc'):
        original = self.fixture.request(selected)
        return SimpleNamespace(**{**vars(original), 'scope': scope, 'package': package,
            'original_bitcode_path': original.original_bitcode_path.with_name(package + '.opt.bc'),
            'build_log': original.build_log.replace('yjson', package)})

    def test_two_native_profiles_allow_one_bound_cjdoc_backend_only(self):
        for selected in backend.FLAGS:
            with self.subTest(selected=selected):
                request = self.request(selected)
                request.directory = self.fixture.root / selected
                runner = Mock(side_effect=self.fixture.runner)
                result = backend.trace_once(request, runner)
                self.assertEqual(result['originalPackage'], 'cjdoc')
                self.assertEqual(result['backendInvocations'], 1)
                self.assertEqual(result['timeoutSeconds'], 600)
                self.assertFalse(result['qualification'])
                runner.assert_called_once()

    def test_legacy_scope_rejects_cjdoc(self):
        with self.assertRaises(ValueError):
            backend.observed_profile(self.request(scope='dependencies'))

    def test_new_scope_rejects_yjson_and_unknown_scope(self):
        for scope in (profile.PROFILE, 'unrecognized'):
            with self.subTest(scope=scope), self.assertRaises(ValueError):
                backend.observed_profile(self.request(scope=scope, package='yjson'))

    def test_selector_binds_complete_failed_path_and_new_scope(self):
        request = self.request()
        row = {'name': 'cjdoc.opt.bc', 'sourceRelative': 'cjdoc.opt.bc',
               'retained': self.fixture.bc.name, 'sha256': request.expected_bitcode_sha256}
        selected, failure, original = pipeline.select_yjson([row], subprocess.CompletedProcess([], 139),
            request.build_log, {'llc': self.fixture.tool}, request.original_bitcode_path.parent,
            self.fixture.root, {}, selected='macos-arm64', packages=('cjdoc', 'markdown'),
            scope=profile.PROFILE)
        self.assertEqual(selected, row)
        self.assertEqual(failure, request.build_log)
        self.assertEqual(original, request.original_bitcode_path)

    def test_new_selector_scope_never_broadens_legacy_package_set(self):
        request = self.request()
        with self.assertRaises(ValueError):
            pipeline.select_yjson([], subprocess.CompletedProcess([], 139), request.build_log,
                {'llc': self.fixture.tool}, self.fixture.root, self.fixture.root, {},
                packages=('cjdoc',))


class ProviderWorkflowTests(unittest.TestCase):
    def test_separate_explicit_mode_binds_both_platforms_and_real_merge(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml').read_text()
        self.assertIn('\n  pr166-provider-155:\n', workflow)
        job = workflow.split('\n  pr166-provider-155:\n', 1)[1]
        self.assertIn("if: ${{ inputs.mode == 'pr166-provider-155' }}", job)
        self.assertIn('ref: ' + profile.MERGE, job)
        self.assertIn('runner: windows-2022', job)
        self.assertIn('runner: macos-15', job)
        self.assertEqual(job.count('- platform:'), 2)
        self.assertIn('scripts/pr166_provider_capture.py', job)
        self.assertIn('fail-on-cache-miss: true', job)
        self.assertIn('retention-days: 3', job)
        self.assertNotIn('public/*', job)
        self.assertNotIn('private/', job)
        self.assertNotIn('--verbose', job)
        self.assertNotIn('--save-temps', job)


if __name__ == '__main__':
    unittest.main()
