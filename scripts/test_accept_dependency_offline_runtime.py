from pathlib import Path
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

    def test_environment_does_not_inherit_sdk_proxy_or_search_paths(self):
        with patch.dict('os.environ', {'CANGJIE_HOME': '/sdk', 'LD_PRELOAD': '/sdk/evil.so',
                                     'HTTPS_PROXY': 'https://example.test', 'PATH': '/sdk/bin'}):
            environment = clean_environment(self.layout)
        self.assertEqual(environment['PATH'], '/acceptance/release-layout/empty-path')
        self.assertEqual(environment['LD_LIBRARY_PATH'], '/acceptance/release-layout/lib')
        for key in ('CANGJIE_HOME', 'HTTPS_PROXY', 'LD_PRELOAD'):
            self.assertNotIn(key, environment)


if __name__ == '__main__':
    unittest.main()
