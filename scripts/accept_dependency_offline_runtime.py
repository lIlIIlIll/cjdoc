#!/usr/bin/env python3
"""Accept frozen DocIR rendering with a private Linux runtime sidecar, not an SDK.

Setup reads --sdk/--stdx only to copy the ELF dependency closure. Rendering uses
an immutable release-packaged executable, copied DSOs and frozen JSON, an empty
PATH and fresh HOME. strace audits all descendants' file/network/process calls.
This is an acceptance layout, NOT a claim that current release assets bundle
these libraries. The host ELF loader, libc and other OS libraries remain needed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import subprocess
import sys
import tomllib

sys.dont_write_bytecode = True

try:
    from .package_standalone import hash_file, package
    from .safe_output_root import lexical_absolute, safe_regular_file, verify_directory_chain
except ImportError:
    from package_standalone import hash_file, package
    from safe_output_root import lexical_absolute, safe_regular_file, verify_directory_chain


NEEDED = re.compile(r'\(NEEDED\).*\[([^\]]+)\]')
CALL = re.compile(r'(\w+)\(')
NETWORK_CALLS = {'socket', 'socketpair', 'connect', 'bind', 'listen', 'accept',
                 'accept4', 'sendto', 'recvfrom', 'sendmsg', 'recvmsg',
                 'sendmmsg', 'recvmmsg', 'getsockname', 'getpeername',
                 'setsockopt', 'getsockopt', 'shutdown'}
OS_LIBRARY_ROOTS = tuple(PurePosixPath(p) for p in ('/lib', '/lib64', '/usr/lib', '/usr/lib64'))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def clean_environment(layout):
    return {'PATH': str(layout / 'empty-path'), 'HOME': str(layout / 'home'),
            'TMPDIR': str(layout / 'tmp'), 'TMP': str(layout / 'tmp'),
            'TEMP': str(layout / 'tmp'), 'LANG': 'C', 'LC_ALL': 'C',
            'TZ': 'UTC', 'LD_LIBRARY_PATH': str(layout / 'lib')}


def redact(text, locations):
    for source, replacement in sorted(locations.items(), key=lambda item: -len(item[0])):
        text = text.replace(source, replacement)
    return text


def run(command, cwd, environment, timeout=120):
    result = subprocess.run([str(part) for part in command], cwd=cwd, env=environment,
                            capture_output=True, text=True, timeout=timeout)
    require(result.returncode == 0, 'subprocess failed (exit %d)' % result.returncode)
    return result.stdout


def elf_dependencies(readelf, path, cwd, environment):
    dynamic = run([readelf, '-d', path], cwd, environment)
    # Absolute DT_NEEDED paths bypass the sidecar search and are never portable.
    dependencies = NEEDED.findall(dynamic)
    require(all('/' not in name for name in dependencies), 'absolute ELF dependency')
    return dependencies


def interpreter(readelf, binary, cwd, environment):
    program = run([readelf, '-l', binary], cwd, environment)
    match = re.search(r'Requesting program interpreter:\s*([^\]]+)', program)
    require(match is not None, 'Linux dynamically linked ELF executable required')
    loader = Path(match.group(1).strip())
    require(loader.is_file() and any(loader.is_relative_to(root) for root in OS_LIBRARY_ROOTS),
            'ELF interpreter must be a host OS loader')
    return loader


def library_candidates(sdk, stdx):
    candidates = {}
    # Prefer runtime DSOs over SDK link-time variants (e.g. libboundscheck).
    roots = [sdk / 'runtime/lib', sdk / 'lib']
    if stdx is not None:
        roots.append(stdx)
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob('*.so*')):
            if path.is_file():
                resolved = path.resolve(strict=True)
                require(resolved.is_relative_to(sdk) or
                        (stdx is not None and resolved.is_relative_to(stdx)),
                        'runtime library symlink escapes supplied roots')
                candidates.setdefault(path.name, path)
    return candidates


def bundle_libraries(readelf, binary, sdk, stdx, layout, environment):
    candidates = library_candidates(sdk, stdx)
    pending = elf_dependencies(readelf, binary, layout, environment)
    visited = set()
    bundled = {}
    os_dependencies = set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        source = candidates.get(name)
        if source is None:
            require(not name.startswith(('libcangjie', 'libstdx', 'libboundscheck')),
                    'required Cangjie runtime library missing: ' + name)
            os_dependencies.add(name)
            continue
        destination = layout / 'lib' / name
        shutil.copyfile(source, destination)
        destination.chmod(0o444)
        bundled[name] = {'sha256': hash_file(destination), 'size': destination.stat().st_size}
        pending.extend(elf_dependencies(readelf, destination, layout, environment))
    return dict(sorted(bundled.items())), sorted(os_dependencies)


def os_access(path):
    if any(path.is_relative_to(root) for root in OS_LIBRARY_ROOTS):
        # Only OS DSOs and loader search directories, never another SDK/index.
        return not path.name.startswith(('libcangjie', 'libstdx')) and ('.so' in path.name or not path.suffix)
    if path in (PurePosixPath('/etc/ld.so.cache'), PurePosixPath('/etc/ld.so.preload'),
                PurePosixPath('/etc/localtime'), PurePosixPath('/dev/null'), PurePosixPath('/dev/urandom'),
                PurePosixPath('/dev/random'), PurePosixPath('/proc/meminfo'), PurePosixPath('/proc/cpuinfo'),
                PurePosixPath('/proc/stat'), PurePosixPath('/usr/share/zoneinfo/UTC')):
        return True
    if path.is_relative_to('/sys/devices/system/cpu'):
        return True
    return bool(re.fullmatch(r'/proc/(?:self|\d+)/(?:maps|stat|status|cmdline|task(?:/\d+(?:/comm)?)?)', str(path)))


def decode_trace_path(encoded):
    # strace prints C-escaped bytes, not Python literals or Unicode escapes.
    data = bytearray()
    escapes = {'a': 7, 'b': 8, 't': 9, 'n': 10, 'v': 11, 'f': 12,
               'r': 13, '\\': 92, '"': 34, "'": 39, '?': 63}
    index = 0
    while index < len(encoded):
        character = encoded[index]
        index += 1
        if character != '\\':
            data.extend(character.encode('utf-8', errors='surrogateescape'))
            continue
        require(index < len(encoded), 'incomplete strace path escape')
        character = encoded[index]
        index += 1
        if character in escapes:
            data.append(escapes[character])
        elif character in '01234567':
            digits = character
            while index < len(encoded) and len(digits) < 3 and encoded[index] in '01234567':
                digits += encoded[index]
                index += 1
            value = int(digits, 8)
            require(value <= 255, 'invalid strace octal byte')
            data.append(value)
        elif character == 'x':
            digits = encoded[index:index + 2]
            require(len(digits) == 2 and all(digit in '0123456789abcdefABCDEF' for digit in digits),
                    'invalid strace hex byte')
            data.append(int(digits, 16))
            index += 2
        else:
            raise ValueError('unknown strace path escape')
    require(0 not in data, 'NUL in strace path')
    return data.decode('utf-8', errors='surrogateescape')


def trace_path_values(line):
    quoted, descriptors = [], []
    index = 0
    while index < len(line):
        descriptor = line.startswith(('</', '<\\'), index)
        if line[index] != '"' and not descriptor:
            index += 1
            continue
        closer = '>' if descriptor else '"'
        index += 1
        start = index
        while index < len(line) and line[index] != closer:
            index += 2 if line[index] == '\\' else 1
        require(index < len(line), 'unterminated strace path')
        encoded = line[start:index]
        index += 1
        require(not line.startswith('...', index) and not (descriptor and encoded.endswith('...')),
                'truncated strace path')
        decoded = decode_trace_path(encoded)
        require(not descriptor or decoded.startswith('/'), 'non-absolute strace descriptor path')
        (descriptors if descriptor else quoted).append(decoded)
    return quoted, descriptors


def audit_trace(text, layout, loader, installed_roots):
    # These are Linux trace paths, even when the auditor is tested on Windows.
    # Keep host filesystem operations in accept(), not in trace interpretation.
    layout = PurePosixPath(layout.as_posix())
    loader = PurePosixPath(loader.as_posix())
    installed_roots = [PurePosixPath(root.as_posix()) for root in installed_roots]
    files = set()
    system = set()
    opened = set()
    executables = []
    calls = 0
    saw_exit = False
    for line in text.splitlines():
        if '+++ exited with 0 +++' in line:
            saw_exit = True
        match = CALL.search(line)
        if match is None:
            continue
        name = match.group(1)
        calls += 1
        require(name not in NETWORK_CALLS, 'network syscall observed: ' + name)
        require(name not in ('chdir', 'fchdir', 'chroot', 'pivot_root', 'execveat'),
                'unexpected process/path redirection: ' + name)
        tokens, descriptors = trace_path_values(line)
        if name == 'execve':
            require(tokens, 'unreadable execve trace')
            executable = PurePosixPath(tokens[0])
            require(executable in (loader, layout / 'bin/cjdoc'),
                    'unexpected child executable')
            executables.append(str(executable))
            # execve arguments include text, not file-access operands.
            tokens = tokens[:1]
        # -yy annotations expose actual descriptor targets, including symlinks
        # and non-AT_FDCWD directory descriptors used by relative *at calls.
        tokens.extend(descriptors)
        for value in tokens:
            if not value:
                continue
            # File calls' quoted strings are path operands; status/clone strings
            # are harmless non-path flags and are not classified as files.
            path = PurePosixPath(posixpath.normpath(value if value.startswith('/') else str(layout / value)))
            require(not any(path.is_relative_to(root) for root in installed_roots),
                    'installed SDK/stdx access observed')
            if path.is_relative_to(layout):
                files.add(path.relative_to(layout).as_posix())
                if name in ('open', 'openat', 'openat2') and re.search(r'= \d+(?:<|$)', line):
                    opened.add(path.relative_to(layout).as_posix())
            else:
                metadata_only = name in ('stat', 'lstat', 'newfstatat', 'statx', 'readlink', 'readlinkat')
                ancestor = metadata_only and path in layout.parents
                proc_link = name in ('readlink', 'readlinkat') and bool(re.fullmatch(
                    r'/proc/(?:self|\d+)/(?:cwd|exe|fd/\d+)', str(path)))
                require(os_access(path) or ancestor or proc_link,
                        'file access outside private layout/OS allowlist')
                label = ('<layout-ancestor:%d>' % list(layout.parents).index(path) if ancestor
                         else re.sub(r'/proc/\d+/', '/proc/<pid>/', str(path)))
                system.add(label)
    require(calls > 0 and saw_exit and executables, 'incomplete syscall trace')
    require('frozen.json' in opened, 'trace does not prove frozen DocIR was read')
    loaded = sorted(name.removeprefix('lib/') for name in opened if name.startswith('lib/'))
    require(loaded, 'trace does not prove bundled runtime DSOs were loaded')
    return {'syscallCount': calls, 'filePaths': sorted(files),
            'osPaths': sorted(system), 'networkSyscalls': 0,
            'installedSdkOrStdxAccesses': 0, 'externalFileAccesses': 0,
            'executables': executables, 'loadedBundledLibraries': loaded}


def frozen_urls(value):
    urls = set()
    if isinstance(value, dict):
        for key, item in value.items():
            if key == 'url' and isinstance(item, str) and item:
                urls.add(item)
            else:
                urls.update(frozen_urls(item))
    elif isinstance(value, list):
        for item in value:
            urls.update(frozen_urls(item))
    return urls


def compare_renders(first, second, document):
    snapshots = []
    for root in (first, second):
        snapshots.append({path.relative_to(root).as_posix(): hash_file(path)
                          for directory in ('html', 'markdown')
                          for path in sorted((root / directory).rglob('*')) if path.is_file()})
    require(snapshots[0] and snapshots[0] == snapshots[1], 'render is not byte reproducible')
    require((first / 'html/index.html').is_file() and (first / 'markdown/index.md').is_file(),
            'HTML/Markdown output missing')
    # Frozen structured navigation survives JSON replay without catalog reads.
    replay = json.loads((first / 'docs.json').read_text(encoding='utf-8'))
    require(replay == document, 'frozen DocIR changed during replay')
    return {'fileCount': len(snapshots[0]), 'files': snapshots[0],
            'frozenNavigationUrlCount': len(frozen_urls(document))}


def accept(args):
    require(sys.platform.startswith('linux'), 'syscall portability acceptance requires Linux')
    repo = Path(__file__).resolve().parent.parent
    binary = safe_regular_file(args.binary, description='cjdoc executable')
    frozen = safe_regular_file(args.input, description='frozen DocIR')
    sdk = verify_directory_chain(lexical_absolute(args.sdk))
    stdx = verify_directory_chain(lexical_absolute(args.stdx)) if args.stdx else None
    output = lexical_absolute(args.output)
    verify_directory_chain(output.parent, create=True)
    require(not output.exists() and not output.is_symlink(), '--output must be a new private directory')
    output.mkdir(mode=0o700)
    layout = output / 'release-layout'
    layout.mkdir()
    for name in ('lib', 'bin', 'empty-path', 'home', 'tmp'):
        (layout / name).mkdir()
    evidence = output / 'evidence'
    evidence.mkdir()
    locations = {str(output): '<acceptance>', str(repo): '<repo>', str(sdk): '<sdk>',
                 str(Path.home()): '$HOME'}
    if stdx:
        locations[str(stdx)] = '<stdx>'
    environment = clean_environment(layout)
    readelf = shutil.which('readelf', path='/usr/bin:/bin')
    strace = shutil.which('strace', path='/usr/bin:/bin')
    require(readelf is not None, 'readelf is required for dependency closure')
    require(strace is not None, 'strace is required; environment clearing alone is not proof')
    version = tomllib.loads((repo / 'cjpm.toml').read_text(encoding='utf-8'))['package']['version']
    asset, checksum = package(binary, output / 'release-asset', 'linux-x64', version)
    executable = layout / 'bin/cjdoc'
    shutil.copyfile(asset, executable)
    executable.chmod(0o555)
    shutil.copyfile(frozen, layout / 'frozen.json')
    (layout / 'frozen.json').chmod(0o444)
    document = json.loads((layout / 'frozen.json').read_text(encoding='utf-8'))
    loader = interpreter(readelf, executable, layout, environment)
    libraries, system_libraries = bundle_libraries(readelf, executable, sdk, stdx, layout, environment)
    # Ask the OS loader to ignore its resolution cache. Some host loaders still
    # inspect cache metadata; trace actual DSO loads rather than claiming none.
    prefix = [loader, '--inhibit-cache', '--library-path', layout / 'lib', executable]
    listing = run([loader, '--inhibit-cache', '--library-path', layout / 'lib', '--list', executable],
                  layout, environment)
    (evidence / 'loader-dependencies.txt').write_text(redact(listing, locations), encoding='utf-8')
    roots = [sdk] + ([stdx] if stdx else [])
    traces = []
    for number in (1, 2):
        destination = layout / ('render-' + str(number))
        trace = evidence / ('render-' + str(number) + '.strace')
        command = [strace, '-f', '-q', '-yy', '-s', '65535', '-o', trace,
                   '-e', 'trace=%file,%network,%process', *prefix,
                   'render', '--input', layout / 'frozen.json', '--output', destination,
                   '--format', 'html', '--format', 'markdown', '--format', 'json']
        result = subprocess.run([str(part) for part in command], cwd=layout, env=environment,
                                capture_output=True, text=True, timeout=args.timeout)
        log = result.stdout + result.stderr
        (evidence / ('render-' + str(number) + '.log')).write_text(redact(log, locations), encoding='utf-8')
        raw = trace.read_text(encoding='utf-8')
        trace.write_text(redact(raw, locations), encoding='utf-8')
        require(result.returncode == 0, 'render failed; see sanitized render log')
        audit = audit_trace(raw, layout, loader, roots)
        require(set(libraries) <= set(audit['loadedBundledLibraries']),
                'not every bundled DSO was loaded from the private layout')
        audit['executables'] = [redact(item, locations) for item in audit['executables']]
        traces.append(audit)
    proof = compare_renders(layout / 'render-1', layout / 'render-2', document)
    summary = {'schemaVersion': 'cjdoc.offline-runtime-acceptance/1', 'state': 'passed',
               'layoutKind': 'private-acceptance-sidecar-not-current-release-asset',
               'binarySha256': hash_file(executable), 'inputSha256': hash_file(layout / 'frozen.json'),
               'packaging': 'package_standalone.package', 'bundledRuntimeLibraries': libraries,
               'hostOsLibraryDependencies': system_libraries,
               'hostOsInterpreter': str(loader), 'requiresInstalledSdkDuringRender': False,
               'compilerOrSdkExecutablesDuringRender': 0, 'externalIndexReadsDuringRender': 0,
               'traceCoverage': 'strace -f: file, network, process; successful and failed accesses',
               'environmentKeys': sorted(environment), 'pathContainsExecutables': False,
               'sharedSdkMovedOrModified': False, 'render': proof, 'traces': traces,
               'limits': ['Linux host OS loader/libraries, kernel, proc/sys CPU and memory introspection remain required.',
                          'No cross-host ABI compatibility claim; current release package still declares SDK-required.',
                          'Tracing proves observed accesses; it is not a network/filesystem sandbox.']}
    (evidence / 'acceptance.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print('PASS: two byte-identical frozen renders; bundled runtime; traced zero installed SDK/index accesses and network syscalls')
    print('Current release assets are unchanged and still SDK-required; host OS runtime remains required.')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, required=True, help='read-only setup source for runtime DSOs only')
    parser.add_argument('--stdx', type=Path, help='optional sibling stdx DSO source; never inferred inside SDK')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args()
    try:
        return accept(args)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Detailed local command output is intentionally not pasted into errors.
        detail = str(error) if isinstance(error, ValueError) else type(error).__name__
        print('FAIL: ' + detail, file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
