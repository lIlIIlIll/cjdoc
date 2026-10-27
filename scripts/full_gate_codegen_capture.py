#!/usr/bin/env python3
"""One original full acceptance gate; passive dependency IR capture is diagnostic only."""
from __future__ import annotations
import argparse
import hashlib
import stat
import os
from pathlib import Path
import platform
import sys

from ir_hardlinks import CaptureMissed, IrLinks
from native_capture_support import digest, inventory
from native_codegen_capture import Attempt, TREE
from pipeline_codegen_capture import PipelineAttempt, inherited_temporary, temporary_aliases, entry_failure

ORIGINAL_MERGE='c98e1db12cda9fa5ec5171ed53050d7372349ce1'


def posix_temporary(environment):
    original=Path(environment['TMPDIR'])
    if original.is_symlink():raise ValueError('inherited temporary leaf is a symlink')
    root=original.resolve(strict=True)
    if not root.is_dir() or root.parent==root:raise ValueError('inherited TMPDIR is not a non-root directory')
    for key in ('TMP','TEMP'):
        if environment.get(key) and Path(environment[key]).resolve(strict=True)!=root:
            raise ValueError('inherited temporary variables disagree')
    aliases=[root]
    if original!=root:
        if not original.is_absolute() or not os.path.samefile(root,original):
            raise ValueError('inherited POSIX temporary alias differs')
        aliases.append(original)
    return root,aliases


class YjsonLinks(IrLinks):
    def accept(self,path):
        if path.name=='yjson.opt.bc':super().accept(path)


class DependencyLinks(IrLinks):
    names=frozenset({'yjson.opt.bc','markdown.opt.bc'})

    def accept(self,path):
        if path.name in self.names:super().accept(path)


class CompilerTempLinks(DependencyLinks):
    """STS 1.2.0 normal compile outputs below direct cangjie-tmp-* children.

    Driver source v1.2.0 (91c24c4): TempFileManager.cpp creates this child
    under inherited TMPDIR and puts T_OPT_BC there; CJNATIVEBackend passes it
    to llc. Prior native captures independently confirm this path shape.
    This namespace is an explicit observation scope, not a filesystem bypass.
    """
    def walk(self):
        roots=[]
        with os.scandir(self.temporary) as entries:
            for entry in entries:
                if entry.name in self.names:
                    raise CaptureMissed('dependency IR outside the compiler temporary namespace')
                if not entry.name.startswith('cangjie-tmp-'):continue
                try:info=entry.stat(follow_symlinks=False)
                except FileNotFoundError:continue
                if not stat.S_ISDIR(info.st_mode) or entry.is_symlink():
                    raise CaptureMissed('compiler temporary child is not an ordinary directory')
                roots.append(Path(entry.path))
        # Keep the inherited Temp root subscribed so late compiler children are
        # discovered. Unrelated first-level namespaces are never traversed.
        yield str(self.temporary),[path.name for path in roots],[]
        def failed(error):
            if isinstance(error,FileNotFoundError):return
            raise error
        for path in roots:
            for directory,names,files in os.walk(path,followlinks=False,onerror=failed):
                for name in names:
                    child=Path(directory)/name
                    try:info=child.lstat()
                    except FileNotFoundError:continue
                    if stat.S_ISLNK(info.st_mode):
                        raise CaptureMissed('symlink inside the compiler temporary namespace')
                yield directory,names,files


