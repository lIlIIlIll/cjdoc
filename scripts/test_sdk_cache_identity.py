import json
import os
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from sdk_cache_identity import inspect_cache, publish


def workflow_job(workflow, name):
    body = workflow.split(f"\n  {name}:\n", 1)[1]
    return re.split(r"\n(?=  [A-Za-z0-9_-]+:\s*\n)", body, maxsplit=1)[0]


class CacheIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.cache=Path(self.temporary.name)/'cache'
        self.sdk=self.cache/'toolchain/sdk'
        suffix='.exe' if os.name=='nt' else ''
        names=['bin/cjc','bin/cjc-frontend','tools/bin/cjpm',
               'third_party/llvm/bin/llc','third_party/llvm/bin/opt',
               'third_party/llvm/bin/llvm-dis','third_party/llvm/bin/llvm-as']
        for name in names:
            path=self.sdk/(name+suffix);path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(b'fixture bytes; must never execute')
            path.chmod(0o755)

    def capture(self):return inspect_cache(self.cache,'exact-key','exact-key','true',{})

    def test_manual_cache_mode_cannot_run_capture_or_mutate_cache(self):
        workflow=(Path(__file__).resolve().parents[1]/'.github/workflows/ci.yml').read_text()
        capture=workflow.split('  capture:',1)[1].split('  cache-identity:',1)[0]
        cache=workflow_job(workflow,'cache-identity')
        self.assertIn("if: ${{ inputs.mode == 'capture' }}",capture)
        self.assertIn("if: ${{ inputs.mode == 'cache-identity' }}",cache)
        self.assertIn('actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9',cache)
        self.assertIn('path: ${{ runner.temp }}/setup-cangjie-cjv',cache)
        self.assertIn('fail-on-cache-miss: true',cache)
        self.assertIn('enableCrossOsArchive: false',cache)
        self.assertIn('steps.sdk-cache.outputs.cache-matched-key',cache)
        self.assertIn('steps.sdk-cache.outputs.cache-hit',cache)
        self.assertNotIn('restore-keys:',cache)
        self.assertNotIn('actions/cache@',cache)
        self.assertNotIn('setup-cangjie@',cache)
        self.assertNotIn('cjpm ',cache)
        self.assertIn('path: ${{ runner.temp }}/original-sdk-cache-identity/receipt.json',cache)
        self.assertIn('retention-days: 3',cache)

    def test_cache_job_excludes_an_appended_unrelated_job(self):
        workflow = "jobs:\n  cache-identity:\n    run: inspect-only\n"
        unrelated = "\n  another-job:\n    uses: example/setup-cangjie@fixture\n"
        self.assertEqual(workflow_job(workflow + unrelated, 'cache-identity'),
                         workflow_job(workflow, 'cache-identity'))
        self.assertNotIn('setup-cangjie@', workflow_job(workflow + unrelated, 'cache-identity'))

    def test_records_actual_bytes_without_executing_any_tool(self):
        with patch('subprocess.run',side_effect=AssertionError('must not execute')), patch('subprocess.Popen',side_effect=AssertionError('must not execute')):
            note=self.capture()
        self.assertEqual(note['status'],'CACHE_BYTES_CAPTURED')
        self.assertEqual(len(note['tools']),7)
        self.assertTrue(note['toolBytesStableBeforeAfter'])
        self.assertEqual([note[k] for k in ['compilerInvocations','productTargetInvocations','sdkInstallerInvocations']],[0,0,0])

    def test_miss_or_inexact_key_never_reads_sdk(self):
        for requested,matched,hit in [('exact-key','prefix-key','true'),('exact-key','exact-key','false'),('','','true')]:
            with self.subTest(requested=requested,matched=matched,hit=hit),self.assertRaises(ValueError):
                inspect_cache(self.cache,requested,matched,hit,{})

    def test_multiple_sdks_are_refused(self):
        import shutil
        shutil.copytree(self.sdk,self.cache/'second-sdk')
        with self.assertRaises(ValueError):self.capture()

    def test_changed_tool_is_refused(self):
        from sdk_cache_identity import inventory
        count=0
        def changing(root,paths):
            nonlocal count
            records=inventory(root,paths);count+=1
            if count==1:(root/records[0]['path']).write_bytes(b'changed actual fixture bytes')
            return records
        with patch('sdk_cache_identity.inventory',side_effect=changing),self.assertRaises(ValueError):self.capture()

    def test_tool_symlink_outside_selected_sdk_is_refused(self):
        suffix='.exe' if os.name=='nt' else ''
        tool=self.sdk/'bin'/('cjc'+suffix)
        external=self.cache/'outside-tool';external.write_bytes(b'outside selected SDK')
        tool.unlink();tool.symlink_to(external)
        with self.assertRaises(ValueError):self.capture()

    def test_safe_receipt_publishes_only_generic_tool_paths(self):
        output=Path(self.temporary.name)/'public'
        publish(output,self.capture(),{})
        text=(output/'receipt.json').read_text()
        self.assertNotIn(str(self.cache),text)
        self.assertEqual({f.name for f in output.iterdir()},{'receipt.json'})

    def test_private_output_is_refused_before_directory_creation(self):
        output=Path(self.temporary.name)/'public'
        with self.assertRaises(ValueError):publish(output,{'path':'/private/unknown'},{})
        self.assertFalse(output.exists())

    def test_cache_failure_and_receipt_write_failure_do_not_escape_private_error(self):
        from io import StringIO
        from sdk_cache_identity import main
        error=StringIO();output=Path(self.temporary.name)/'uncreated'
        argv=['sdk_cache_identity','--cache',str(self.cache),'--output',str(output)]
        with patch('sys.argv',argv),patch('sys.stderr',error), patch('sdk_cache_identity.inspect_cache',side_effect=ValueError('private cache read failure')), patch('sdk_cache_identity.publish',side_effect=PermissionError('/private/example-output')):
            self.assertEqual(main(),1)
        self.assertEqual(error.getvalue(),'Cache identity capture failed; safe receipt unavailable.\n')
        self.assertNotIn('/private/',error.getvalue())
        self.assertNotIn(str(self.cache),error.getvalue())

    def test_publication_refuses_existing_directory(self):
        output=Path(self.temporary.name)/'public';output.mkdir()
        marker=output/'owned-by-someone-else';marker.write_text('preserve')
        with self.assertRaises(FileExistsError):publish(output,self.capture(),{})
        self.assertEqual(marker.read_text(),'preserve')


if __name__=='__main__':unittest.main()
