#!/usr/bin/env python3
"""Observe the original Windows preflight/build stages without compiler warm-up."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tempfile

from ir_events import EventWatch
from ir_hardlinks import CaptureMissed, IrLinks
from ir_publication import publish
from native_backend_trace import TRACE_PACKAGES, TraceRequest, observed_profile, trace_once
from native_capture_support import digest, inventory
from native_codegen_capture import Attempt, ChildFailed, SOURCE, TREE


def inherited_temporary(environment):
    # The frozen failing Windows command used the inherited system temp volume.
    # Do not select a replacement directory or invoke CJC to discover this path.
    original=[Path(environment[key]) for key in ('TMP','TEMP')]
    if any(path.is_symlink() for path in original):raise ValueError('inherited temporary root is a symlink')
    paths=[path.resolve(strict=True) for path in original]
    if paths[0]!=paths[1] or not paths[0].is_dir() or paths[0].parent==paths[0]:
        raise ValueError('inherited TMP and TEMP must name one existing non-root directory')
    if environment.get('TMPDIR') and Path(environment['TMPDIR']).resolve(strict=True)!=paths[0]:
        raise ValueError('inherited TMPDIR differs; compiler temporary root is ambiguous')
    if paths[0].is_symlink():raise ValueError('inherited temporary root is a symlink')
    return paths[0]



def temporary_aliases(root, lookup=None):
    if lookup is None:
        import ctypes
        from ctypes import wintypes
        kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        def lookup(name,value):
            function=getattr(kernel,name)
            function.argtypes=[wintypes.LPCWSTR,wintypes.LPWSTR,wintypes.DWORD]
            function.restype=wintypes.DWORD
            buffer=ctypes.create_unicode_buffer(32768)
            size=function(str(value),buffer,len(buffer))
            if not size or size>=len(buffer):raise OSError('Windows temporary path alias lookup failed')
            return buffer.value
    aliases=[root]
    for api in ('GetLongPathNameW','GetShortPathNameW'):
        path=Path(lookup(api,root))
        if not path.is_absolute() or not path.is_dir() or not os.path.samefile(root,path):
            raise ValueError('Windows temporary alias does not identify the same existing directory')
        if str(path).casefold() not in {str(item).casefold() for item in aliases}:aliases.append(path)
    return aliases


def select_yjson(rows, result, log, tools, temporary, retained, environment, aliases=None, selected="windows-x64", packages=("yjson",), scope="dependencies"):
    if not packages or len(set(packages))!=len(packages) or not set(packages)<=TRACE_PACKAGES.get(scope, frozenset()):
        raise ValueError('trace packages differ from the frozen scope')
    filenames={name+'.opt.bc' for name in packages}
    candidates=[row for row in rows if row['name'] in filenames]
    if not candidates:raise CaptureMissed('original pipeline produced no captured authorized dependency IR; no retry')
    failures=[line for line in log.splitlines() if any(name in line for name in filenames) and 'llc' in line
              and 'command failed with exit code' in line]
    if not failures:
        first=next((row for row in candidates if row['name']=='yjson.opt.bc'),candidates[0])
        return first,None,temporary/first['sourceRelative']
    if result.returncode==0 or len(failures)!=1:
        raise CaptureMissed('backend failure does not bind one failed original pipeline')
    matches=[]
    for row in candidates:
        for alias in aliases or [temporary]:
            original=alias/row['sourceRelative']
            request=TraceRequest(selected,tools['llc'],digest(tools['llc']),
                retained/row['retained'],row['sha256'],original,
                log,retained/'unused-profile-check',environment,package=row['name'].removesuffix('.opt.bc'),scope=scope)
            try:observed_profile(request)
            except ValueError:continue
            matches.append((row,original))
    if len(matches)!=1:raise CaptureMissed('failed backend argv does not bind exactly one captured yjson IR')
    return matches[0][0],failures[0],matches[0][1]


class PipelineAttempt(Attempt):
    source_tree=TREE
    trace_scope="dependencies"

    def __init__(self,source,output,selected='windows-x64',**kwargs):
        if selected!='windows-x64':raise ValueError('original pipeline profile is Windows-only')
        inherited=os.environ.copy()
        super().__init__(source,output,selected,dependency_checkout='windows-crlf',**kwargs)
        # Restore the original workflow process environment; no private TMP or
        # RUNNER_TEMP override, extra CJC compilation, update or verbose flag.
        for key in ('TMPDIR','TMP','TEMP','RUNNER_TEMP','CJDOC_PYTHON','CJDOC_CI_EVIDENCE',
                    'CJDOC_STS_INVOCATION_LOG'):
            self.environment.pop(key,None)
            if key in inherited:self.environment[key]=inherited[key]
        if Path(inherited['GITHUB_WORKSPACE']).resolve(strict=True)!=self.source:
            raise ValueError('original pipeline requires the workspace root checkout')
        self.temporary=inherited_temporary(inherited)
        self.temporary_aliases=temporary_aliases(self.temporary)
        self.mappings.extend((path,'<compiler-temp>') for path in self.temporary_aliases)
        self.evidence['verifiedTemporaryAliases']=[str(path) for path in self.temporary_aliases]
        info=self.temporary.stat();self.temp_identity=(info.st_dev,info.st_ino)
        self.evidence['compilerTempIdentityBefore']={'device':info.st_dev,'inode':info.st_ino}
        self.invocations=Path(inherited.get('CJDOC_STS_INVOCATION_LOG',
                              str(Path(inherited['RUNNER_TEMP'])/'cjdoc-sts-invocations.jsonl')))
        if self.invocations.exists() or self.invocations.is_symlink():
            raise ValueError('original wrapper invocation log already exists')
        self.evidence['entryProfile']={
            'name':'original-windows-preflight-build',
            'stages':['preflight','build'],
            'sourceTreeEqualsOriginalPrMergeTree':TREE,
            'originalPrMergeCommit':'c98e1db12cda9fa5ec5171ed53050d7372349ce1',
            'inheritedTemporaryEnvironment':{key:inherited.get(key) for key in ('TMPDIR','TMP','TEMP','RUNNER_TEMP')},
            'extraCompilerPreflight':False,'extraDependencyResolve':False,
            'verboseAdded':False,
            'scope':'Original stage bodies and ci_stage process chain; split preflight/build outer calls, diagnostic observer and closed Git policy remain differences'}
        self.evidence['argvObservation']='Original nonverbose pipeline; actual CJC argv unobserved; wrapper records are policy evidence only'

    def identity(self):
        result=super().identity();path=Path(__file__).resolve();root=path.parents[1]
        result['modules'].append({'path':str(path),'sha256':digest(path)})
        result['candidateFiles']+=inventory(root,['scripts/pipeline_codegen_capture.py',
                                                 'scripts/test_pipeline_codegen_capture.py'])
        return result

    def trace_packages(self):
        return ('yjson',)

    def entry_shell(self):
        return shutil.which('bash',path=self.environment['PATH'])

    def stage_script(self):
        return ('set -euo pipefail\n'
            'export CANGJIE_STDX_PATH="${CJDOC_STDX_PATH}"\n'
            '. "$GITHUB_WORKSPACE/scripts/with_sts_cjpm.sh"\n'
            'bash scripts/check.sh preflight --manifest target/ci-build/build-manifest.json '
            '--worker-binary-out target/release/bin/chir-worker-main\n'
            'bash scripts/check.sh build --manifest target/ci-build/build-manifest.json '
            '--worker-binary-out target/release/bin/chir-worker-main\n')

    def retention_links(self):
        return IrLinks(self.temporary,self.pipeline_retained)

    def target(self):
        if (self.source/'target').exists():raise ValueError('original build target must be fresh')
        if list(self.temporary.rglob('*.opt.bc')):
            raise CaptureMissed('inherited temp contains prior optimized IR; no files removed')
        shell=self.entry_shell()
        if shell is None:raise ValueError('original Bash entry unavailable')
        self.mappings.extend([(Path(shell),'<bash>'),(Path(shell).resolve(),'<bash>')])
        self.pipeline_retained=Path(tempfile.mkdtemp(prefix='cjdoc-pipeline-retained-',dir=self.temporary.parent))
        self.pipeline_retained.chmod(0o700)
        self.mappings.append((self.pipeline_retained,'<retained>'))
        self.evidence['retentionRoot']=str(self.pipeline_retained)
        links=self.retention_links()
        watch=self.watcher(links,self.selected)
        script=self.private/'original-stages.sh'
        script.write_text(self.stage_script())
        (self.output/'target-attempt.marker').open('x').close()
        self.evidence['targetCommand']=[shell,str(script)]
        try:
            watch.start()
            try:
                self.evidence['targetInvocations']=1
                result=self.call('target',[shell,str(script)],self.source,checked=False)
                self.evidence['processExitCode']=result.returncode
                self.exit_code=result.returncode;self.build_log=result.stdout+result.stderr
            finally:watch.stop()
            rows=links.finish();self.evidence['targetCaptured']=rows
        finally:self.evidence['targetCaptureIssues']=links.issues
        self.evidence['status']='CAPTURED_BUILD_FAILED' if result.returncode else 'CAPTURED_BUILD_SUCCEEDED'
        selected,failure,original=select_yjson(rows,result,self.build_log,self.tools,self.temporary,
                                     self.pipeline_retained,self.environment,self.temporary_aliases,selected=self.selected,packages=self.trace_packages(),scope=self.trace_scope)
        package=selected['name'].removesuffix('.opt.bc')
        meaning='Unique original failed backend path' if failure else 'First observed '+package+' input; no failed backend reported'
        self.evidence['selectedDependencyIr']=selected
        self.evidence['selectedDependencyPackage']=package
        self.evidence['selectedDependencyMeaning']=meaning
        self.evidence['tracePackages']=list(self.trace_packages())
        if package=='yjson':
            self.evidence['selectedYjson']=selected;self.evidence['selectedYjsonMeaning']=meaning
        self.evidence['wrapperInvocationLog']=None
        if self.invocations.is_file():
            data=self.invocations.read_bytes()
            self.evidence['wrapperInvocationLog']={'sha256':hashlib.sha256(data).hexdigest(),
                'size':len(data),'records':[json.loads(line) for line in data.splitlines() if line]}
        # Keep the original product result even if optional disassembly fails.
        try:
            text=self.disassemble(package,self.pipeline_retained,selected)
            if package=='yjson':self.disassemblies=[(selected['sha256'],text)]
            else:self.evidence['derivedIrPublication']={'package':package,'status':'PRIVATE_ONLY',
                'reason':'Public derived IR allowlist currently covers yjson only'}
        except Exception as error:self.evidence['disassemblyUnavailable']=type(error).__name__
        if failure is None:
            self.evidence['backendTrace']={'backendInvocations':0,'reason':'Original command did not report a failure for the authorized trace packages'}
        else:
            directory=self.private/'backend-trace'
            try:
                request=TraceRequest(self.selected,self.tools['llc'],self.evidence['toolsBefore']['llc']['sha256'],
                    self.pipeline_retained/selected['retained'],selected['sha256'],
                    original,self.build_log,directory,self.environment,package=package,scope=self.trace_scope)
                self.evidence['backendTrace']=trace_once(request)
                if not self.evidence['backendTrace']['inputsUnchanged']:
                    self.evidence['status']='INPUT_CHANGED';self.evidence['integrityError']='backend input changed'
            except Exception as error:
                self.evidence['backendTrace']={'status':'UNAVAILABLE','backendAttempts':int(directory.exists()),
                    'backendInvocations':'UNKNOWN' if directory.exists() else 0,'reason':type(error).__name__+': '+str(error)}

    def execute(self):
        initial=None
        try:
            self.evidence['controllerBefore']=self.identity()
            (self.output/'attempt.marker').open('x').close()
            self.configure_dependency_inputs()
            if self.selected=='windows-x64':
                self.git.read(self.source,'config','--global','core.longpaths','true')
            initial=self.git.snapshot(self.source,self.evidence['sourceCommit'],self.source_tree);self.evidence['sourceBefore']=initial
            self.authenticate();self.lock_pins()
            prior=self.dependencies(allow_missing=True)
            self.evidence['dependenciesBeforeTarget']=prior
            if any(note.get('present') is not False for note in prior.values()):
                raise ValueError('original fresh-job profile requires absent Git dependency caches')
            self.target()
        except Exception as error:
            if isinstance(error,ChildFailed):self.exit_code=error.code
            elif not self.evidence.get('processExitCode'):self.exit_code=2
            self.evidence['status']='CAPTURE_MISSED' if isinstance(error,CaptureMissed) else 'PRECONDITION_OR_CAPTURE_FAILED'
            self.evidence['error']=type(error).__name__+': '+str(error)
        finally:
            try:
                self.evidence['integrityPhase']='TEMP'
                info=self.temporary.stat()
                self.evidence['compilerTempIdentityAfter']={'device':info.st_dev,'inode':info.st_ino}
                if (info.st_dev,info.st_ino)!=self.temp_identity or any(
                        not os.path.samefile(self.temporary,path) for path in self.temporary_aliases):
                    raise ValueError('inherited compiler temp directory or verified aliases changed')
                self.evidence['integrityPhase']='CONTROLLER'
                self.evidence['controllerAfter']=self.identity()
                if self.evidence['controllerAfter']!=self.evidence.get('controllerBefore'):
                    raise ValueError('controller identity changed')
                if initial is not None:
                    self.evidence['integrityPhase']='SOURCE'
                    after=self.git.snapshot(self.source,self.evidence['sourceCommit'],self.source_tree);self.evidence['sourceAfter']=after
                    if after!=initial:raise ValueError('source identity changed')
                if self.evidence['targetInvocations']:
                    self.evidence['integrityPhase']='DEPENDENCIES'
                    after=self.dependencies(allow_missing=True);self.evidence['dependenciesAfterTarget']=after
                    if 'processExitCode' in self.evidence and self.evidence['processExitCode']==0:
                        if any(note.get('present') is False for note in after.values()):
                            raise ValueError('successful pipeline omitted a fixed dependency')
                if hasattr(self,'tools'):
                    self.evidence['integrityPhase']='TOOLS'
                    self.evidence['toolsAfter']=self.tool_hashes()
                    if self.evidence['toolsAfter']!=self.evidence['toolsBefore']:raise ValueError('SDK tool identity changed')
                self.evidence['integrityPhase']='COMPLETE'
            except Exception as error:
                self.evidence['integrityError']=str(error);self.evidence['status']='INPUT_CHANGED'
                if not self.evidence.get('processExitCode'):self.exit_code=2
            for index,(stdout,stderr) in enumerate(self.git.raw_calls):
                (self.private/('git-'+str(index)+'.stdout')).write_bytes(stdout)
                (self.private/('git-'+str(index)+'.stderr')).write_bytes(stderr)
            self.evidence['gitCalls']=self.git.calls
            self.evidence['gitNormalizedObservations']=self.git.normalized_observations
            self.evidence['lastRejectedWorkingSnapshot']=getattr(self.git,'last_snapshot',None)
            self.evidence['controllerExitCode']=self.exit_code
            try:publish(self.output/'public',self.evidence,self.build_log,self.disassemblies,
                        self.mappings,self.environment,self.validate_derived if hasattr(self,'tools') else None)
            except Exception as error:
                self.evidence['publicationError']=str(error)
                if not self.evidence.get('processExitCode'):self.exit_code=2
            self.evidence['controllerExitCode']=self.exit_code
            (self.private/'receipt.raw.json').write_text(json.dumps(self.evidence,indent=2)+'\n')
        return self.exit_code



def entry_failure(output,error,code=2,attempt=None):
    # Error text can contain private paths. Never send it to hosted stdout/stderr,
    # including when publishing this minimal failure receipt itself fails.
    evidence=getattr(attempt,'evidence',{})
    note={'status':'CONTROLLER_FAILED' if attempt is not None else 'INITIALIZATION_FAILED',
          'diagnosticOnly':True,'targetInvocations':evidence.get('targetInvocations',0),
          'controllerExitCode':code,'errorType':type(error).__name__,
          'errorTextSha256':hashlib.sha256(str(error).encode('utf-8','replace')).hexdigest(),
          'rawBitcodePublished':False}
    if 'processExitCode' in evidence:note['processExitCode']=evidence['processExitCode']
    if output is not None:
        try:publish(output/'public',note,'',[],[],dict(os.environ))
        except Exception:pass
    print('Diagnostic entry failed; private exception text withheld.',file=sys.stderr)
    return code


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if os.name!='nt' or platform.machine().lower() not in {'amd64','x86_64'}:
        parser.error('original pipeline diagnostic is native Windows-only')
    prepared=False
    try:
        if args.output.exists() or args.output.is_symlink():parser.error('output exists; no retry')
        args.output.mkdir(mode=0o700);prepared=True
        attempt=PipelineAttempt(args.source,args.output)
    except Exception as error:
        return entry_failure(args.output if prepared else None,error)
    try:return attempt.execute()
    except Exception as error:
        original=attempt.evidence.get('processExitCode')
        code=original if type(original) is int and original!=0 else 2
        return entry_failure(args.output,error,code,attempt)


if __name__=='__main__':raise SystemExit(main())
