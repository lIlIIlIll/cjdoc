"""Original full-gate shell and capture boundaries; fixtures are not native proof."""
import os
from pathlib import Path
import stat
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import full_gate_codegen_capture as full
import pipeline_codegen_capture as prefix
import test_native_backend_trace as backend_fixtures


class FullGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.source=self.root/'source';self.source.mkdir()
        self.temporary=self.root/'compiler-temp';self.temporary.mkdir()
        self.output=self.root/'output';self.output.mkdir()
        self.environment=dict(os.environ,GITHUB_WORKSPACE=str(self.source),RUNNER_TEMP=str(self.root),
            TMPDIR=str(self.temporary),TMP=str(self.temporary),TEMP=str(self.temporary),
            CJDOC_PYTHON='python',CJDOC_STDX_PATH='fixture-stdx',CJDOC_ORIGINAL_BASH=shutil.which('bash'),CJDOC_CI_EVIDENCE=str(self.source/'target/ci-evidence'))
        self.environment.pop('CJDOC_STS_INVOCATION_LOG',None)

    def attempt(self):
        with patch.dict(os.environ,self.environment,clear=True):return full.FullGateAttempt(self.source,self.output,'macos-arm64')

    def test_posix_inherited_temp_and_var_alias_are_same_directory_bound(self):
        alias=self.root/'alias';alias.symlink_to(self.temporary,target_is_directory=True)
        # A parent symlink is valid on macOS (/var -> /private/var); the leaf must be ordinary.
        child=self.temporary/'child';child.mkdir()
        environment={'TMPDIR':str(alias/'child')}
        root,aliases=full.posix_temporary(environment)
        self.assertEqual(root,child);self.assertEqual(aliases,[child,alias/'child'])
        self.assertTrue(os.path.samefile(*aliases))

    def test_posix_missing_disagreeing_or_symlink_leaf_is_refused(self):
        alias=self.root/'alias';alias.symlink_to(self.temporary,target_is_directory=True)
        other=self.root/'other';other.mkdir()
        for environment in [{},{'TMPDIR':str(alias)}, {'TMPDIR':str(self.temporary),'TMP':str(other)}]:
            with self.subTest(environment=environment),self.assertRaises((ValueError,KeyError)):
                full.posix_temporary(environment)

    def test_constructor_binds_exact_original_merge_and_full_stage_order(self):
        attempt=self.attempt()
        self.assertEqual(attempt.evidence['sourceCommit'],full.ORIGINAL_MERGE)
        self.assertEqual(attempt.evidence['entryProfile']['stages'],['preflight','build','native','python-tools','cli','provider'])
        self.assertEqual(attempt.dependency_checkout,'canonical')
        self.assertEqual(attempt.environment['TMPDIR'],self.environment['TMPDIR'])
        self.assertEqual(attempt.entry_shell(),self.environment['CJDOC_ORIGINAL_BASH'])
        identity=attempt.identity()
        self.assertEqual(identity['entryShell']['sha256'],full.digest(Path(self.environment['CJDOC_ORIGINAL_BASH'])))
        paths={row['path'] for row in identity['candidateFiles']}
        self.assertTrue({'scripts/full_gate_codegen_capture.py','scripts/test_full_gate_codegen_capture.py'}<=paths)

    def test_prior_macos_pristine_snapshot_is_refused_without_overwriting(self):
        path=self.root/'source-edge-fixture.cj';path.write_text('preserve')
        with self.assertRaisesRegex(ValueError,'already exists'):self.attempt()
        self.assertEqual(path.read_text(),'preserve')

    def run_shell(self,platform,code):
        scripts=self.source/'scripts';scripts.mkdir()
        (scripts/'with_sts_cjpm.sh').write_text(': # shell fixture, no compiler\n')
        (scripts/'check.sh').write_text('printf "%s\\n" "$@" > "$GITHUB_WORKSPACE/args"\n'
            'if [ -n "${FIXTURE_FILE:-}" ]; then printf changed > "$FIXTURE_FILE"; chmod 600 "$FIXTURE_FILE"; fi\n'
            'exit '+str(code)+'\n')
        entry=object.__new__(full.FullGateAttempt);entry.selected=platform
        script=self.root/'full-gate.sh';script.write_text(entry.stage_script())
        fixture=self.source/'tests/fixtures/projects/source_edges/src/fixture.cj';fixture.parent.mkdir(parents=True)
        fixture.write_bytes(b'original fixture\r\n');fixture.chmod(0o640)
        env=dict(self.environment,FIXTURE_FILE=str(fixture))
        result=subprocess.run(['bash',str(script)],cwd=self.source,env=env,capture_output=True)
        return result,fixture

    def test_real_shell_template_calls_no_stage_token_and_preserves_original_failure(self):
        result,fixture=self.run_shell('macos-arm64',17)
        self.assertEqual(result.returncode,17,result.stderr)
        self.assertEqual((self.source/'args').read_text().splitlines(),
            ['--manifest','target/ci-build/build-manifest.json','--worker-binary-out','target/release/bin/chir-worker-main'])
        self.assertEqual(fixture.read_bytes(),b'original fixture\r\n')
        self.assertEqual(stat.S_IMODE(fixture.stat().st_mode),0o640)

    def test_real_shell_template_restores_macos_fixture_after_success(self):
        result,fixture=self.run_shell('macos-arm64',0)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(fixture.read_bytes(),b'original fixture\r\n')

    def test_windows_shell_template_does_not_snapshot_or_restore_macos_fixture(self):
        result,fixture=self.run_shell('windows-x64',0)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(fixture.read_bytes(),b'changed')
        self.assertFalse((self.root/'source-edge-fixture.cj').exists())

    def test_real_hardlinks_retain_only_yjson_ir(self):
        retained=self.root/'retained';retained.mkdir()
        links=full.YjsonLinks(self.temporary,retained)
        for name in ['main.opt.bc','yjson.opt.bc','markdown.opt.bc']:
            path=self.temporary/name;path.write_bytes(name.encode());links.accept(path);path.unlink()
        rows=links.finish();self.assertEqual([row['name'] for row in rows],['yjson.opt.bc'])
        self.assertTrue(all(row['linkCountAfterCompiler']==1 and not row['originalPresent'] for row in rows))

    def test_complete_macos_failure_profile_selects_matching_ir(self):
        fixture=backend_fixtures.BackendTraceTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        request=fixture.request('macos-arm64')
        row={'name':'yjson.opt.bc','sourceRelative':'yjson.opt.bc','retained':fixture.bc.name,'sha256':request.expected_bitcode_sha256}
        selected,failure,path=prefix.select_yjson([row],subprocess.CompletedProcess([],139),request.build_log,
            {'llc':fixture.tool},request.original_bitcode_path.parent,fixture.root,{},selected='macos-arm64')
        self.assertEqual(selected,row);self.assertEqual(path,request.original_bitcode_path)
        self.assertEqual(failure,request.build_log)


