#!/usr/bin/env python3
"""One original full acceptance gate; passive yjson IR capture is diagnostic only."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import platform
import sys

from ir_hardlinks import IrLinks
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


class FullGateAttempt(PipelineAttempt):
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
        self.evidence['sourceCommit']=ORIGINAL_MERGE
        self.evidence['entryProfile']={
            'name':'original-native-full-gate','stages':['preflight','build','native','python-tools','cli','provider'],
            'originalPrMergeCommit':ORIGINAL_MERGE,'sourceTreeEqualsOriginalPrMergeTree':TREE,
            'inheritedTemporaryEnvironment':{key:inherited.get(key) for key in ('TMPDIR','TMP','TEMP','RUNNER_TEMP')},
            'extraCompilerPreflight':False,'extraDependencyResolve':False,'verboseAdded':False,
            'macosFixtureSnapshotAndRestore':selected=='macos-arm64',
            'scope':'Original full check.sh command and stage order; observer, enclosing diagnostic process, core-dump setting and Windows closed Git policy remain differences'}
        self.evidence['argvObservation']='Original nonverbose full gate; CJC argv unobserved; wrapper records are policy evidence only'

    def identity(self):
        result=super().identity();path=Path(__file__).resolve()
        result['modules'].append({'path':str(path),'sha256':digest(path)})
        result['entryShell']={'path':str(self.original_bash),'sha256':digest(self.original_bash)}
        result['candidateFiles']+=inventory(path.parents[1],['scripts/full_gate_codegen_capture.py','scripts/test_full_gate_codegen_capture.py'])
        return result

    def entry_shell(self):
        return str(self.original_bash)

    def retention_links(self):
        return YjsonLinks(self.temporary,self.pipeline_retained)

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


def main():
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
        attempt=FullGateAttempt(args.source,args.output,args.platform)
    except Exception as error:return entry_failure(args.output if prepared else None,error)
    try:return attempt.execute()
    except Exception as error:
        original=attempt.evidence.get('processExitCode')
        code=original if type(original) is int and original!=0 else 2
        return entry_failure(args.output,error,code,attempt)


if __name__=='__main__':raise SystemExit(main())
