#!/usr/bin/env python3
"""Exercise phase selection and artifact isolation through the real STS wrapper."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

try:
    from .release_build_parameters import usable_shell
except ImportError:
    from release_build_parameters import usable_shell

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))

from sts_compile_override import OPTION, UNIT_OPTION  # noqa: E402
PROBE = r"""import json, os, pathlib, subprocess, sys, tomllib
if sys.argv[1:] == ['-v']:
    raise SystemExit(0)
argv = sys.argv[1:]
command = argv[0]
manifest = pathlib.Path('cjpm.toml')
option = tomllib.loads(manifest.read_text())['package']['override-compile-option']
root_manifest = pathlib.Path(os.environ['GITHUB_WORKSPACE']) / 'cjpm.toml'
root_option = None
if root_manifest.resolve() != manifest.resolve():
    root_option = tomllib.loads(root_manifest.read_text())['package'].get('override-compile-option')
target = None
if command == 'test':
    target = pathlib.Path(argv[argv.index('--target-dir') + 1])
    assert target.is_dir() and not list(target.iterdir()), 'test target reused cached files'
    (target / 'unit-o1-cache').write_text(option)
    if os.environ.get('PROBE_NESTED_BUILD'):
        subprocess.run([os.environ['PROBE_SHELL'], '-c', 'cjpm build --jobs 1'], check=True)
        assert tomllib.loads(pathlib.Path('cjpm.toml').read_text())['package']['override-compile-option'] == os.environ['PROBE_UNIT_OPTION']
if command == 'build' and not os.environ.get('PROBE_EXIT_CODE'):
    binary = pathlib.Path('target/release/bin/main')
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(b'product-O2')
with open(os.environ['PROBE_OBSERVATIONS'], 'a') as stream:
    stream.write(json.dumps({'argv': argv, 'option': option, 'target': str(target) if target else None,
                             'rootOption': root_option}) + '\n')