class WorkflowModeTests(unittest.TestCase):
    def test_full_gate_requires_its_exact_explicit_mode_and_original_merge(self):
        workflow=(Path(__file__).resolve().parents[1]/'.github/workflows/ci.yml').read_text()
        full_job=workflow.split('  original-full-gate:\n',1)[1].split('\n  cache-identity:\n',1)[0]
        self.assertIn("if: ${{ inputs.mode == 'original-full-gate' }}",full_job)
        self.assertIn('ref: '+full.ORIGINAL_MERGE,full_job)
        self.assertNotIn('runner: windows-2022',full_job);self.assertIn('runner: macos-15',full_job)
        self.assertEqual(full_job.count('- platform:'),1)
        self.assertIn('actions/cache/restore@',full_job);self.assertIn('fail-on-cache-miss: true',full_job)
        self.assertNotIn('actions/cache@',full_job);self.assertNotIn('--verbose',full_job)
        self.assertIn('--platform "$DIAGNOSTIC_PLATFORM"',full_job)
        self.assertNotIn('public/*',full_job);self.assertNotIn('private/',full_job)


class FailingDependencyCaptureTests(unittest.TestCase):
    def test_full_gate_retains_actual_markdown_and_yjson_only(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);temporary=root/'tmp';temporary.mkdir();retained=root/'retained';retained.mkdir()
            attempt=object.__new__(full.FullGateAttempt);attempt.temporary=temporary;attempt.pipeline_retained=retained;attempt.selected='windows-x64'
            links=attempt.retention_links()
            for filename in ['yjson.opt.bc','markdown.opt.bc','cjdoc.opt.bc']:
                path=temporary/filename;path.write_bytes(filename.encode());links.accept(path);path.unlink()
            self.assertEqual({row['name'] for row in links.finish()},{'yjson.opt.bc','markdown.opt.bc'})
            self.assertEqual(set(attempt.trace_packages()),{'yjson','markdown'})

    def test_actual_markdown_failure_is_bound_while_original_yjson_only_scope_stays_unchanged(self):
        fixture=backend_fixtures.BackendTraceTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        request=fixture.request('windows-x64')
        markdown={'name':'markdown.opt.bc','sourceRelative':'markdown.opt.bc','retained':fixture.bc.name,'sha256':request.expected_bitcode_sha256}
        yjson={**markdown,'name':'yjson.opt.bc','sourceRelative':'yjson.opt.bc'}
        log=request.build_log.replace('yjson.opt.bc','markdown.opt.bc').replace('yjson.o','markdown.o')
        args=([yjson,markdown],subprocess.CompletedProcess([],1),log,{'llc':fixture.tool},request.original_bitcode_path.parent,fixture.root,{})
        selected,failure,_=prefix.select_yjson(*args)
        self.assertEqual(selected,yjson);self.assertIsNone(failure)
        selected,failure,original=prefix.select_yjson(*args,packages=('yjson','markdown'))
        self.assertEqual(selected,markdown);self.assertEqual(failure,log)
        self.assertEqual(original.name,'markdown.opt.bc')
