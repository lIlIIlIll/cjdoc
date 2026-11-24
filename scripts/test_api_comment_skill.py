"""Contracts for the offline API comment skill."""

import contextlib
import io
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest

from scripts.sync_api_comment_skill import REFERENCE, ROOT, SOURCES, extract_blocks

SYNC = Path('scripts/sync_api_comment_skill.py')

PREVIEW = ROOT / REFERENCE.parents[1] / 'scripts/preview.py'

class SyncApiCommentSkillTest(unittest.TestCase):
    def test_repository_reference_is_current(self):
        result = subprocess.run([sys.executable, ROOT / SYNC, '--check'], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_output_whitespace_drift_does_not_rewrite_the_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (*SOURCES, SYNC, REFERENCE):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, destination)
            reference = root / REFERENCE
            original = reference.read_bytes()
            readme = root / 'README.md'
            readme.write_bytes(readme.read_bytes().replace(b'* Hello, !', b'* Hello, ! ', 1))

            result = subprocess.run([sys.executable, root / SYNC, '--check'], capture_output=True)
            self.assertEqual(result.returncode, 1, result.stderr.decode())
            self.assertEqual(reference.read_bytes(), original)
            subprocess.run([sys.executable, root / SYNC], check=True)
            self.assertEqual(reference.read_bytes(), original.replace(b'* Hello, !', b'* Hello, ! ', 1))

    def test_fences_preserve_content_and_only_matching_markers_close(self):
        block = (
            '  ~~~~text\r\n'
            '### Selected\r\n'
            '  ~~~\r\n'
            '```cangjie\r\n'
            '  println("Hello")\r\n'
            '```\r\n'
            '```output\r\n'
            'Hello  \r\n'
            '```\r\n'
            '  ~~~~~\t\r\n'
        )
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'guide.md'
            source.write_bytes(('## Selected\r\n\r\n' + block + '\r\n~~~text\r\nsecond\r\n~~~\r\n').encode())
            self.assertEqual(extract_blocks(source, {'Selected': 'text'}), {'Selected': block})

    def test_invalid_source_keeps_the_existing_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / SYNC.parent).mkdir(parents=True)
            shutil.copyfile(ROOT / SYNC, root / SYNC)
            reference = root / REFERENCE
            reference.parent.mkdir(parents=True)
            reference.write_bytes(b'existing reference\n')
            heading = '1. 为一个 API 写注释'
            for source, diagnostic in (
                ('', '找不到标题'),
                (f'## {heading}\n~~~text\n~~~\n', '找不到 cangjie 块'),
                (f'## {heading}\n~~~cangjie\n~~~\n## {heading}\n', '标题重复'),
                (f'## {heading}\n~~~~cangjie\n~~~\n', '围栏未闭合'),
            ):
                with self.subTest(diagnostic=diagnostic):
                    (root / 'README.md').write_text(source, encoding='utf-8')
                    result = subprocess.run([sys.executable, root / SYNC], capture_output=True)
                    self.assertEqual(result.returncode, 1)
                    for expected in ('README.md', heading, diagnostic):
                        self.assertIn(expected, result.stderr.decode())
                    self.assertEqual(reference.read_bytes(), b'existing reference\n')


class PreviewApiCommentSkillTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report_targets = staticmethod(runpy.run_path(str(PREVIEW))['report_targets'])

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.site = Path(directory.name).resolve() / 'site'
        self.root = self.site / 'html'
        self.root.mkdir(parents=True)

    def entry(self, symbol_id, signature, href):
        return {'id': symbol_id, 'qualifiedName': 'demo.greet', 'sourceHeader': signature, 'href': href}

    def write_index(self, entries, root=None, schema='cjdoc.symbol-index/2'):
        root = root or self.root
        (root / 'symbol-index.json').write_text(
            json.dumps({'schemaVersion': schema, 'entries': entries}), encoding='utf-8')

    def invoke(self, *targets, languages=()):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = self.report_targets(self.site, languages, list(targets))
        return code, stdout.getvalue(), stderr.getvalue()

    def test_ambiguous_name_lists_overloads_but_exact_id_has_one_page(self):
        string_sig = 'public func greet(name: String): String'
        integer_sig = 'public func greet(id: Int64): String'
        pages = [self.root / 'space in route.html', self.root / 'greet-id.html']
        for page in pages:
            page.write_text('<!doctype html>', encoding='utf-8')
        self.write_index([
            self.entry('demo-string', string_sig, pages[0].name),
            self.entry('demo-int', integer_sig, pages[1].name),
        ])
        code, stdout, stderr = self.invoke('demo.greet', 'demo-string')
        self.assertEqual(code, 1)
        self.assertIn(f'{string_sig} [demo-string]\n  {pages[0].as_uri()}', stdout)
        self.assertNotIn(integer_sig, stdout)
        self.assertIn(f'{string_sig} [demo-string]\n  {pages[0].as_uri()}', stderr)
        self.assertIn(f'{integer_sig} [demo-int]\n  {pages[1].as_uri()}', stderr)
        self.assertEqual(self.invoke('demo-int'), (
            0, f'html: {integer_sig} [demo-int]\n  {pages[1].as_uri()}\n', ''))
        for partial in ('greet', 'demo', 'demo-str'):
            with self.subTest(target=partial):
                self.assertEqual(self.invoke(partial), (1, '', f'html: no exact match for {partial}\n'))

    def test_outside_missing_and_nonregular_pages_are_not_returned(self):
        outside = self.site / 'outside.html'
        outside.write_text('<!doctype html>', encoding='utf-8')
        (self.root / 'directory.html').mkdir()
        hrefs = ['../outside.html', str(outside), 'missing.html', 'directory.html']
        symlink = self.root / 'link.html'
        try:
            symlink.symlink_to(outside)
        except (OSError, NotImplementedError):
            pass  # Windows can prohibit symlink creation without Developer Mode.
        else:
            hrefs.append(symlink.name)
        for href in hrefs:
            with self.subTest(href=href):
                self.write_index([self.entry('demo-string', 'greet(String)', href)])
                code, stdout, stderr = self.invoke('demo.greet')
                self.assertEqual((code, stdout), (1, ''))
                self.assertNotIn('file:', stderr)

    def test_each_language_requires_a_current_index(self):
        for language, schema in (('zh-CN', 'cjdoc.symbol-index/2'), ('en', 'cjdoc.symbol-index/1')):
            root = self.root / language
            root.mkdir()
            (root / 'greet.html').write_text('<!doctype html>', encoding='utf-8')
            self.write_index([self.entry('demo-string', 'greet(String)', 'greet.html')], root, schema)
        code, stdout, stderr = self.invoke('demo.greet', languages=('zh-CN', 'en'))
        self.assertEqual(code, 1)
        self.assertIn((self.root / 'zh-CN/greet.html').as_uri(), stdout)
        self.assertNotIn('/en/', stdout)
        self.assertIn('en: cannot read symbol index: incompatible', stderr)