raise SystemExit(int(os.environ.get('PROBE_EXIT_CODE', '0')))
"""


class CompilePhaseTests(unittest.TestCase):
    def setUp(self):
        self.shell = usable_shell()
        if self.shell is None:
            self.skipTest('STS wrapper needs a usable POSIX shell')
        self.temporary = tempfile.TemporaryDirectory(prefix='cjdoc-phase-')
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name).resolve() / 'repo'
        scripts = self.repo / 'scripts'
        scripts.mkdir(parents=True)
        for name in ['with_sts_cjpm.sh', 'sts_compile_override.py', 'apply_sts_override.py', 'log_invocation.py', 'verify_build_invocations.py']:
            shutil.copy2(ROOT / 'scripts' / name, scripts / name)
        self.manifest = self.repo / 'cjpm.toml'
        self.original = b'[package]\nname = "cjdoc"\noverride-compile-option = ""\n'
        self.manifest.write_bytes(self.original)
        self.runner = Path(self.temporary.name).resolve() / 'runner'
        probe = self.runner / 'probe'
        probe.mkdir(parents=True)
        (probe / 'probe.py').write_text(PROBE, encoding='utf-8', newline='\n')
        (probe / 'cjc').write_text('#!/usr/bin/env bash\nexit 0\n', encoding='utf-8', newline='\n')
        (probe / 'cjpm').write_text('#!/usr/bin/env bash\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(probe / 'probe.py')) + ' "$@"\n', encoding='utf-8', newline='\n')
        (probe / 'cjc').chmod(0o755)
        (probe / 'cjpm').chmod(0o755)
        self.observed = self.runner / 'observed.jsonl'
        self.log = self.runner / 'invocations.jsonl'
        self.environment = dict(os.environ, GITHUB_WORKSPACE=str(self.repo), RUNNER_TEMP=str(self.runner), CJDOC_PYTHON=sys.executable,
                                PROBE_OBSERVATIONS=str(self.observed), CJDOC_STS_INVOCATION_LOG=str(self.log),
                                PROBE_SHELL=self.shell, PROBE_UNIT_OPTION=UNIT_OPTION)
        self.environment['PATH'] = str(probe) + os.pathsep + os.environ.get('PATH', '')
        self.environment.pop('CJDOC_STS_WRAPPER_CJPM', None)
        self.environment.pop('CJDOC_REAL_CJPM', None)
        self.environment.pop('CJDOC_STS_COMPILER_DIAGNOSTICS', None)

    def invoke(self, commands, *, cwd=None, **extra):
        source = '. ' + shlex.quote(str(self.repo / 'scripts/with_sts_cjpm.sh'))
        return subprocess.run([self.shell, '-c', source + ' && ' + commands], cwd=cwd or self.repo,
                              env=dict(self.environment, **extra), capture_output=True, text=True, timeout=60)

    def provider_fixture(self):
        """Create the provider fixture the wrapper treats as a diagnostics target."""
        fixture = self.repo / 'tests/fixtures/projects/provider_plugin'
        fixture.mkdir(parents=True)
        manifest = fixture / 'cjpm.toml'
        original = b'[package]\n  name = "provider_plugin_fixture"\n  override-compile-option = ""\n'
        manifest.write_bytes(original)
        return fixture, manifest, original

    def records(self, path):
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_product_o2_and_unit_o1_are_selected_before_execution(self):
        result = self.invoke('cjpm build --jobs 1 && cjpm test --jobs 1 --no-progress && cjpm run --build-args "--jobs 1"')
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = self.records(self.observed)
        self.assertEqual([r['option'] for r in actual], [OPTION, UNIT_OPTION, OPTION])
        self.assertEqual(self.manifest.read_bytes(), self.original)
        self.assertFalse(Path(actual[1]['target']).exists())
        records = self.records(self.log)
        self.assertEqual([r['phase'] for r in records], ['product-build', 'unit-test', 'product-run'])
        self.assertEqual(records[1]['reason'], 'sts-1.2-linux-unit-plain-and-noinline-compiler-ice13')
        self.assertEqual(records[1]['exitCode'], 0)
        self.assertIsNone(records[1]['binary'])
        self.assertIsNone(records[2]['binary'])
        binary = self.repo / 'target/release/bin/main'
        self.assertEqual(binary.read_bytes(), b'product-O2')
        verified = subprocess.run([sys.executable, str(self.repo / 'scripts/verify_build_invocations.py'), '--log', str(self.log), '--binary', str(binary)], capture_output=True, text=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(json.loads(verified.stdout)['option'], OPTION)

    def test_failed_unit_keeps_exit_code_without_retry_or_product_cache_change(self):
        product = self.repo / 'target/release/bin/main'
        product.parent.mkdir(parents=True)
        product.write_bytes(b'previous-product')
        result = self.invoke('cjpm test --jobs 1', PROBE_EXIT_CODE='47')
        self.assertEqual(result.returncode, 47, result.stderr)
        actual = self.records(self.observed)
        self.assertEqual(len(actual), 1)
        self.assertEqual(actual[0]['option'], UNIT_OPTION)
        self.assertFalse(Path(actual[0]['target']).exists())
        self.assertEqual(product.read_bytes(), b'previous-product')
        self.assertEqual(self.manifest.read_bytes(), self.original)
        record = self.records(self.log)[0]
        self.assertEqual(record['exitCode'], 47)
        self.assertIsNone(record['binary'])

    def test_each_unit_invocation_gets_a_new_target(self):
        result = self.invoke('cjpm test --jobs 1 && cjpm test --jobs 1')
        self.assertEqual(result.returncode, 0, result.stderr)
        targets = [r['target'] for r in self.records(self.observed)]
        self.assertNotEqual(*targets)
        self.assertTrue(all(not Path(p).exists() for p in targets))

    def test_caller_cannot_route_unit_cache_into_product_target(self):
        for argument in ['--target-dir target', '--target-dir=target']:
            with self.subTest(argument=argument):
                result = self.invoke('cjpm test ' + argument)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('target is owned', result.stderr)
                self.assertFalse(self.observed.exists())
                self.assertEqual(self.manifest.read_bytes(), self.original)

    def test_nested_product_build_stays_o2_and_restores_outer_test_manifest(self):
        result = self.invoke('cjpm test --jobs 1', PROBE_NESTED_BUILD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r['option'] for r in self.records(self.observed)], [OPTION, UNIT_OPTION])
        self.assertEqual(self.manifest.read_bytes(), self.original)

    def test_provider_run_retains_compiler_ir_without_changing_the_product_option(self):
        fixture, manifest, original = self.provider_fixture()
        diagnostics = 'D:\\a\\_temp\\cjdoc native ir'
        for status in (0, 37):
            with self.subTest(status=status):
                self.observed.unlink(missing_ok=True)
                self.log.unlink(missing_ok=True)
                result = self.invoke('cjpm run --build-args "--jobs 1"', cwd=fixture,
                                     CJDOC_STS_COMPILER_DIAGNOSTICS=diagnostics,
                                     PROBE_EXIT_CODE=str(status))
                self.assertEqual(result.returncode, status, result.stderr)
                expected = f'{OPTION} -V --save-temps "{diagnostics}"'
                # What the compiler would read came back from TOML as exactly the
                # requested argument: the Windows backslashes survived escaping and
                # `cjpm`'s quote-grouping sees one --save-temps argument.
                self.assertEqual([r['option'] for r in self.records(self.observed)], [expected])
                self.assertEqual(self.records(self.observed)[0]['rootOption'], expected)
                entry = self.records(self.log)[0]
                self.assertEqual(entry['phase'], 'product-run')
                self.assertEqual(entry['option'], expected)
                self.assertEqual(entry['exitCode'], status)
                # Both manifests are restored, including after a failed invocation.
                self.assertEqual(manifest.read_bytes(), original)
                self.assertEqual(self.manifest.read_bytes(), self.original)

    def test_retention_leaves_the_optimisation_level_and_manifest_text_otherwise_intact(self):
        fixture, manifest, original = self.provider_fixture()
        result = self.invoke('cjpm run --build-args "--jobs 1"', cwd=fixture,
                             CJDOC_STS_COMPILER_DIAGNOSTICS='/runner temp/ir')
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = self.records(self.observed)[0]['option']
        self.assertTrue(raw.startswith(OPTION + ' '), raw)
        self.assertNotIn('-O1', raw)
        # The next invocation without the request is the plain pinned option again.
        result = self.invoke('cjpm run --build-args "--jobs 1"', cwd=fixture)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.records(self.observed)[-1]['option'], OPTION)
        self.assertEqual(manifest.read_bytes(), original)

    def test_retention_is_refused_outside_the_provider_run(self):
        """An inherited request must never add IR retention to another invocation."""
        fixture, manifest, original = self.provider_fixture()
        diagnostics = '/runner temp/ir'
        cases = (
            ('cjpm run --build-args "--jobs 1"', self.repo, OPTION),
            ('cjpm build --jobs 1', fixture, OPTION),
            ('cjpm test --jobs 1', fixture, UNIT_OPTION),
        )
        for command, cwd, expected in cases:
            with self.subTest(command=command, cwd=cwd.name):
                self.observed.unlink(missing_ok=True)
                self.log.unlink(missing_ok=True)
                result = self.invoke(command, cwd=cwd,
                                     CJDOC_STS_COMPILER_DIAGNOSTICS=diagnostics)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([r['option'] for r in self.records(self.observed)], [expected])
                self.assertIn('CJDOC_STS_COMPILER_DIAGNOSTICS', result.stderr)
                self.assertEqual(self.records(self.log)[-1]['option'], expected)
        self.assertEqual(manifest.read_bytes(), original)
        self.assertEqual(self.manifest.read_bytes(), self.original)

    def test_an_unrepresentable_diagnostics_directory_stops_before_compiling(self):
        """A path `cjpm` would split or truncate must fail, not silently compile."""
        fixture, manifest, original = self.provider_fixture()
        # Native paths survive Git Bash's POSIX-path conversion unchanged.
        for diagnostics in ('relative/ir', 'D:\\a\\_temp\\ir\\', 'D:\\a\\_temp\\"quoted ir"',
                            'D:\\a\\_temp\\ir;touch x', 'D:\\a\\_temp\\${HOME}'):
            with self.subTest(diagnostics=diagnostics):
                self.observed.unlink(missing_ok=True)
                self.log.unlink(missing_ok=True)
                result = self.invoke('cjpm run --build-args "--jobs 1"', cwd=fixture,
                                     CJDOC_STS_COMPILER_DIAGNOSTICS=diagnostics)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('compiler diagnostics directory', result.stderr)
                self.assertFalse(self.observed.exists())
                self.assertEqual(manifest.read_bytes(), original)
                self.assertEqual(self.manifest.read_bytes(), self.original)

    def test_worker_reads_its_pinned_manifest_and_records_its_own_binary(self):
        worker = self.repo / 'tools/chir-worker'
        worker.mkdir(parents=True)
        manifest = worker / 'cjpm.toml'
        original = b'[package]\nname = "cjdoc_chir_worker"\n'
        manifest.write_bytes(original)
        result = self.invoke('cjpm build --jobs 1 && cd tools/chir-worker && cjpm build --jobs 1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r['option'] for r in self.records(self.observed)],
                         [OPTION, OPTION])
        records = self.records(self.log)
        self.assertEqual(records[1]['package'], 'cjdoc_chir_worker')
        import hashlib
        binary = worker / 'target/release/bin/main'
        self.assertEqual(records[1]['binary']['sha256'], hashlib.sha256(binary.read_bytes()).hexdigest())
        self.assertEqual(manifest.read_bytes(), original)
        self.assertEqual(self.manifest.read_bytes(), self.original)
        self.assertEqual(records[1]['policySha256'], hashlib.sha256((self.repo / 'scripts/sts_compile_override.py').read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main()
