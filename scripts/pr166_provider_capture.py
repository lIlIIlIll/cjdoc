#!/usr/bin/env python3
"""One fixed PR166 full gate, retaining its cjdoc/markdown backend inputs."""
from pathlib import Path

from full_gate_codegen_capture import (
    CompilerTempLinks, DependencyLinks, FullGateAttempt, main as full_gate_main,
)
from native_capture_support import digest, inventory

HEAD = '155fb458f90fa6f29f89c74ca8f4d1582b61792c'
MERGE = 'bf0e39ddddb28c28c71fddc595910619257b48c4'
TREE = 'f360c6c90267321e5940ead9071182193fc011f5'
BASE = '9bf41bbd6e91a6cea4ff8dd109403abd7618776b'
PROFILE = 'pr166-provider-155'
NAMES = frozenset({'cjdoc.opt.bc', 'markdown.opt.bc'})


class ProviderDependencyLinks(DependencyLinks):
    names = NAMES


class ProviderCompilerTempLinks(CompilerTempLinks):
    names = NAMES


class Pr166ProviderAttempt(FullGateAttempt):
    source_commit = MERGE
    source_tree = TREE
    profile_name = PROFILE
    trace_scope = PROFILE
    dependency_links = ProviderDependencyLinks
    compiler_temp_links = ProviderCompilerTempLinks

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.evidence['sourceHead'] = HEAD
        self.evidence['entryProfile'].update({
            'originalPrHeadCommit': HEAD, 'originalPrBaseCommit': BASE,
            'originalCiRun': 40497099839, 'originalRunAttempt': 1,
            'capturePackageScope': PROFILE,
            'failurePackages': list(self.trace_packages()),
            'productCleanupFixIncluded': False,
        })

    def trace_packages(self):
        return ('cjdoc', 'markdown')

    def identity(self):
        result = super().identity()
        path = Path(__file__).resolve()
        result['modules'].append({'path': str(path), 'sha256': digest(path)})
        result['candidateFiles'] += inventory(path.parents[1], [
            'scripts/pr166_provider_capture.py', 'scripts/test_pr166_provider_capture.py',
            'scripts/test_sdk_cache_identity.py',
        ])
        return result


if __name__ == '__main__':
    raise SystemExit(full_gate_main(Pr166ProviderAttempt))
