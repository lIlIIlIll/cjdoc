#!/usr/bin/env python3
"""Compile lexical-shadow fixtures and check API/body/tag/offline link decisions."""
from __future__ import annotations
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import subprocess
from accept_dependency_links import Signature
from document_navigation import decode_document_navigation


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def run(command, cwd, evidence, name):
    result = subprocess.run([str(part) for part in command], cwd=cwd, capture_output=True, text=True)
    write(evidence / (name + '.log'), (result.stdout + result.stderr).replace(str(cwd), '<scope>'))
    if result.returncode:
        raise AssertionError(name + ' failed; see ' + name + '.log')


def nodes(node):
    yield node
    for child in node['children']:
        yield from nodes(child)


class Links(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.links = []
        self.active = None
        self.excluded = 0
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        if tag in ('nav', 'aside'):
            self.excluded += 1
        if tag == 'a' and not self.excluded:
            self.active = [dict(attrs).get('href', ''), '']

    def handle_data(self, text):
        if self.active is not None:
            self.active[1] += text

    def handle_endtag(self, tag):
        if tag in ('nav', 'aside'):
            self.excluded -= 1
        if tag == 'a' and self.active is not None:
            self.links.append(self.active)
            self.active = None


def comment_for(name, bare, qualified):
    return '''/**
 * Generic parameter reference: {@link BARE}; explicit target: {@link QUALIFIED}.
 * @summary[lang=zh-CN] 泛型参数 {@link BARE}；明确目标 {@link QUALIFIED}。
 * @see BARE The generic parameter, not the imported or local class.
 * @see[lang=zh-CN] BARE 泛型参数，不是导入或本地类。
 * @see QUALIFIED The explicit class target.
 * @see[lang=zh-CN] QUALIFIED 明确的类目标。
 * @throws BARE The generic parameter documentation subject.
 * @throws[lang=zh-CN] BARE 泛型参数文档主题。
 */
'''.replace('BARE', bare).replace('QUALIFIED', qualified)


def verify(document, destination, owners):
    report = []
    by_name = {item['name']: item for item in document['declarations']}
    for name, bare, qualified in owners:
        owner = by_name[name]
        comment = owner['documentation']
        weak = []
        strong = []
        trees = [comment['markdown']] + [item['markdown'] for item in comment['localizedTexts']]
        for tree in trees:
            for node in nodes(tree):
                metadata = node.get('metadata') or {}
                target = metadata.get('target') if node['kind'] == 'semantic_link' else None
                if target == bare:
                    decision = metadata.get('semanticNavigation') or {}
                    weak.append(metadata.get('state') != 'resolved' and
                                metadata.get('targetSymbolId') is None and
                                metadata.get('externalUrl') is None and
                                decision.get('state') == 'unavailable' and not decision.get('url') and
                                bool(decision.get('reason')))
                elif target == qualified:
                    decision = metadata.get('semanticNavigation') or {}
                    strong.append(decision.get('state') == 'resolved' and bool(decision.get('url')))
        tagged = []
        localized = []
        for tag in comment['tags']:
            if tag['name'] in ('see', 'throws') and tag['subject'] == bare:
                tagged.append(tag['referenceState'] != 'resolved' and tag['targetSymbolId'] is None)
        for item in comment['localizedTexts']:
            if item['kind'] in ('see', 'throws') and item['subject'] == bare:
                decision = item.get('navigation') or {}
                localized.append(item['referenceState'] != 'resolved' and item['targetSymbolId'] is None and
                                 decision.get('state') == 'unavailable' and not decision.get('url'))
        rendered = []
        for path in (destination / 'html').rglob('*.html'):
            content = path.read_text(encoding='utf-8')
            if Signature(content).text != owner['headerSpelling']:
                continue
            links = Links(content).links
            rendered.append(not any(label.strip() == bare for _, label in links))
        markdown = []
        for path in (destination / 'markdown').rglob('*.md'):
            content = path.read_text(encoding='utf-8')
            if owner['headerSpelling'] in content:
                markdown.append('[' + bare + '](' not in content and '[`' + bare + '`](' not in content)
        report.append({'owner': name, 'bodyBarePreservedWithoutTarget': bool(weak) and all(weak),
                       'qualifiedBodyTargetsResolved': bool(strong) and all(strong),
                       'legacyTagsHaveNoFalseLocalId': all(tagged),
                       'localizedSeeThrowsPreservedWithoutTarget': len(localized) >= 4 and all(localized),
                       'htmlHasNoShadowedNameLink': bool(rendered) and all(rendered),
                       'markdownHasNoShadowedNameLink': bool(markdown) and all(markdown),
                       'bodyReferenceOccurrences': len(weak), 'localizedReferenceOccurrences': len(localized)})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compile-fixtures', action='store_true', required=True,
                        help='explicitly authorize actual fixture compilation')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    output = args.output.resolve()
    if output.exists():
        parser.error('--output must be a new task-private directory')
    output.mkdir(parents=True, mode=0o700)
    evidence = output / 'evidence'
    evidence.mkdir()
    library = output / 'library'
    write(library / 'cjpm.toml', '[package]\ncjc-version = "1.2.0"\nname = "library"\nversion = "1.0.0"\noutput-type = "static"\nsrc-dir = "src"\n')
    write(library / 'src/api.cj', 'package library\npublic class Widget { public init() {} }\n')
    run(['cjpm', 'build'], library, evidence, 'compile-library')
    producer = output / 'library-site'
    run([binary, 'generate', '--project', library, '--output', producer, '--format', 'html', '--lint-profile', 'off'],
        output, evidence, 'generate-real-inventory')
    inventory = producer / 'html/symbol-index.json'
    pin = hashlib.sha256(inventory.read_bytes()).hexdigest()
    catalog = output / 'catalog.json'
    write(catalog, json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': [
        {'index': 'library-site/html/symbol-index.json', 'baseUrl': 'https://docs.example.test/scope-library'}]}))
    reports = []
    for kind in ['alias', 'local']:
        project = output / kind
        package = 'scope_' + kind
        dependency = '\n[dependencies]\nlibrary = { path = "../library" }\n' if kind == 'alias' else ''
        write(project / 'cjpm.toml', '[package]\ncjc-version = "1.2.0"\nname = "' + package + '"\nversion = "0.1.0"\noutput-type = "static"\nsrc-dir = "src"\n' + dependency)
        write(project / 'cjdoc.toml', '[i18n]\ndefault-language = "en"\nlanguages = ["en", "zh-CN"]\n')
        bare = 'RemoteWidget' if kind == 'alias' else 'Widget'
        qualified = 'library.Widget' if kind == 'alias' else package + '.Widget'
        source = 'package ' + package + '\n'
        source += 'import library.Widget as RemoteWidget\n' if kind == 'alias' else 'public class Widget { public init() {} }\n'
        source += comment_for('shadow', bare, qualified)
        source += 'public func shadow<' + bare + '>(input: ' + bare + '): ' + bare + ' { input }\n'
        source += 'public class ScopeOwner<' + bare + '> {\n    public init() {}\n'
        source += comment_for('fromOwner', bare, qualified)
        source += '    public func fromOwner(input: ' + bare + '): ' + bare + ' { input }\n}\n'
        write(project / 'src/api.cj', source)
        run(['cjpm', 'build'], project, evidence, 'compile-' + kind)
        destination = output / (kind + '-site')
        command = [binary, 'generate', '--project', project, '--output', destination, '--format', 'json',
                   '--format', 'html', '--format', 'markdown', '--all-languages', '--lint-profile', 'off']
        if kind == 'alias':
            command += ['--doc-source', catalog, '--doc-inventory-pin', str(inventory) + '=' + pin]
        run(command, output, evidence, 'generate-' + kind)
        document = decode_document_navigation(json.loads((destination / 'docs.json').read_text(encoding='utf-8')))
        cases = verify(document, destination, [('shadow', bare, qualified), ('fromOwner', bare, qualified)])
        reports += [{'context': kind, **case} for case in cases]
        replay = output / (kind + '-replay')
        shutil.move(project / 'src', project / 'detached-src')
        hidden_inventory = inventory.with_suffix('.hidden')
        inventory.rename(hidden_inventory)
        try:
            run([binary, 'render', '--input', destination / 'docs.json', '--output', replay,
                 '--format', 'html', '--format', 'markdown', '--all-languages'], output, evidence, 'detached-' + kind)
        finally:
            hidden_inventory.rename(inventory)
        for format_name in ['html', 'markdown']:
            for path in (destination / format_name).rglob('*'):
                if path.is_file():
                    actual = replay / path.relative_to(destination)
                    assert actual.read_bytes() == path.read_bytes(), 'detached render changed scope decisions'
    summary = {'binarySha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'cases': reports,
               'actualCjpmBuildCommands': 3, 'standaloneInventoryGenerated': True, 'detachedReplays': 2}
    write(evidence / 'scope-reference-results.json', json.dumps(summary, indent=2, ensure_ascii=False) + '\n')
    fields = ['bodyBarePreservedWithoutTarget', 'qualifiedBodyTargetsResolved', 'legacyTagsHaveNoFalseLocalId',
              'localizedSeeThrowsPreservedWithoutTarget', 'htmlHasNoShadowedNameLink', 'markdownHasNoShadowedNameLink']
    assert all(case[field] for case in reports for field in fields), 'lexical scope reference regression; see scope-reference-results.json'
    print('PASS: actual compiled alias/local/ancestor generic scopes, qualified positives, bilingual body/see/throws and detached HTML/Markdown replay')


if __name__ == '__main__':
    main()
