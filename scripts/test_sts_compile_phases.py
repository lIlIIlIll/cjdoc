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
PROBE = r"""import json, os, pathlib, subprocess, sys, tomllib
if sys.argv[1:] == ['-v']:
    raise SystemExit(0)
argv = sys.argv[1:]
command = argv[0]
option = tomllib.loads(pathlib.Path('cjpm.toml').read_text())['package']['override-compile-option']
target = None
if command == 'test':
    target = pathlib.Path(argv[argv.index('--target-dir') + 1])
    assert target.is_dir() and not list(target.iterdir()), 'test target reused cached files'
    (target / 'unit-o1-cache').write_text(option)
    if os.environ.get('PROBE_NESTED_BUILD'):
        subprocess.run([os.environ['PROBE_SHELL'], '-c', 'cjpm build --jobs 1'], check=True)
        assert tomllib.loads(pathlib.Path('cjpm.toml').read_text())['package']['override-compile-option'] == '-O1'
if command == 'build' and not os.environ.get('PROBE_EXIT_CODE'):
    binary = pathlib.Path('target/release/bin/main')
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(b'product-O2')
with open(os.environ['PROBE_OBSERVATIONS'], 'a') as stream:
    stream.write(json.dumps({'argv': argv, 'option': option, 'target': str(target) if target else None}) + '\n')
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
                                PROBE_SHELL=self.shell)
        self.environment['PATH'] = str(probe) + os.pathsep + os.environ.get('PATH', '')
        self.environment.pop('CJDOC_STS_WRAPPER_CJPM', None)
        self.environment.pop('CJDOC_REAL_CJPM', None)

    def invoke(self, commands, **extra):
        source = '. ' + shlex.quote(str(self.repo / 'scripts/with_sts_cjpm.sh'))
        return subprocess.run([self.shell, '-c', source + ' && ' + commands], cwd=self.repo,
                              env=dict(self.environment, **extra), capture_output=True, text=True, timeout=60)

    def records(self, path):
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_product_o2_and_unit_o1_are_selected_before_execution(self):
        result = self.invoke('cjpm build --jobs 1 && cjpm test --jobs 1 --no-progress && cjpm run --build-args "--jobs 1"')
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = self.records(self.observed)
        self.assertEqual([r['option'] for r in actual], ['-O2 --fno-chir-function-inlining', '-O1', '-O2 --fno-chir-function-inlining'])
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
        self.assertEqual(json.loads(verified.stdout)['option'], '-O2 --fno-chir-function-inlining')

    def test_failed_unit_keeps_exit_code_without_retry_or_product_cache_change(self):
        product = self.repo / 'target/release/bin/main'
        product.parent.mkdir(parents=True)
        product.write_bytes(b'previous-product')
        result = self.invoke('cjpm test --jobs 1', PROBE_EXIT_CODE='47')
        self.assertEqual(result.returncode, 47, result.stderr)
        actual = self.records(self.observed)
        self.assertEqual(len(actual), 1)
        self.assertEqual(actual[0]['option'], '-O1')
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
        self.assertEqual([r['option'] for r in self.records(self.observed)], ['-O2 --fno-chir-function-inlining', '-O1'])
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
                         ['-O2 --fno-chir-function-inlining', '-O2 --fno-chir-function-inlining'])
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
