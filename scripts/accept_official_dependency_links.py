#!/usr/bin/env python3
"""Bind real selected std/stdx artifacts to an explicitly scoped fixed doc snapshot."""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import subprocess
import sys
from document_navigation import decode_navigation


def invoke(command, cwd, log):
    result = subprocess.run([str(item) for item in command], cwd=cwd, capture_output=True, text=True)
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(log.name + ': command exited ' + str(result.returncode))


def navigation_facts(value):
    if isinstance(value, dict):
        for key in ('navigation', 'semanticNavigation'):
            if value.get(key) is not None:
                yield decode_navigation(value[key])
        for child in value.values():
            yield from navigation_facts(child)
    elif isinstance(value, list):
        for child in value:
            yield from navigation_facts(child)


class Anchors(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.links = []
        self.current = None
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            self.current = [dict(attrs).get('href', ''), '']

    def handle_data(self, data):
        if self.current is not None:
            self.current[1] += data

    def handle_endtag(self, tag):
        if tag == 'a' and self.current is not None:
            self.links.append(self.current)
            self.current = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('target/release/bin/main'))
    parser.add_argument('--sdk', type=Path, required=True, help='actual compiler SDK selected for this target build')
    parser.add_argument('--stdx', type=Path, required=True, help='actual stdx import artifact directory selected for this build')
    parser.add_argument('--target', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    binary = args.binary.resolve(); sdk = args.sdk.resolve(); stdx = args.stdx.resolve(); output = args.output.resolve()
    if output.exists():
        raise SystemExit('--output must be new')
    output.mkdir(mode=0o700, parents=True)
    project = output / 'consumer'; (project / 'src').mkdir(parents=True)
    manifest = ('[package]\ncjc-version = "1.2.0"\nname = "official_consumer"\nversion = "0.1.0"\noutput-type = "static"\n' +
                '[target.' + args.target + '.bin-dependencies]\npath-option = [' + json.dumps(str(stdx)) + ']\n')
    (project / 'cjpm.toml').write_text(manifest)
    (project / 'src/api.cj').write_text('''package official_consumer
import std.collection as stdCollection
import stdx.encoding.json as stdxJson
/** The selected standard-library type. See {@link std.collection.ArrayDeque.capacity}. */
public func deque(input: stdCollection.ArrayDeque<Int64>): stdCollection.ArrayDeque<Int64> { input }
/** The independently selected extension type.
 * @see stdx.encoding.json.JsonArray.add(JsonValue) Exact source-verified member.
 */
public func json(input: stdxJson.JsonArray): stdxJson.JsonArray { input }
private func compiledMemberWitness(queue: stdCollection.ArrayDeque<Int64>, values: stdxJson.JsonArray): Int64 {
    values.add(stdxJson.JsonString("value"))
    queue.capacity
}
''')
    invoke([sdk / 'tools/bin/cjpm' if (sdk / 'tools/bin/cjpm').exists() else sdk / 'bin/cjpm', 'build'],
           project, output / 'actual-target-build.log')
    std_artifact = sdk / ('modules/linux_x86_64_cjnative/std/std.collection.cjo')
    if not std_artifact.is_file():
        raise SystemExit('This acceptance command currently requires the explicitly selected Linux x64 STS layout')
    receipt = output / 'build-context.json'
    invoke([sys.executable, repo / 'scripts/capture_build_context.py', '--project', project, '--output', receipt,
            '--target', args.target, '--dependency', 'official_consumer:toolchain:toolchain=' + str(sdk / 'bin/cjc'),
            '--dependency', 'official_consumer:std:std=' + str(std_artifact),
            '--dependency', 'official_consumer:stdx:stdx=' + str(stdx / 'stdx.encoding.json.cjo')], repo, output / 'capture.log')
    official = output / 'official'
    invoke([sys.executable, repo / 'scripts/prepare_official_inventory.py', '--manifest', repo / 'tests/fixtures/external_docs/official83/manifest.json',
            '--bundle', repo / 'tests/fixtures/external_docs/official83', '--output', official / 'symbol-index.json',
            '--html-output', official / 'official-pages'], repo, output / 'prepare.log')
    record = json.loads(receipt.read_text())
    inventory = json.loads((official / 'symbol-index.json').read_text())
    mappings = []
    for dependency in record['modules'][0]['dependencies']:
        if dependency['kind'] not in ['std', 'stdx']:
            continue
        target = next(item for item in inventory['documentSets'] if item['library'] == dependency['name'])
        mappings.append({'fromIdentity': dependency['identity'], 'toIdentity': target['identity'], 'target': args.target, 'cfg': '',
                         'evidence': 'Explicit user-scoped source-reference mapping for the four pinned documented symbols; actual signature consumer compiled; not API/ABI/behavior equivalence or authenticated release mapping'})
    catalog = output / 'cjdoc-documents.json'
    catalog.write_text(json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': [
        {'index': 'official/symbol-index.json', 'baseUrl': './official-pages', 'compatibilityMappings': mappings}]}))
    # The operator pins freshly produced, independently source-checked bytes;
    # this value is not read from inventory/catalog self-reported metadata.
    inventory_pin = str(official / 'symbol-index.json') + '=' + hashlib.sha256((official / 'symbol-index.json').read_bytes()).hexdigest()
    site = output / 'site'
    invoke([binary, 'generate', '--project', project, '--build-context', receipt, '--doc-source', catalog,
            '--link-compatible', '--link-language', 'en', '--doc-inventory-pin', inventory_pin,
            '--format', 'json', '--format', 'html', '--format', 'markdown',
            '--output', site, '--lint-profile', 'off'], repo, output / 'generate.log')
    document = json.loads((site / 'docs.json').read_text())
    components = {item['name']: item for item in document['dependencies'] if item['name'] in ['std', 'stdx', 'toolchain']}
    assert all(components[name]['state'] == 'verified' for name in ['std', 'stdx', 'toolchain'])
    assert components['std']['identity'] != components['stdx']['identity']
    decisions = []
    public = [item for item in document['declarations'] if item['name'] in ('deque', 'json')]
    assert len(public) == 2 and all(item['visibility'] == 'public' for item in public)
    for declaration in public:
        for parameter in declaration['parameters']:
            nav = parameter['type']['navigation']
            assert nav['state'] == 'resolved' and nav['matchLevel'] == 'compatible'
            assert nav['apiIdentity'].startswith('official-doc-source:')
            decisions.append(nav)
        nav = declaration['returnType']['navigation']
        assert nav['state'] == 'resolved' and nav['matchLevel'] == 'compatible'
        decisions.append(nav)
    members = {nav['symbolKey'].split('|')[0]: nav for declaration in public for nav in navigation_facts(declaration)
               if nav.get('symbolKey', '').split('|')[0] in ('std.collection.ArrayDeque.capacity', 'stdx.encoding.json.JsonArray.add')}
    for name, fragment in [('std.collection.ArrayDeque.capacity', '#L18'), ('stdx.encoding.json.JsonArray.add', '#L55')]:
        assert name in members and members[name]['state'] == 'resolved' and members[name]['matchLevel'] == 'compatible'
        assert members[name]['url'].endswith(fragment)
    html_links = [link for path in (site / 'html/symbols').glob('*.html') for link in Anchors(path.read_text()).links]
    assert any(href.endswith('#L18') and 'std.collection.ArrayDeque.capacity' in text for href, text in html_links), 'body member link was not presented'
    assert any(href.endswith('#L55') and 'stdx.encoding.json.JsonArray.add' in text for href, text in html_links), '@see member link was not presented'
    all_types = [parameter['type'] for declaration in document['declarations'] for parameter in declaration['parameters']]
    all_types += [declaration['returnType'] for declaration in document['declarations'] if declaration.get('returnType')]
    shutil.copytree(official / 'official-pages', site / 'html/official-pages')
    # The local receipt is intentionally not a distributable output. Only portable
    # identities and verified scope are published, never the observation paths.
    encoded = (site / 'docs.json').read_text()
    assert str(output) not in encoded and str(sdk) not in encoded and str(stdx) not in encoded
    negative = {}
    for name, allow_compatible, selected_catalog in [
        ('not-opted-in', False, catalog),
        ('wrong-platform-map', True, output / 'wrong-platform.json'),
    ]:
        if name == 'wrong-platform-map':
            wrong = json.loads(catalog.read_text())
            for mapping in wrong['documents'][0]['compatibilityMappings']:
                mapping['target'] = args.target + '-different'
            selected_catalog.write_text(json.dumps(wrong))
        destination = output / name
        command = [binary, 'generate', '--project', project, '--build-context', receipt,
                   '--doc-source', selected_catalog, '--link-language', 'en', '--doc-inventory-pin', inventory_pin, '--format', 'json',
                   '--output', destination, '--lint-profile', 'off']
        if allow_compatible:
            command.append('--link-compatible')
        invoke(command, repo, output / (name + '.log'))
        rejected = json.loads((destination / 'docs.json').read_text())
        rejected_public = [item for item in rejected['declarations'] if item['name'] in ('deque', 'json')]
        rejected_types = [parameter['type'] for declaration in rejected_public for parameter in declaration['parameters']]
        rejected_types += [declaration['returnType'] for declaration in rejected_public if declaration.get('returnType')]
        assert len(rejected_types) == len(decisions)
        assert all(decode_navigation(item['navigation'])['state'] != 'resolved' for item in rejected_types)
        negative[name] = {'rejectedTypePositions': len(rejected_types), 'result': 'passed'}
    (output / 'evidence.json').write_text(json.dumps({'components': components, 'navigation': decisions,
        'officialEntries': 4, 'officialDocumentSets': 2, 'releaseMapping': 'none', 'negativeCases': negative,
        'explicitMemberTargets': members, 'allTopLevelTypePositions': len(all_types),
        'allTopLevelNavigationStates': dict(Counter((decode_navigation(item['navigation']) or {}).get('state', 'not-applicable/no-recorded-decision') for item in all_types)),
        'allDeclarationVisibility': dict(Counter(item['visibility'] for item in document['declarations'])),
        'qualityScope': 'four public external type positions and two explicit member targets; all author-IR/private/primitive counts retained separately',
        'mappingLevel': 'compatible, explicitly user-declared source-reference scope; not exact release mapping',
        'actualTargetCompile': 'passed, including capacity and add(JsonString) member witnesses',
        'renderedReliableTargets': len(decisions), 'renderCoveragePercent': 100}, indent=2, sort_keys=True))
    print('PASS: actual target/member compile; independent std/stdx observations; fixed source-reference mapping is compatible, not exact; no-opt-in/wrong-platform mappings rejected')
    print('Browser clicks and detached render are separate acceptance steps.')


if __name__ == '__main__':
    main()
