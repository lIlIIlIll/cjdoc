import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import unittest
from unittest.mock import patch

from scripts.accept_dependency_offline_runtime import audit_trace, clean_environment


class OfflineRuntimeTraceTest(unittest.TestCase):
    layout = Path('/acceptance/release-layout')
    loader = Path('/lib64/ld-linux-x86-64.so.2')
    sdk = Path('/sdk')

    def trace(self, extra=''):
        return '\n'.join([
            '10 execve("/lib64/ld-linux-x86-64.so.2", ["loader", "render"], 0x0) = 0',
            '10 openat(AT_FDCWD, "frozen.json", O_RDONLY) = 3</acceptance/release-layout/frozen.json>',
            '10 openat(AT_FDCWD, "/acceptance/release-layout/lib/libcangjie-std-ast.so", O_RDONLY) = 3</acceptance/release-layout/lib/libcangjie-std-ast.so>',
            extra,
            '10 +++ exited with 0 +++',
        ])

    def audit(self, extra=''):
        return audit_trace(self.trace(extra), self.layout, self.loader, [self.sdk])

    def test_tracks_successful_bundled_loads_and_frozen_input(self):
        result = self.audit('10 openat(AT_FDCWD, "/usr/lib/libc.so.6", O_RDONLY) = 4</usr/lib/libc.so.6>')
        self.assertEqual(result['loadedBundledLibraries'], ['libcangjie-std-ast.so'])
        self.assertEqual(result['networkSyscalls'], 0)

    def test_rejects_installed_sdk_and_external_index_accesses_even_when_missing(self):
        for path in ['/sdk/runtime/lib/libcangjie-runtime.so', '/indexes/symbol-index.json',
                     '../symbol-index.json', '/usr/lib/symbol-index.json']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.audit('10 openat(AT_FDCWD, "' + path + '", O_RDONLY) = -1 ENOENT')

    def test_rejects_symlink_and_directory_descriptor_escape_targets(self):
        for call in [
            '10 openat(AT_FDCWD, "local-index.json", O_RDONLY) = 3</indexes/symbol-index.json>',
            '10 openat(3</indexes>, "symbol-index.json", O_RDONLY) = 4</indexes/symbol-index.json>',
            '10 openat(AT_FDCWD, "/proc/self/fd/9", O_RDONLY) = 3</indexes/symbol-index.json>',
        ]:
            with self.subTest(call=call), self.assertRaises(ValueError):
                self.audit(call)

    def test_rejects_network_and_compiler_children(self):
        for call in [
            '10 socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 4',
            '11 connect(4, {sa_family=AF_INET6}, 32) = -1 ENETUNREACH',
            '11 execve("/sdk/bin/cjc", ["cjc"], 0x0) = -1 ENOENT',
            '10 chdir("/indexes") = 0',
        ]:
            with self.subTest(call=call), self.assertRaises(ValueError):
                self.audit(call)

    def test_failed_library_probe_is_not_loaded_runtime_proof(self):
        trace = self.trace().replace('= 3</acceptance/release-layout/lib/libcangjie-std-ast.so>', '= -1 ENOENT')
        with self.assertRaisesRegex(ValueError, 'runtime DSOs'):
            audit_trace(trace, self.layout, self.loader, [self.sdk])

    def test_incomplete_trace_is_not_accepted(self):
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            audit_trace(self.trace().replace('10 +++ exited with 0 +++', ''),
                        self.layout, self.loader, [self.sdk])

    def test_allows_only_metadata_for_layout_ancestors_and_proc_aliases(self):
        self.audit('10 lstat("/acceptance", {st_mode=S_IFDIR}, 0) = 0')
        self.audit('10 readlink("/proc/self/cwd", "/acceptance/release-layout", 4096) = 26')
        with self.assertRaises(ValueError):
            self.audit('10 openat(AT_FDCWD, "/acceptance", O_RDONLY|O_DIRECTORY) = 3</acceptance>')

    def test_linux_trace_paths_are_independent_of_host_path_flavor(self):
        # This models path containers, not execution of a Linux binary on Windows.
        extra = '\n'.join([
            '10 lstat("/acceptance", {st_mode=S_IFDIR}, 0) = 0',
            '10 readlink("/proc/self/cwd", "/acceptance/release-layout", 4096) = 26',
            '10 readlink("/proc/10/exe", "/acceptance/release-layout/bin/cjdoc", 4096) = 36',
            '10 readlink("/proc/self/fd/3", "/acceptance/release-layout/frozen.json", 4096) = 38',
            '10 openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY) = 4</etc/ld.so.cache>',
            '10 openat(AT_FDCWD, "/proc/10/status", O_RDONLY) = 4</proc/10/status>',
            '10 openat(AT_FDCWD, "lib/../frozen.json", O_RDONLY) = 3</acceptance/release-layout/frozen.json>',
        ])
        for flavor in (PurePosixPath, PureWindowsPath):
            with self.subTest(flavor=flavor.__name__):
                result = audit_trace(self.trace(extra), flavor(self.layout.as_posix()),
                                     flavor(self.loader.as_posix()), [flavor(self.sdk.as_posix())])
                self.assertIn('frozen.json', result['filePaths'])
                self.assertIn('/proc/self/cwd', result['osPaths'])
                self.assertIn('/proc/<pid>/exe', result['osPaths'])
                self.assertIn('/proc/self/fd/3', result['osPaths'])
                self.assertIn('/etc/ld.so.cache', result['osPaths'])
                self.assertIn('/proc/<pid>/status', result['osPaths'])
                self.assertEqual(result['loadedBundledLibraries'], ['libcangjie-std-ast.so'])

    def test_host_path_flavor_does_not_hide_linux_escape_paths(self):
        calls = [
            '10 openat(AT_FDCWD, ' + json.dumps(path) + ', O_RDONLY) = -1 ENOENT'
            for path in (
                '/acceptance/release-layout/../symbol-index.json',
                '/acceptance/release-layout-other/symbol-index.json',
                '/ACCEPTANCE/release-layout/symbol-index.json',
                r'/acceptance\release-layout/symbol-index.json',
                '/sdk/runtime/lib/libcangjie-runtime.so',
                '/stdx/libstdx.so',
            )
        ] + [
            '10 readlink("/proc/self/cwd", "/indexes", 4096) = 8',
            '10 readlink("/proc/10/exe", "/sdk/bin/cjc", 4096) = 12',
            '10 readlink("/proc/self/fd/3", "/indexes/symbol-index.json", 4096) = 26',
            '10 openat(AT_FDCWD, "local-index.json", O_RDONLY) = 3</indexes/symbol-index.json>',
            '10 openat(3</indexes>, "symbol-index.json", O_RDONLY) = -1 ENOENT',
            '10 openat(AT_FDCWD, "/proc/self/cwd", O_RDONLY|O_DIRECTORY) = 3</acceptance/release-layout>',
        ]
        for flavor in (PurePosixPath, PureWindowsPath):
            for call in calls:
                with self.subTest(flavor=flavor.__name__, call=call), self.assertRaises(ValueError):
                    audit_trace(self.trace(call), flavor(self.layout.as_posix()),
                                flavor(self.loader.as_posix()),
                                [flavor(self.sdk.as_posix()), flavor('/stdx')])

    def test_c_escaped_paths_preserve_linux_filename_bytes(self):
        paths = [
            (r'lib/angle\76name.so', 'lib/angle>name.so'),
            (r'lib/angle\076name.so', 'lib/angle>name.so'),
            (r'lib/utf8-\303\251.so', 'lib/utf8-é.so'),
            (r'lib/hex-\xc3\xa9.so', 'lib/hex-é.so'),
            ('lib/unicode-é.so', 'lib/unicode-é.so'),
            (r'lib/quoted\"name.so', 'lib/quoted"name.so'),
            (r"lib/apostrophe\'name.so", "lib/apostrophe'name.so"),
            (r'lib/back\\slash.so', 'lib/back\\slash.so'),
            (r'lib/byte-\377.so', 'lib/byte-\udcff.so'),
        ]
        for flavor in (PurePosixPath, PureWindowsPath):
            for encoded, decoded in paths:
                call = ('10 openat(AT_FDCWD, "' + encoded + '", O_RDONLY) = 9<'
                        + self.layout.as_posix() + '/' + encoded + '>')
                with self.subTest(flavor=flavor.__name__, encoded=encoded):
                    result = audit_trace(self.trace(call), flavor(self.layout.as_posix()),
                                         flavor(self.loader.as_posix()), [PurePosixPath('/sdk')])
                    self.assertIn(decoded, result['filePaths'])
                    self.assertIn(decoded.removeprefix('lib/'), result['loadedBundledLibraries'])

    def test_c_escaped_sdk_targets_cannot_hide_under_os_library_roots(self):
        roots = [
            (r'another-sdk\76hidden', 'another-sdk>hidden'),
            (r'another-sdk\074hidden', 'another-sdk<hidden'),
            (r'another-sdk\303\251hidden', 'another-sdkéhidden'),
            (r'another-sdk\42hidden', 'another-sdk"hidden'),
            (r'another-sdk\\hidden', 'another-sdk\\hidden'),
            (r'another-sdk\x3ehidden', 'another-sdk>hidden'),
            (r'another-sdk\377hidden', 'another-sdk\udcffhidden'),
        ]
        for flavor in (PurePosixPath, PureWindowsPath):
            for encoded, decoded in roots:
                target = '/usr/lib/' + encoded + '/libboundscheck.so'
                root = PurePosixPath('/usr/lib') / decoded
                # A Linux filename's literal backslash has no lossless Windows
                # path representation; all other roots exercise both flavors.
                installed = root if '\\' in decoded else flavor(root.as_posix())
                calls = [
                    '10 openat(AT_FDCWD, "lib/alias.so", O_RDONLY) = 9<' + target + '>',
                    '10 openat(AT_FDCWD, "lib/alias.so", O_RDONLY) = 9<' + target.replace('/', r'\57', 1) + '>',
                    '10 openat(AT_FDCWD, "' + target + '", O_RDONLY) = -1 ENOENT',
                    '10 openat(9</usr/lib/' + encoded + '>, "libboundscheck.so", O_RDONLY) = -1 ENOENT',
                    '10 readlink("lib/alias.so", "' + target + '", 4096) = 64',
                ]
                for call in calls:
                    with self.subTest(flavor=flavor.__name__, call=call):
                        with self.assertRaisesRegex(ValueError, 'installed SDK/stdx'):
                            # SDK-root rejection must take precedence over OS DSOs.
                            audit_trace(self.trace(call), flavor(self.layout.as_posix()),
                                        flavor(self.loader.as_posix()),
                                        [installed])

    def test_unreadable_c_paths_fail_closed(self):
        malformed = [r'/usr/lib/bad\q.so', r'/usr/lib/bad\u002f.so',
                     r'/usr/lib/bad\xQ0.so', r'/usr/lib/bad\x0',
                     r'/usr/lib/bad\400.so', r'/usr/lib/bad\000.so']
        calls = []
        for path in malformed:
            calls.extend([
                '10 openat(AT_FDCWD, "' + path + '", O_RDONLY) = -1 ENOENT',
                '10 openat(AT_FDCWD, "lib/alias.so", O_RDONLY) = 9<' + path + '>',
            ])
        calls.extend([
            '10 openat(AT_FDCWD, "/usr/lib/libc.so.6"... , O_RDONLY) = -1 ENOENT',
            '10 openat(AT_FDCWD, "lib/alias.so", O_RDONLY) = 9</usr/lib/libc.so...>',
            '10 openat(AT_FDCWD, "/usr/lib/libc.so.6',
            '10 openat(AT_FDCWD, "lib/alias.so", O_RDONLY) = 9</usr/lib/libc.so.6',
            '10 openat(AT_FDCWD, "/usr/lib/bad' + '\\',
            '10 openat(AT_FDCWD, "lib/alias.so", O_RDONLY) = 9</usr/lib/bad' + '\\',
            r'10 openat(AT_FDCWD, "lib/alias.so", O_RDONLY) = 9<\qusr/lib/libc.so.6>',
        ])
        for flavor in (PurePosixPath, PureWindowsPath):
            for call in calls:
                with self.subTest(flavor=flavor.__name__, call=call):
                    with self.assertRaisesRegex(ValueError, 'strace'):
                        audit_trace(self.trace(call), flavor(self.layout.as_posix()),
                                    flavor(self.loader.as_posix()), [PurePosixPath('/sdk')])

    def test_environment_does_not_inherit_sdk_proxy_or_search_paths(self):
        inherited = {
            'CANGJIE_HOME': '/inherited-sdk',
            'LD_PRELOAD': '/inherited-sdk/evil.so',
            'HTTPS_PROXY': 'https://proxy.example.test',
            'http_proxy': 'http://proxy.example.test',
            'ALL_PROXY': 'http://proxy.example.test',
            'PATH': '/inherited-sdk/bin',
            'LD_LIBRARY_PATH': '/inherited-sdk/runtime/lib',
            'LIBRARY_PATH': '/inherited-sdk/lib',
            'CPATH': '/inherited-sdk/include',
            'PYTHONPATH': '/inherited-sdk/python',
            'HOME': '/inherited-sdk/home',
            'TMPDIR': '/inherited-sdk/tmp',
            'TMP': '/inherited-sdk/tmp',
            'TEMP': '/inherited-sdk/tmp',
        }
        with patch.dict('os.environ', inherited):
            environment = clean_environment(self.layout)
        for key in ('CANGJIE_HOME', 'HTTPS_PROXY', 'http_proxy', 'ALL_PROXY', 'LD_PRELOAD',
                    'LIBRARY_PATH', 'CPATH', 'PYTHONPATH'):
            self.assertNotIn(key, environment)
        for value in environment.values():
            self.assertNotIn('/inherited-sdk', value)
            self.assertNotIn('proxy.example.test', value)


if __name__ == '__main__':
    unittest.main()
