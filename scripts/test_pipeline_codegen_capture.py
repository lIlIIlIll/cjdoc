"""Stage-entry checker regressions; mocks do not prove a native pipeline."""
import copy
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import pipeline_codegen_capture as pipeline
from ir_hardlinks import CaptureMissed
import test_native_backend_trace as backend_fixtures


class TemporaryBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.temporary=self.root/'temp';self.temporary.mkdir()
        self.environment={'TMP':str(self.temporary),'TEMP':str(self.temporary)}

    def test_inherited_temp_is_selected_without_mutating_environment(self):
        before=self.environment.copy()
        self.assertEqual(pipeline.inherited_temporary(self.environment),self.temporary)
        self.assertEqual(self.environment,before)

    def test_different_tmp_temp_or_tmpdir_is_refused(self):
        other=self.root/'other';other.mkdir()
        for key in ['TMP','TEMP','TMPDIR']:
            environment={**self.environment,key:str(other)}
            with self.subTest(key=key),self.assertRaises(ValueError):pipeline.inherited_temporary(environment)

    def test_missing_or_symlink_inherited_temp_is_refused(self):
        link=self.root/'alias';link.symlink_to(self.temporary,target_is_directory=True)
        for path in [self.root/'missing',link]:
            environment={key:str(path) for key in self.environment}
            with self.subTest(path=path.name),self.assertRaises((ValueError,FileNotFoundError)):
                pipeline.inherited_temporary(environment)

    def test_long_short_aliases_are_deduplicated_and_same_file_bound(self):
        alias=self.root/'short';alias.symlink_to(self.temporary,target_is_directory=True)
        aliases=pipeline.temporary_aliases(self.temporary,lambda api,path:str(alias))
        self.assertEqual(aliases,[self.temporary,alias])
        self.assertTrue(os.path.samefile(*aliases))

    def test_alias_to_another_directory_or_relative_path_is_refused(self):
        other=self.root/'other';other.mkdir()
        for value in [str(other),'relative',str(self.root/'missing')]:
            with self.subTest(value=value),self.assertRaises(ValueError):
                pipeline.temporary_aliases(self.temporary,lambda api,path:value)


class BackendBindingTests(unittest.TestCase):
    def setUp(self):
        self.fixture=backend_fixtures.BackendTraceTests();self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        f=self.fixture;self.request=f.request('windows-x64')
        self.temporary=f.root/'compiler-tmp'
        self.rows=[{'name':'yjson.opt.bc','sourceRelative':'earlier/yjson.opt.bc','retained':'earlier.opt.bc','sha256':'0'*64},
                   {'name':'yjson.opt.bc','sourceRelative':'yjson.opt.bc','retained':f.bc.name,'sha256':self.request.expected_bitcode_sha256}]

    def select(self,log=None,code=7,rows=None,temporary=None,aliases=None):
        return pipeline.select_yjson(self.rows if rows is None else rows,
            subprocess.CompletedProcess([],code),self.request.build_log if log is None else log,
            {'llc':self.fixture.tool},temporary or self.temporary,self.fixture.root,{},aliases)

    def test_full_failure_path_selects_the_matching_capture_among_multiple_yjson_inputs(self):
        row,failure,original=self.select()
        self.assertEqual(row,self.rows[1]);self.assertEqual(original,self.request.original_bitcode_path)
        self.assertEqual(failure,self.request.build_log)

    def test_verified_temp_alias_matches_full_path_without_basename_fallback(self):
        other=self.fixture.root/'long-temp'
        with self.assertRaises(CaptureMissed):self.select(temporary=other)
        row,_,original=self.select(temporary=other,aliases=[other,self.temporary])
        self.assertEqual(row,self.rows[1]);self.assertEqual(original,self.request.original_bitcode_path)

    def test_success_reports_first_observed_input_without_triggering_a_backend(self):
        row,failure,_=self.select(log='build succeeded',code=0)
        self.assertEqual(row,self.rows[0]);self.assertIsNone(failure)

    def test_other_package_failure_does_not_trigger_yjson_backend(self):
        _,failure,_=self.select(log=self.request.build_log.replace('yjson.opt.bc','markdown.opt.bc'))
        self.assertIsNone(failure)

    def test_duplicate_failure_or_ambiguous_capture_is_refused(self):
        for log,rows in [(self.request.build_log+'\n'+self.request.build_log,self.rows),
                         (self.request.build_log,[self.rows[1],copy.deepcopy(self.rows[1])])]:
            with self.subTest(log=log,rows=rows),self.assertRaises(CaptureMissed):self.select(log=log,rows=rows)

    def test_changed_complete_backend_flags_or_success_with_failure_line_is_refused(self):
        for log,code in [(self.request.build_log.replace('"-O2"','"-O1"'),7),(self.request.build_log,0)]:
            with self.subTest(code=code),self.assertRaises(CaptureMissed):self.select(log=log,code=code)

    def test_missing_yjson_capture_is_a_miss_and_never_a_retry(self):
        with self.assertRaises(CaptureMissed):self.select(rows=[])


class OriginalEntryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.source=self.root/'source';self.source.mkdir()
        self.output=self.root/'output';self.output.mkdir()
        self.temp=self.root/'compiler-temp';self.temp.mkdir()
        self.environment={'GITHUB_WORKSPACE':str(self.source),'RUNNER_TEMP':str(self.root),
                          'TMP':str(self.temp),'TEMP':str(self.temp),'CJDOC_PYTHON':'python',
                          'CJDOC_CI_EVIDENCE':str(self.source/'target/ci-evidence')}

    def attempt(self):
        with patch.dict(os.environ,self.environment,clear=True),patch.object(pipeline,'temporary_aliases',return_value=[self.temp]):
            return pipeline.PipelineAttempt(self.source,self.output)

    def test_original_environment_is_preserved_and_private_temp_override_removed(self):
        attempt=self.attempt()
        for key,value in self.environment.items():self.assertEqual(attempt.environment[key],value)
        self.assertNotIn('TMPDIR',attempt.environment)
        self.assertNotIn('CJDOC_STS_INVOCATION_LOG',attempt.environment)
        self.assertEqual(attempt.temporary,self.temp)
        self.assertFalse(attempt.evidence['entryProfile']['extraCompilerPreflight'])

    def test_wrong_workspace_root_or_nonwindows_profile_is_refused(self):
        with patch.dict(os.environ,{**self.environment,'GITHUB_WORKSPACE':str(self.root)},clear=True):
            with self.assertRaisesRegex(ValueError,'workspace root'):pipeline.PipelineAttempt(self.source,self.output)
        with self.assertRaisesRegex(ValueError,'Windows-only'):
            pipeline.PipelineAttempt(self.source,self.output,selected='macos-arm64')

    def test_preexisting_wrapper_log_is_refused_without_adopting_it(self):
        (self.root/'cjdoc-sts-invocations.jsonl').write_text('prior task')
        with self.assertRaisesRegex(ValueError,'already exists'):self.attempt()

    def stub_execution(self,exit_code=0,changed_source=False):
        attempt=self.attempt();events=[];snapshot={'fixed':'source'}
        attempt.identity=Mock(return_value={'fixed':'controller'})
        attempt.configure_dependency_inputs=Mock(side_effect=lambda:events.append('configure'))
        attempt.git=SimpleNamespace(read=Mock(side_effect=lambda *a:events.append('longpaths')),
            snapshot=Mock(side_effect=[snapshot,{'changed':True} if changed_source else snapshot]),
            calls=[],normalized_observations=[],raw_calls=[])
        attempt.authenticate=Mock(side_effect=lambda:events.append('authenticate'))
        attempt.lock_pins=Mock(side_effect=lambda:events.append('pins'))
        attempt.dependencies=Mock(side_effect=[{'yjson':{'present':False}}, {'yjson':{'commit':'verified'}}])
        attempt.preflight=Mock(side_effect=AssertionError('extra CJC preflight forbidden'))
        attempt.resolve_sources=Mock(side_effect=AssertionError('extra resolver forbidden'))
        def target():
            events.append('target');attempt.evidence.update(targetInvocations=1,processExitCode=exit_code)
            attempt.exit_code=exit_code
        attempt.target=Mock(side_effect=target)
        return attempt,events

    def test_execute_reaches_original_stages_without_extra_cjc_preflight_or_resolve(self):
        attempt,events=self.stub_execution()
        with patch.object(pipeline,'publish',return_value={}):self.assertEqual(attempt.execute(),0)
        self.assertEqual(events,['configure','longpaths','authenticate','pins','target'])
        attempt.preflight.assert_not_called();attempt.resolve_sources.assert_not_called()
        self.assertEqual(attempt.evidence['targetInvocations'],1)
        self.assertEqual(attempt.dependencies.call_count,2)

    def test_original_nonzero_exit_survives_integrity_and_publication_failure(self):
        attempt,_=self.stub_execution(exit_code=17,changed_source=True)
        with patch.object(pipeline,'publish',side_effect=ValueError('publication refused')):
            self.assertEqual(attempt.execute(),17)
        self.assertEqual(attempt.evidence['processExitCode'],17)
        self.assertEqual(attempt.evidence['status'],'INPUT_CHANGED')


class MainFailurePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.source=self.root/'source';self.source.mkdir()
        self.output=self.root/'output'

    def invoke(self,constructor,output=None):
        import contextlib
        import io
        stderr=io.StringIO()
        with patch.object(pipeline,'os',SimpleNamespace(name='nt',environ=dict(os.environ))), \
             patch.object(pipeline.platform,'machine',return_value='amd64'), \
             patch.object(pipeline,'PipelineAttempt',constructor), \
             patch.object(pipeline.sys,'argv',['pipeline_codegen_capture.py','--source',str(self.source),
                                             '--output',str(output or self.output)]), \
             contextlib.redirect_stderr(stderr):
            result=pipeline.main()
        self.assertNotIn('private/example-temp',stderr.getvalue())
        self.assertNotIn('Traceback',stderr.getvalue())
        return result

    def test_constructor_path_error_is_hash_only_and_never_printed(self):
        constructor=Mock(side_effect=PermissionError('/private/example-temp'))
        self.assertEqual(self.invoke(constructor),2)
        import json
        receipt=json.loads((self.output/'public/receipt.json').read_text())
        self.assertEqual(receipt['status'],'INITIALIZATION_FAILED')
        self.assertEqual(receipt['targetInvocations'],0)
        self.assertNotIn('private/example-temp',str(receipt))
        self.assertEqual(receipt['errorType'],'PermissionError')

    def test_output_prepare_error_never_adopts_an_existing_parent_file(self):
        blocked=self.root/'parent-file';blocked.write_text('preserve')
        constructor=Mock()
        self.assertEqual(self.invoke(constructor,blocked/'child'),2)
        constructor.assert_not_called();self.assertEqual(blocked.read_text(),'preserve')

    def test_exception_after_original_nonzero_target_preserves_that_exit(self):
        attempt=SimpleNamespace(evidence={'targetInvocations':1,'processExitCode':17},
                                execute=Mock(side_effect=OSError('/private/example-temp')))
        self.assertEqual(self.invoke(Mock(return_value=attempt)),17)
        import json
        receipt=json.loads((self.output/'public/receipt.json').read_text())
        self.assertEqual(receipt['processExitCode'],17)
        self.assertEqual(receipt['controllerExitCode'],17)
        self.assertEqual(receipt['targetInvocations'],1)

    def test_failure_receipt_publication_error_cannot_escape(self):
        constructor=Mock(side_effect=PermissionError('/private/example-temp'))
        with patch.object(pipeline,'publish',side_effect=OSError('/private/example-temp')):
            self.assertEqual(self.invoke(constructor),2)