class FullGateAttempt(PipelineAttempt):
    source_commit=ORIGINAL_MERGE
    profile_name='original-native-full-gate'
    dependency_links=DependencyLinks
    compiler_temp_links=CompilerTempLinks

    def __init__(self,source,output,selected,**kwargs):
        if selected not in {'windows-x64','macos-arm64'}:raise ValueError('unsupported native platform')
        inherited=os.environ.copy()
        Attempt.__init__(self,source,output,selected,
                         dependency_checkout='windows-crlf' if selected=='windows-x64' else 'canonical',**kwargs)
        for key in ('TMPDIR','TMP','TEMP','RUNNER_TEMP','CJDOC_PYTHON','CJDOC_CI_EVIDENCE','CJDOC_STS_INVOCATION_LOG'):
            self.environment.pop(key,None)
            if key in inherited:self.environment[key]=inherited[key]
        if Path(inherited['GITHUB_WORKSPACE']).resolve(strict=True)!=self.source:
            raise ValueError('full gate requires the original workspace root')
        if selected=='windows-x64':
            self.temporary=inherited_temporary(inherited);self.temporary_aliases=temporary_aliases(self.temporary)
        else:self.temporary,self.temporary_aliases=posix_temporary(inherited)
        self.mappings.extend((path,'<compiler-temp>') for path in self.temporary_aliases)
        self.evidence['verifiedTemporaryAliases']=[str(path) for path in self.temporary_aliases]
        info=self.temporary.stat();self.temp_identity=(info.st_dev,info.st_ino)
        self.evidence['compilerTempIdentityBefore']={'device':info.st_dev,'inode':info.st_ino}
        self.invocations=Path(inherited.get('CJDOC_STS_INVOCATION_LOG',
                              str(Path(inherited['RUNNER_TEMP'])/'cjdoc-sts-invocations.jsonl')))
        if self.invocations.exists() or self.invocations.is_symlink():raise ValueError('original invocation log already exists')
        snapshot=Path(inherited['RUNNER_TEMP'])/'source-edge-fixture.cj'
        if selected=='macos-arm64' and (snapshot.exists() or snapshot.is_symlink()):
            raise ValueError('original fixture snapshot destination already exists')
        self.original_bash=Path(inherited['CJDOC_ORIGINAL_BASH'])
        if not self.original_bash.is_absolute() or not self.original_bash.is_file():
            raise ValueError('original workflow Bash is not an existing absolute executable path')
        self.original_bash.resolve(strict=True)
        self.evidence['sourceCommit']=self.source_commit
        self.evidence['sourceTree']=self.source_tree
        self.evidence['entryProfile']={
            'name':self.profile_name,'stages':['preflight','build','native','python-tools','cli','provider'],
            'originalPrMergeCommit':self.source_commit,'sourceTreeEqualsOriginalPrMergeTree':self.source_tree,
            'inheritedTemporaryEnvironment':{key:inherited.get(key) for key in ('TMPDIR','TMP','TEMP','RUNNER_TEMP')},
            'extraCompilerPreflight':False,'extraDependencyResolve':False,'verboseAdded':False,
            'macosFixtureSnapshotAndRestore':selected=='macos-arm64',
            'scope':'Original full check.sh command and stage order; observer, enclosing diagnostic process, core-dump setting and Windows closed Git policy remain differences'}
        self.evidence['argvObservation']='Original nonverbose full gate; CJC argv unobserved; wrapper records are policy evidence only'

    def identity(self):
        result=super().identity();path=Path(__file__).resolve()
        result['modules'].append({'path':str(path),'sha256':digest(path)})
        result['entryShell']={'path':str(self.original_bash),'sha256':digest(self.original_bash)}
        result['candidateFiles']+=inventory(path.parents[1],['scripts/full_gate_codegen_capture.py','scripts/test_full_gate_codegen_capture.py','scripts/test_compiler_temp_scope.py'])
        return result

    def entry_shell(self):
        return str(self.original_bash)

    def trace_packages(self):
        return ('yjson','markdown')

    def retention_links(self):
        if self.selected!='macos-arm64':
            return self.dependency_links(self.temporary,self.pipeline_retained)
        data=self.tools['cjc'].read_bytes()
        observed={'sha256':hashlib.sha256(data).hexdigest(),'size':len(data)}
        before=self.evidence['toolsBefore']['cjc']
        if any(observed[key]!=before[key] for key in observed):
            raise ValueError('CJC identity changed before directory observation')
        if b'cangjie-tmp-' not in data or b'.opt.bc' not in data:
            raise ValueError('CJC does not contain the frozen temporary namespace literals')
        self.evidence['compilerTempObservation']={
            'profile':'sts-1.2.0-direct-cangjie-tmp-children',
            'inheritedTempRootMonitored':True,'recursiveCompilerChildren':True,
            'unrelatedFirstLevelNamespaces':'EXCLUDED',
            'namespacePermissionErrors':'FAIL_CAPTURE',
            'sourceProtocolCommit':'91c24c4fc5ce6d77cb14ff6d63d04dca85e5d803',
            'observedCjc':observed,'frozenLiteralsPresent':True,
            'provenanceLimit':'Release-tag driver source and native path observations; not an exact binary rebuild proof'}
        return self.compiler_temp_links(self.temporary,self.pipeline_retained)

    def stage_script(self):
        script='set -euo pipefail\n'
        if self.selected=='macos-arm64':
            script+=('fixture="$GITHUB_WORKSPACE/tests/fixtures/projects/source_edges/src/fixture.cj"\n'
                'pristine="$RUNNER_TEMP/source-edge-fixture.cj"\n'
                'cp -p "$fixture" "$pristine"\n'
                'restore_fixture() {\n'
                '  status=$?\n  trap - EXIT\n'
                '  cp -p "$pristine" "$fixture" || { if [ "$status" = 0 ]; then status=2; fi; }\n'
                '  exit "$status"\n}\ntrap restore_fixture EXIT\n')
        return script+('export CANGJIE_STDX_PATH="${CJDOC_STDX_PATH}"\n'
            '. "$GITHUB_WORKSPACE/scripts/with_sts_cjpm.sh"\n'
            'bash scripts/check.sh --manifest target/ci-build/build-manifest.json '
            '--worker-binary-out target/release/bin/chir-worker-main\n')


def main(attempt_type=None):
    if attempt_type is None:attempt_type=FullGateAttempt
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--platform',choices=('windows-x64','macos-arm64'),required=True)
    args=parser.parse_args()
    native=(os.name=='nt' and platform.machine().lower() in {'amd64','x86_64'}) if args.platform=='windows-x64' else (
        sys.platform=='darwin' and platform.machine().lower()=='arm64')
    if not native:parser.error('requested native platform unavailable; no target started')
    prepared=False
    try:
        if args.output.exists() or args.output.is_symlink():parser.error('output exists; no retry')
        args.output.mkdir(mode=0o700);prepared=True
        attempt=attempt_type(args.source,args.output,args.platform)
    except Exception as error:return entry_failure(args.output if prepared else None,error)
    try:return attempt.execute()
    except Exception as error:
        original=attempt.evidence.get('processExitCode')
        code=original if type(original) is int and original!=0 else 2
        return entry_failure(args.output,error,code,attempt)


if __name__=='__main__':raise SystemExit(main())
