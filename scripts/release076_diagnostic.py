#!/usr/bin/env python3
"""Bounded diagnosis of the failed 0.7.6 release; never release qualification."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import shutil
import shlex
import subprocess
import sys
import tarfile
import textwrap

COMMIT = '653457d1aa46ef2939cd10e130d7e1b16fd5d999'
TREE = '06f7d27491f8952b1df63163dca292d8cb8378d5'
LIBRARY_COMMIT = 'a1ef6e5db0f9214a990627b008e13ef06f6eb485'
BINARY_SHA = 'e6bc2e2529ede407d1b0a9ed00a3c8ef2c51d416270082474e3417852b65c377'
TAR_SHA = '870d223181b936bc47b966fcf4a62ee33f04678faa04fd7afe9de9b583f8e38a'
TAR_SIZE = 25825280
WORKFLOW_SHA = '4d4b323bfb3a32bdff21ec5a359f651ccb06cd31554eefd46d46ba360af863c1'
CHECK_SHA = 'b5aebb06c4b9b6ca4dd7b5c003cec8dc53c147b081b8fb7120924efe0b33d06f'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def release_stage(source):
    """Replay the committed original Windows shell, including its preconditions."""
    path = source / '.github/workflows/release.yml'
    if sha(path) != WORKFLOW_SHA:
        raise ValueError('original release workflow identity differs')
    body = path.read_text().split('      - name: Run the platform acceptance gates\n', 1)[1]
    body = body.split('      - name:', 1)[0].split('        run: |\n', 1)[1]
    script = textwrap.dedent(body).replace('${{ matrix.platform }}', 'windows-x64')
    if '${{' in script or script.count('bash scripts/check.sh') != 1:
        raise ValueError('unrecognized original target script')
    return script


def extract_candidate(tar_path, marker_path, source):
    """Authenticate the exact successful main artifact before exposing executables."""
    marker = json.loads(marker_path.read_text())
    expected = {'commit': COMMIT, 'tree': TREE, 'runId': 40536370055, 'runAttempt': 1,
                'repository': 'lIlIIlIll/cjdoc', 'candidateTarSha256': TAR_SHA,
                'candidateTarSize': TAR_SIZE,
                'schemaVersion': 'cjdoc.linux-candidate-ready/1',
                'artifactName': 'cjdoc-linux-candidate-40536370055-1'}
    if any(marker.get(k) != value for k, value in expected.items()):
        raise ValueError('candidate marker identity differs')
    if tar_path.stat().st_size != expected['candidateTarSize'] or sha(tar_path) != TAR_SHA:
        raise ValueError('candidate tar identity differs')
    if (source / 'target').exists() or (source / 'target').is_symlink():
        raise ValueError('candidate output already exists')
    names = {'target/release/bin/main', 'target/release/bin/chir-worker-main',
             'target/ci-build/build-manifest.json'}
    with tarfile.open(tar_path) as archive:
        members = archive.getmembers()
        if {m.name for m in members} != names or len(members) != 3 or not all(m.isfile() for m in members):
            raise ValueError('unexpected candidate members')
        if sha_bytes(archive.extractfile('target/release/bin/main').read()) != BINARY_SHA:
            raise ValueError('candidate executable identity differs')
        manifest = json.load(archive.extractfile('target/ci-build/build-manifest.json'))
        if (manifest['checkoutCommit'], manifest['checkoutTree'], manifest['mainBinary']['sha256']) != (COMMIT, TREE, BINARY_SHA):
            raise ValueError('candidate build manifest differs')
        archive.extractall(source, filter='data')
    return manifest


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def configure_library(path):
    root = path.resolve(strict=True)
    actual = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD']).decode().strip()
    if actual != LIBRARY_COMMIT:
        raise ValueError('diagnostic library commit differs')
    sys.path.insert(0, str(root / 'scripts'))
    return root


def windows_attempt_class():
    from full_gate_codegen_capture import FullGateAttempt
    from native_capture_support import inventory

    class Release076Windows(FullGateAttempt):
        source_commit = COMMIT
        source_tree = TREE
        profile_name = 'release076-windows'

        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.environment.update(CJDOC_RELEASE_TAG='v0.7.6', CJDOC_RELEASE_COMMIT=COMMIT)
            self.evidence['entryProfile'].update(originalReleaseRun=40546453166,
                originalRunAttempt=1, originalReleaseTag='v0.7.6',
                originalWorkflowSha256=WORKFLOW_SHA,
                scope='Original Windows release acceptance shell once; passive IR observer is a difference')
            self.mappings.append((Path(__file__).resolve().parents[1], '<release-controller>'))

        def stage_script(self):
            return release_stage(self.source)

        def identity(self):
            result = super().identity()
            result['modules'].append({'path': str(Path(__file__).resolve()), 'sha256': sha(__file__)})
            result['candidateFiles'] += inventory(Path(__file__).resolve().parents[1], [
                'scripts/release076_diagnostic.py', 'scripts/test_release076_diagnostic.py',
                '.github/workflows/release076-evidence.yml'])
            return result

        def target(self):
            super().target()
            # Do not publish IR in this diagnostic; the original backend input and
            # conditional trace stay private. Safe receipt/log publication is unchanged.
            self.disassemblies = []
            self.evidence['derivedIrPublication'] = {'status': 'PRIVATE_ONLY'}

    return Release076Windows


def runtime_crash(result, source, binary, private):
    output = result.stdout + result.stderr
    if result.returncode == 0 or b'"exitCode": -11' not in output:
        return False
    candidates = []
    for line in output.decode('utf-8', 'replace').splitlines():
        if ': error: command failed (245): ' not in line:
            continue
        fields = shlex.split(line.split(': error: command failed (245): ', 1)[1])
        prefix = [sys.executable, str(source / 'scripts/measure_command.py'), str(binary),
                  'generate', '--project', str(source), '--format', 'json', '--output']
        if fields[:len(prefix)] != prefix or fields[len(prefix) + 1:] != ['--jobs', '1', '--no-cache']:
            continue
        destination = Path(fields[len(prefix)])
        if (destination.name == 'run-00-cold' and destination.parent.name == 'self'
                and destination.parent.parent.name.startswith('performance-')
                and destination.parent.parent.parent == private):
            candidates.append(destination)
    return len(candidates) == 1


def run_bounded(argv, source, environment, seconds, cpu=None):
    prepare = None if cpu is None else lambda: os.sched_setaffinity(0, {cpu})
    child = None
    pending = []
    previous = {}

    def cancel(signum, _frame):
        if child is None:
            pending.append(signum)
            return
        terminate_session(child.pid)
        child.wait()
        raise SystemExit(128 + signum)

    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous[signum] = signal.signal(signum, cancel)
        child = subprocess.Popen(argv, cwd=source, env=environment, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True, preexec_fn=prepare)
        if pending:
            cancel(pending[0], None)
        try:
            stdout, stderr = child.communicate(timeout=seconds)
            return subprocess.CompletedProcess(argv, child.returncode, stdout, stderr), False
        except subprocess.TimeoutExpired:
            terminate_session(child.pid)
            stdout, stderr = child.communicate()
            return subprocess.CompletedProcess(argv, 124, stdout, stderr), True
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def terminate_session(session):
    """Also stop debugger inferiors that use another group in this owned session."""
    handles = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            descriptor = os.pidfd_open(int(entry.name))
        except (ProcessLookupError, PermissionError):
            continue
        try:
            fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            if int(fields[3]) == session:
                handles.append(descriptor)
                descriptor = None
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
        finally:
            if descriptor is not None:
                os.close(descriptor)
    for descriptor in handles:
        try:
            signal.pidfd_send_signal(descriptor, signal.SIGKILL)
        except ProcessLookupError:
            pass
        finally:
            os.close(descriptor)
    try:
        os.killpg(session, signal.SIGKILL)
    except ProcessLookupError:
        pass


def linux_attempt(args, library):
    import resource
    from ir_publication import publish
    from native_capture_support import GitEvidence, controller_identity, digest, system_mappings

    source = args.source.resolve(strict=True)
    output = args.output
    output.mkdir(mode=0o700)
    private = output / 'private'
    private.mkdir(mode=0o700)
    environment = os.environ.copy()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    mappings = system_mappings(environment) + [(source, '<source>'), (output, '<diagnostic>'),
        (library, '<frozen-library>'), (Path(__file__).resolve().parents[1], '<release-controller>'),
        (Path.home(), '<home>'), (Path(sys.executable).resolve().parent, '<python>'),
        (Path(environment['RUNNER_TEMP']), '<temporary>')]
    evidence = {'schemaVersion': 'cjdoc.release076-runtime-diagnostic/1', 'diagnosticOnly': True,
        'sourceCommit': COMMIT, 'sourceTree': TREE, 'originalReleaseRun': 40546453166,
        'targetInvocations': 0, 'gdbInvocations': 0, 'qualification': False,
        'rawBitcodePublished': False, 'originalReleaseBinarySha256': BINARY_SHA,
        'differences': ['Accepted identical binary reused without preceding build/unit/CLI/smoke stages.',
                        'Diagnostic parent process; conditional debugger observes a separate invocation.',
                        'Core dumps disabled; original stack and heap limits unchanged.'],
        'workflow': {k: environment.get(k) for k in ('GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')},
        'observedStackBytes': list(resource.getrlimit(resource.RLIMIT_STACK)),
        'heap': environment.get('cjHeapSize'), 'affinity': sorted(os.sched_getaffinity(0))}
    original_code = 2
    log = ''
    git = GitEvidence(subprocess.run, environment)
    before = None
    modules = [Path(__file__), library / 'scripts/ir_publication.py',
               library / 'scripts/native_capture_support.py']
    try:
        if environment.get('cjHeapSize') != '512MB':
            raise ValueError('original heap differs')
        if (environment.get('CJDOC_TOOLCHAIN_FINGERPRINT') != '282c2bc7d0ba20d500d6930649c5a672c173c0b0ce1f76c8f4d8d0a7866aec0a'
                or environment.get('CJDOC_STDX_DIGEST') != 'e62289d5b88af440de04a26a30c79403d024f6accfacfd96607ae409ad9c1df2'):
            raise ValueError('original Linux SDK/stdx identity differs')
        evidence['controllerBefore'] = controller_identity(modules, environment)
        evidence['releaseControllerSha256'] = sha(__file__)
        before = git.snapshot(source, COMMIT, TREE)
        evidence['sourceBefore'] = before
        if sha(source / 'scripts/release_check.sh') != CHECK_SHA:
            raise ValueError('original release gate identity differs')
        manifest = extract_candidate(args.candidate, args.marker, source)
        evidence['buildManifest'] = manifest
        sdk = Path(environment['CANGJIE_SDK_ROOT']).resolve(strict=True)
        runtime = sdk / 'runtime/lib/linux_x86_64_cjnative/libcangjie-runtime.so'
        evidence['runtimeBefore'] = {'sha256': digest(runtime), 'size': runtime.stat().st_size}
        binary = source / 'target/release/bin/main'
        argv = [sys.executable, 'scripts/perf_gate.py', 'check', '--binary', str(binary),
            '--baseline', 'tests/perf/baseline.json', '--evidence', str(private / 'performance.json')]
        evidence['targetCommand'] = argv
        (output / 'target-attempt.marker').open('x').close()
        evidence['targetInvocations'] = 1
        result, timed_out = run_bounded(argv, source, environment, 1800)
        evidence['targetTimedOut'] = timed_out
        original_code = result.returncode
        evidence['processExitCode'] = original_code
        log = (result.stdout + result.stderr).decode('utf-8', 'replace')
        (private / 'target.stdout').write_bytes(result.stdout)
        (private / 'target.stderr').write_bytes(result.stderr)
        evidence['targetStdoutSha256'] = sha_bytes(result.stdout)
        evidence['targetStderrSha256'] = sha_bytes(result.stderr)
        if runtime_crash(result, source, binary, private):
            gdb = Path(shutil.which('gdb') or '').resolve(strict=True)
            if not gdb.is_file():
                raise ValueError('conditional debugger unavailable')
            command = [str(gdb), '--batch', '--nx', '--nh', '--return-child-result',
                '-ex', 'set startup-with-shell off', '-ex', 'set pagination off',
                '-ex', 'handle SIGSEGV stop print nopass', '-ex', 'run',
                '-ex', 'p $_siginfo', '-ex', 'thread apply all bt 16', '--args', str(binary),
                'generate', '--project', str(source), '--format', 'json',
                '--output', str(private / 'gdb-self-cold'), '--jobs', '1', '--no-cache']
            evidence['gdbCommand'] = command
            evidence['gdbSha256'] = sha(gdb)
            evidence['gdbInvocations'] = 1
            (output / 'gdb-attempt.marker').open('x').close()
            cpu = min(os.sched_getaffinity(0))
            traced, timed_out = run_bounded(command, source, environment, 600, cpu)
            evidence['gdbExitCode'] = traced.returncode
            evidence['gdbTimedOut'] = timed_out
            trace = traced.stdout + traced.stderr
            (private / 'gdb.log').write_bytes(trace)
            log += '\nCONDITIONAL DEBUGGER (not original target):\n' + trace.decode('utf-8', 'replace')
        evidence['runtimeAfter'] = {'sha256': digest(runtime), 'size': runtime.stat().st_size}
        if evidence['runtimeBefore'] != evidence['runtimeAfter'] or sha(binary) != BINARY_SHA:
            raise ValueError('runtime or binary changed')
    except Exception as error:
        evidence['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            if before is not None:
                evidence['sourceAfter'] = git.snapshot(source, COMMIT, TREE)
                if evidence['sourceAfter'] != before:
                    raise ValueError('source changed')
            evidence['controllerAfter'] = controller_identity(modules, environment)
            if evidence.get('controllerBefore') != evidence['controllerAfter'] or sha(__file__) != evidence.get('releaseControllerSha256'):
                raise ValueError('controller changed')
        except Exception as error:
            evidence['integrityError'] = type(error).__name__ + ': ' + str(error)
        code = original_code if original_code else (2 if 'error' in evidence or 'integrityError' in evidence else 0)
        evidence['controllerExitCode'] = code
        (private / 'receipt.raw.json').write_text(json.dumps(evidence, indent=2) + '\n')
        try:
            publish(output / 'public', evidence, log, [], mappings, environment)
        except Exception as error:
            evidence['publicationErrorSha256'] = sha_bytes(str(error).encode())
            (private / 'receipt.raw.json').write_text(json.dumps(evidence, indent=2) + '\n')
            code = code or 2
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('windows-x64', 'linux-x64'), required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--marker', type=Path)
    args = parser.parse_args()
    if os.environ.get('GITHUB_RUN_ATTEMPT') != '1':
        parser.error('only the first workflow attempt may execute targets')
    if args.output.exists() or args.output.is_symlink():
        parser.error('output exists; no retry')
    try:
        library = configure_library(args.library)
    except Exception:
        print('Diagnostic library verification failed; private details withheld.', file=sys.stderr)
        return 2
    if args.platform == 'linux-x64':
        if sys.platform != 'linux' or platform.machine() != 'x86_64' or not args.candidate or not args.marker:
            parser.error('native Linux artifact inputs required')
        return linux_attempt(args, library)
    if os.name != 'nt' or platform.machine().lower() not in {'amd64', 'x86_64'}:
        parser.error('native Windows required')
    from pipeline_codegen_capture import entry_failure
    prepared = False
    attempt = None
    try:
        args.output.mkdir(mode=0o700)
        prepared = True
        attempt = windows_attempt_class()(args.source, args.output, args.platform)
        return attempt.execute()
    except Exception as error:
        original = attempt.evidence.get('processExitCode') if attempt else None
        code = original if type(original) is int and original != 0 else 2
        return entry_failure(args.output if prepared else None, error, code, attempt)


if __name__ == '__main__':
    raise SystemExit(main())
