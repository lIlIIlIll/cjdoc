"""Read existing SDK bytes only; never run installers, compilers, or targets."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

import native_capture_support
from native_capture_support import inventory, private_reasons, tools_for_sdk


def inspect_cache(cache, requested, matched, hit, environment):
    if not requested or requested != matched or hit != 'true':
        raise ValueError('exact SDK cache key was not restored')
    cache=cache.resolve(strict=True)
    suffix='.exe' if os.name=='nt' else ''
    roots=set()
    for path in cache.rglob('cjc'+suffix):
        root=path.parent.parent.resolve(strict=True)
        if (path.parent.name=='bin' and root.is_relative_to(cache)
                and (root/'bin'/('cjc-frontend'+suffix)).is_file()
                and (root/'third_party/llvm/bin'/('llc'+suffix)).is_file()):
            roots.add(root)
    if len(roots)!=1:
        raise ValueError('expected one complete SDK in restored cache')
    sdk=roots.pop()
    selected=dict(environment,CANGJIE_HOME=str(sdk))
    selected['PATH']=os.pathsep.join([str(sdk/'bin'),str(sdk/'tools/bin'),environment.get('PATH','')])
    observed,tools=tools_for_sdk(selected)
    assert observed==sdk
    relative={name:path.relative_to(sdk).as_posix() for name,path in tools.items()}
    paths=set(relative.values())
    before=inventory(sdk,paths)
    after=inventory(sdk,paths)
    if before!=after:raise ValueError('SDK tools changed during read-only inventory')
    rows={row['path']:row for row in before}
    return {
        'schema':'cjdoc.sdk-cache-identity/1',
        'status':'CACHE_BYTES_CAPTURED',
        'diagnosticOnly':True,
        'compilerInvocations':0,'productTargetInvocations':0,'sdkInstallerInvocations':0,
        'requestedCacheKey':requested,'matchedCacheKey':matched,'exactCacheHit':True,
        'cacheEntryIdentity':'Restore action exposes matched key; entry ID and archive version are not directly observed',
        'toolBytesStableBeforeAfter':True,
        'tools':{name:{'path':'<cached-sdk>/'+path,'sha256':rows[path]['sha256'],
                       'size':rows[path]['size']} for name,path in relative.items()},
        'workflow':{key:environment.get(key,'') for key in
                    ('GITHUB_SHA','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_REF','RUNNER_OS','RUNNER_ARCH')},
        'controllerFileSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'supportModuleFileSha256':hashlib.sha256(Path(native_capture_support.__file__).read_bytes()).hexdigest(),
        'limitations':['Current restored cache bytes do not directly observe the original failed compiler process',
                       'Tool equality alone does not compare every SDK module or establish a compiler root cause'],
    }


def publish(output, note, environment):
    text=json.dumps(note,indent=2)+'\n'
    if private_reasons(text,environment):raise ValueError('cache identity receipt failed privacy scan')
    output.mkdir(mode=0o700)
    (output/'receipt.json').write_text(text,encoding='utf-8')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    environment=dict(os.environ)
    try:
        note=inspect_cache(args.cache,environment.get('CJDOC_CACHE_REQUESTED',''),
                           environment.get('CJDOC_CACHE_MATCHED',''),environment.get('CJDOC_CACHE_HIT',''),environment)
        publish(args.output,note,environment)
    except Exception as error:
        # Error contents may contain private paths: report type and hash only.
        note={'schema':'cjdoc.sdk-cache-identity/1','status':'CACHE_IDENTITY_FAILED',
              'compilerInvocations':0,'productTargetInvocations':0,'sdkInstallerInvocations':0,
              'errorType':type(error).__name__,'errorSha256':hashlib.sha256(str(error).encode()).hexdigest()}
        try:
            if not args.output.exists():publish(args.output,note,environment)
        except Exception:
            print('Cache identity capture failed; safe receipt unavailable.',file=sys.stderr)
            return 1
        print('Cache identity capture failed; inspect the safe receipt.',file=sys.stderr)
        return 1
    print(json.dumps({'status':note['status'],'tools':len(note['tools']),
                      'compilerInvocations':0,'productTargetInvocations':0,'sdkInstallerInvocations':0}))
    return 0


if __name__=='__main__':raise SystemExit(main())
