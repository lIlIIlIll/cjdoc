"""Checker unit fixtures; native byte identity is accepted separately."""
import copy
import hashlib
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock

import crlf_working_inputs as policy
from native_capture_support import inventory
import test_native_codegen_capture as fixtures


class FrozenWorkingInputTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixtures.RawGitSnapshotTests()
        self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        f=self.fixture;f.head=policy.PINS['yjson']
        # LF OID independently obtained with git hash-object --stdin.
        f.entries[0]='100644 blob a999a0c211215fd28e77d6a7c66ade6ec76ccbcb\tfixture.cj'
        f.index=[row.replace(' blob ',' ').replace(' commit ',' ').replace('\t',' 0\t',1) for row in f.entries]
        rows=[]
        for row in inventory(f.root,['fixture.cj','tool.sh']):
            canonical=next(entry.split('\t',1)[0].split() for entry in f.entries if entry.endswith('\t'+row['path']))
            rows.append({'path':row['path'],'canonicalGitBlobSha1':canonical[2],'gitMode':canonical[0],
                         'workingSha256':row['sha256'],'workingGitBlobSha1':row['gitBlobSha1'],'workingSize':row['size']})
        self.expected={'_name':'yjson','_catalogSha256':policy.CATALOG_SHA256,
                       'commit':f.head,'tree':f.tree,'files':rows}

    def test_strict_default_still_refuses_crlf_working_bytes_against_lf_git_blob(self):
        with self.assertRaisesRegex(ValueError,'raw working bytes differ'):
            self.fixture.evidence().snapshot(self.fixture.root,self.fixture.head,self.fixture.tree)

    def test_profile_accepts_exact_working_bytes_and_reports_canonical_difference(self):
        result=self.fixture.evidence().snapshot(self.fixture.root,self.fixture.head,self.fixture.tree,expected_working=self.expected)
        self.assertFalse(result['rawGitBlobsVerified'])
        self.assertTrue(result['indexMatchesHead']);self.assertTrue(result['workingCheckoutVerified'])
        self.assertEqual(result['workingCheckoutVerification']['exactWorkingFiles'],2)

    def test_profile_still_refuses_changed_index_oid_and_mode(self):
        for replacement in ['100644 '+'d'*40+' 0\tfixture.cj',
                            '100755 a999a0c211215fd28e77d6a7c66ade6ec76ccbcb 0\tfixture.cj']:
            with self.subTest(replacement=replacement),self.assertRaisesRegex(ValueError,'Git index differs'):
                self.fixture.evidence(index=[replacement,*self.fixture.index[1:]]).snapshot(
                    self.fixture.root,self.fixture.head,self.fixture.tree,expected_working=self.expected)

    def test_profile_refuses_actual_extra_or_mixed_newlines(self):
        for data in [b'line\n',b'line\r\n\n',b'changed\r\n']:
            with self.subTest(data=data):
                (self.fixture.root/'fixture.cj').write_bytes(data)
                with self.assertRaisesRegex(ValueError,'raw working bytes differ from frozen checkout catalog'):
                    self.fixture.evidence().snapshot(self.fixture.root,self.fixture.head,self.fixture.tree,expected_working=self.expected)

    def test_profile_refuses_wrong_catalog_commit_tree_oid_hash_and_file_set(self):
        variants=[]
        for key,value in [('_catalogSha256','0'*64),('commit','0'*40),('tree','0'*40)]:
            row=copy.deepcopy(self.expected);row[key]=value;variants.append(row)
        for key,value in [('canonicalGitBlobSha1','0'*40),('gitMode','100755'),
                          ('workingSha256','0'*64),('workingGitBlobSha1','0'*40),('workingSize',1)]:
            row=copy.deepcopy(self.expected);row['files'][0][key]=value;variants.append(row)
        row=copy.deepcopy(self.expected);row['files'].pop();variants.append(row)
        row=copy.deepcopy(self.expected);row['files'].append(copy.deepcopy(row['files'][0]));variants.append(row)
        for expected in variants:
            with self.subTest(expected=expected),self.assertRaises(ValueError):
                self.fixture.evidence().snapshot(self.fixture.root,self.fixture.head,self.fixture.tree,expected_working=expected)

    def test_real_frozen_catalog_all_repositories_and_bytes_are_bound(self):
        path=Path(__file__).with_name('windows_crlf_catalog.json')
        catalog=policy.load_catalog(path)
        self.assertEqual({name:len(row['files']) for name,row in catalog.items()},
                         {'yjson':1775,'markdown':212,'yjson_macros':7})
        changed=self.fixture.root/'catalog.json';changed.write_bytes(path.read_bytes()+b'\n')
        with self.assertRaisesRegex(ValueError,'catalog bytes differ'):policy.load_catalog(changed)


class GitClosureTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name);self.private=self.root/'private';self.private.mkdir()
        self.repository=self.root/'repository';self.repository.mkdir()
        self.environment,self.note=policy.closed_git_environment({},self.private)
        self.git=SimpleNamespace(environment=self.environment,read=Mock(side_effect=self.read))

    def read(self,root,*args,check=True):
        if args==('rev-parse','--git-path','info/attributes'):
            return SimpleNamespace(stdout=str(root/'.git/info/attributes'),returncode=0)
        if args[0]=='config':return SimpleNamespace(stdout='',returncode=1)
        raise AssertionError('unsafe or unexpected Git operation')

    def test_catalog_disk_drift_changes_controller_identity(self):
        import shutil
        import native_codegen_capture as capture
        from unittest.mock import patch
        original=Path(capture.__file__).resolve().parents[1]
        isolated=self.root/'identity-source'
        files=['native_codegen_capture.py','ir_events.py','ir_hardlinks.py','ir_publication.py',
               'native_capture_support.py','native_backend_trace.py','crlf_working_inputs.py',
               'test_native_codegen_capture.py','test_native_backend_trace.py',
               'test_crlf_working_inputs.py','windows_crlf_catalog.json']
        for relative in ['scripts/'+name for name in files]+['.github/workflows/ci.yml']:
            target=isolated/relative;target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(original/relative,target)
        output=self.root/'identity-attempt';output.mkdir()
        attempt=capture.Attempt(self.repository,output,'windows-x64',dependency_checkout='windows-crlf')
        with patch.object(capture,'__file__',str(isolated/'scripts/native_codegen_capture.py')):
            attempt.configure_dependency_inputs()
            before=attempt.identity()
            catalog=isolated/'scripts/windows_crlf_catalog.json'
            catalog.write_bytes(catalog.read_bytes()+b'\n')
            after=attempt.identity()
        self.assertNotEqual(before,after)
        paths={row['path'] for row in before['candidateFiles']}
        self.assertTrue({'scripts/windows_crlf_catalog.json','scripts/test_crlf_working_inputs.py'}<=paths)

    def test_controller_configures_closed_profile_before_any_git_or_compiler_call(self):
        from native_codegen_capture import Attempt
        output=self.root/'attempt';output.mkdir()
        runner=Mock(side_effect=AssertionError('configuration must not execute tools'))
        attempt=Attempt(self.repository,output,'windows-x64',runner=runner,dependency_checkout='windows-crlf')
        original=attempt.environment
        attempt.configure_dependency_inputs()
        self.assertIs(attempt.environment,original)
        self.assertIs(attempt.git.environment,original)
        self.assertEqual(set(attempt.expected_working),set(policy.PINS))
        self.assertEqual(attempt.evidence['dependencyCheckoutPolicy']['profile'],policy.PROFILE)
        self.assertTrue(callable(attempt.git.input_policy_guard))
        self.assertEqual(attempt.evidence['targetInvocations'],0)
        runner.assert_not_called()

    def test_closed_environment_removes_inherited_filters_attributes_and_templates(self):
        private=self.root/'other-private';private.mkdir()
        original={'GIT_ATTR_SOURCE':'untrusted','GIT_CONFIG_GLOBAL':'untrusted',
                  'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'filter.tripwire.smudge',
                  'GIT_CONFIG_VALUE_0':'must-not-execute','GIT_TEMPLATE_DIR':'untrusted','KEEP':'value'}
        configured,note=policy.closed_git_environment(original,private)
        self.assertEqual(original['GIT_CONFIG_KEY_0'],'filter.tripwire.smudge')
        self.assertNotIn('GIT_ATTR_SOURCE',configured)
        self.assertNotIn('must-not-execute',configured.values())
        self.assertEqual(configured['GIT_CONFIG_NOSYSTEM'],'1')
        self.assertEqual(configured['GIT_ATTR_NOSYSTEM'],'1')
        self.assertEqual(configured['KEEP'],'value')
        self.assertEqual(Path(configured['GIT_CONFIG_GLOBAL']).read_bytes(),b'')
        self.assertFalse(list(Path(configured['GIT_TEMPLATE_DIR']).iterdir()))

    def test_empty_closure_and_private_longpaths_config_are_accepted(self):
        policy.guard_attributes(self.git,self.repository)
        Path(self.environment['GIT_CONFIG_GLOBAL']).write_bytes(b'[core]\r\n\tlongpaths = true\r\n')
        policy.guard_attributes(self.git,self.repository)

    def test_untracked_nested_attribute_tripwire_is_stopped_before_any_git_operation(self):
        path=self.repository/'nested/.gitattributes';path.parent.mkdir();path.write_text('* filter=tripwire\n')
        with self.assertRaisesRegex(ValueError,'unexpected Git attribute'):policy.guard_attributes(self.git,self.repository)
        self.git.read.assert_not_called()

    def test_info_attribute_tripwire_is_stopped_before_local_config_or_diff(self):
        path=self.repository/'.git/info/attributes';path.parent.mkdir(parents=True);path.write_text('* filter=tripwire\n')
        with self.assertRaisesRegex(ValueError,'info attributes'):policy.guard_attributes(self.git,self.repository)
        self.assertEqual(self.git.read.call_count,1)

    def test_modified_empty_attribute_template_or_global_config_is_stopped_before_git(self):
        paths=[Path(self.environment['GIT_CONFIG_VALUE_2']),Path(self.environment['GIT_TEMPLATE_DIR'])/'post-checkout',
               Path(self.environment['GIT_CONFIG_GLOBAL'])]
        for path in paths:
            with self.subTest(path=path.name):
                path.write_text('filter tripwire must not execute')
                with self.assertRaises(ValueError):policy.guard_attributes(self.git,self.repository)
                self.git.read.assert_not_called()
                if path.name=='post-checkout':path.unlink()
                else:path.write_bytes(b'')

    def test_local_include_configuration_is_refused_before_following_it(self):
        import subprocess
        config=self.repository/'local.gitconfig'
        for section in ['include','includeIf "gitdir:untrusted/"']:
            with self.subTest(section=section):
                config.write_text('['+section+']\n    path = must-not-be-read.gitconfig\n')
                def read(root,*args,check=True):
                    if args[0]=='rev-parse':
                        return SimpleNamespace(stdout=str(root/'.git/info/attributes'),returncode=0)
                    if args[:2]==('config','--local'):
                        return subprocess.run(['git','config','--file',str(config),*args[2:]],
                                              capture_output=True,text=True,check=False)
                    raise AssertionError('diff/filter/include must not execute')
                self.git.read=Mock(side_effect=read)
                with self.assertRaisesRegex(ValueError,'local Git filter'):
                    policy.guard_attributes(self.git,self.repository)
                self.assertEqual(self.git.read.call_count,2)

    def test_local_filter_configuration_is_refused_without_invoking_diff(self):
        def read(root,*args,check=True):
            if args[0]=='rev-parse':return SimpleNamespace(stdout=str(root/'.git/info/attributes'),returncode=0)
            if args[0]=='config':return SimpleNamespace(stdout='filter.tripwire.smudge must-not-execute',returncode=0)
            raise AssertionError('diff/filter must not execute')
        self.git.read=Mock(side_effect=read)
        with self.assertRaisesRegex(ValueError,'local Git filter'):policy.guard_attributes(self.git,self.repository)
        self.assertEqual(self.git.read.call_count,2)


if __name__=='__main__':unittest.main()
