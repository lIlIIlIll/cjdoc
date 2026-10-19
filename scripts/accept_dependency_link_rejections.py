#!/usr/bin/env python3
"""Exercise version, scope, cache, ambiguity and unsafe-index failures via real CLI."""
from __future__ import annotations
import argparse
import copy
import hashlib
import html
import json
import os
from pathlib import Path
import subprocess
from document_navigation import decode_document_navigation, encode_document_navigation


def navigation(document):
    def visit(value):
        if isinstance(value, dict):
            if 'spelling' in value and 'semantic' in value and value.get('navigation'):
                yield value['navigation']
            for child in value.values():
                yield from visit(child)
        elif isinstance(value, list):
            for child in value:
                yield from visit(child)
    return list(visit(document))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('target/release/bin/main'))
    parser.add_argument('--workspace', type=Path, required=True, help='completed accept_dependency_links.py output')
    args = parser.parse_args()
    binary = args.binary.resolve(); root = args.workspace.resolve()
    consumer = root / 'consumer-v1'
    evidence = root / 'evidence'
    index = json.loads((root / 'v1-site/html/symbol-index.hidden').read_text())
    other = json.loads((root / 'v2-site/html/symbol-index.hidden').read_text())
    results = []
    def generate(name, documents, extra=(), require_external=False, pin_inventories=True):
        catalog = root / ('matrix-' + name + '.json')
        catalog.write_text(json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': documents}, sort_keys=True))
        destination = root / ('matrix-' + name)
        command = [str(binary), 'generate', '--project', str(consumer), '--output', str(destination),
                   '--format', 'json', '--format', 'html', '--doc-source', str(catalog), '--lint-profile', 'off', *extra]
        if pin_inventories:
            for source in documents:
                path = (root / source['index']).resolve()
                if path.is_relative_to(root) and path.is_file() and path.stat().st_size <= 8 * 1024 * 1024:
                    command += ['--doc-inventory-pin', str(path) + '=' + hashlib.sha256(path.read_bytes()).hexdigest()]
        completed = subprocess.run(command, cwd=root, capture_output=True, text=True)
        (evidence / (name + '.log')).write_text(completed.stdout + completed.stderr)
        assert completed.returncode == 0, name + ' generation failed'
        document = decode_document_navigation(json.loads((destination / 'docs.json').read_text()))
        assert document['apiCollectionState'] == 'resolved', 'navigation/display failure polluted source API collection facts'
        decisions = navigation(document)
        external = [item for item in decisions if item['state'] == 'resolved' and item['documentSetId']]
        if require_external:
            assert external, name + ' did not resolve any external target'
        else:
            assert not external, name + ' incorrectly linked external API'
        results.append({'case': name, 'externalTargets': len(external), 'reasons': sorted({item['reason'] for item in decisions})})
        return document, external
    def entry(path='v1-site/html/symbol-index.hidden', base='https://docs.example.test/api/v1', **more):
        return {'index': path, 'baseUrl': base, **more}
    forged = copy.deepcopy(index)
    for item in forged['documentSets']:
        item['state'] = 'verified'
        item['source'] = 'invented author statement only'
    for item in forged['entries']:
        item['href'] = 'forged.html#invented'
    forged_path = root / 'forged-index.json'
    forged_path.write_text(json.dumps(forged))
    untrusted, links = generate('publisher-cannot-self-verify', [entry('forged-index.json')],
                                require_external=True, pin_inventories=False)
    assert all(item['matchLevel'] == 'manual' for item in links)
    assert all(item['state'] == 'declared' for item in untrusted['documentSets'])
    original_pin = hashlib.sha256((root / 'v1-site/html/symbol-index.hidden').read_bytes()).hexdigest()
    generate('complete-payload-tamper-host-pin-unchanged', [entry('forged-index.json')],
             ['--doc-inventory-pin', str(forged_path) + '=' + original_pin], pin_inventories=False)
    generate('wrong-version', [entry('v2-site/html/symbol-index.hidden')])
    strict = subprocess.run([str(binary), 'check', '--project', str(consumer), '--doc-source',
                             str(root / 'matrix-wrong-version.json'), '--lint-profile', 'strict'],
                            cwd=root, capture_output=True, text=True)
    (evidence / 'strict-selection-policy.log').write_text(strict.stdout + strict.stderr)
    assert strict.returncode != 0 and 'CJDOC2310' in strict.stdout + strict.stderr
    results.append({'case': 'strict-selection-policy', 'exitCode': strict.returncode, 'diagnostic': 'CJDOC2310'})
    changed = consumer.parent / 'v1/src/api.cj'
    original = changed.read_bytes(); stat = changed.stat()
    try:
        changed.write_bytes(original + b'\n/** Local uncommitted API modification. */\npublic class Added {}\n')
        os.utime(changed, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        generate('source-content-same-mtime', [entry()])
        repinned = copy.deepcopy(index)
        for item in repinned['entries']:
            item['href'] = 'new-deployment/' + item['href']
        (root / 'repinned-old-api.json').write_text(json.dumps(repinned))
        generate('new-pin-cannot-override-actual-source-identity', [entry('repinned-old-api.json')])
    finally:
        changed.write_bytes(original); os.utime(changed, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    unsafe = copy.deepcopy(index)
    for item in unsafe['entries']:
        item['href'] = 'javascript:alert(1)'
    (root / 'unsafe-index.json').write_text(json.dumps(unsafe))
    generate('unsafe-route', [entry('unsafe-index.json')])
    (root / 'duplicate-index.json').write_text('{"schemaVersion":"cjdoc.symbol-index/2","schemaVersion":"cjdoc.symbol-index/2"}')
    generate('duplicate-index', [entry('duplicate-index.json')])
    (root / 'unknown-schema-index.json').write_text(json.dumps({**index, 'schemaVersion': 'cjdoc.symbol-index/999'}))
    generate('wrong-schema', [entry('unknown-schema-index.json')])
    duplicate_symbols = copy.deepcopy(index)
    duplicate_symbols['entries'].append(copy.deepcopy(duplicate_symbols['entries'][0]))
    (root / 'duplicate-symbol-index.json').write_text(json.dumps(duplicate_symbols))
    generate('duplicate-portable-symbol', [entry('duplicate-symbol-index.json')])
    for name, href in [('traversal', '../outside.html'), ('bad-escape', 'type.html#%ZZ'),
                       ('encoded-control', 'type.html#%0Ainjected'), ('unsafe-port', 'https://docs.example.test:99999/type.html')]:
        invalid = copy.deepcopy(index)
        for item in invalid['entries']:
            item['href'] = href
        path = name + '-index.json'
        (root / path).write_text(json.dumps(invalid))
        generate(name, [entry(path)])
    (root / 'oversize-index.json').write_text(' ' * (8 * 1024 * 1024 + 1))
    generate('index-byte-limit', [entry('oversize-index.json')])
    platform = copy.deepcopy(index)
    for item in platform['documentSets']:
        item['target'] = 'other-platform'
    (root / 'platform-index.json').write_text(json.dumps(platform))
    generate('platform-mismatch', [entry('platform-index.json')])
    language = copy.deepcopy(index)
    for item in language['documentSets']:
        item['language'] = 'en'
    (root / 'english-index.json').write_text(json.dumps(language))
    generate('language-missing', [entry('english-index.json')], ['--link-language', 'zh-CN'])
    _, links = generate('language-fallback', [entry('english-index.json')], ['--link-language', 'zh-CN', '--link-language-fallback'], True)
    assert all(item['language'] == 'en' and item['matchLevel'] == 'exact' for item in links)
    documents = [entry(), entry(base='https://mirror.example.test/api/v1')]
    first, _ = generate('ambiguous-order-a', documents)
    second, _ = generate('ambiguous-order-b', list(reversed(documents)))
    assert first == second, 'catalog enumeration order changed frozen decisions'
    generate('unrelated-bad-index', [entry(), entry('duplicate-index.json')], require_external=True)
    generate('unrelated-bad-index-first', [entry('duplicate-index.json'), entry()], require_external=True)
    selected = next(item for item in first['dependencies'] if item['name'] == 'library')
    target = next(item for item in other['documentSets'] if item['library'] == 'library')
    mapping = {'fromIdentity': selected['identity'], 'toIdentity': target['identity'],
               'target': selected['target'], 'cfg': selected['cfg'],
               'evidence': 'controlled two-version fixture; shared documented Widget/Box API, explicit user-scoped policy; no ABI or behavior assertion'}
    mapped = [entry('v2-site/html/symbol-index.hidden', compatibilityMappings=[mapping])]
    generate('compatibility-opt-in-required', mapped)
    _, links = generate('compatibility-explicit', mapped, ['--link-compatible'], True)
    assert all(item['matchLevel'] == 'compatible' and item['apiIdentity'] == target['identity'] for item in links)
    local, _ = generate('authoritative-local', [entry()], ['--include-path-dependencies'])
    assert any(item['state'] == 'resolved' and item['matchLevel'] == 'exact' and not item['documentSetId'] for item in navigation(local))
    def guide_decision(document):
        page = next(item for item in document['pages'] if item['source'] == 'docs/guide.md')
        return next(item for item in page['bindings'] if item['target'] == 'library.Widget.lookup')['navigation']
    no_header = copy.deepcopy(index)
    for symbol in no_header['entries']:
        symbol.pop('sourceHeader', None)
    (root / 'no-header-index.json').write_text(json.dumps(no_header))
    absent, _ = generate('guide-header-witness-missing', [entry('no-header-index.json')], require_external=True)
    assert guide_decision(absent)['state'] != 'resolved', 'missing header guessed an exact guide selector'
    guide_path = consumer / 'docs/guide.md'
    original_guide = guide_path.read_bytes(); guide_stat = guide_path.stat()
    try:
        original_text = original_guide.decode()
        exact_selector = 'signature:public func lookup(value: Int64): Int64'
        assert exact_selector in original_text
        guide_path.write_text(original_text.replace(exact_selector, 'signature:public func lookup(value: Bool): Bool'))
        wrong, _ = generate('guide-header-no-such-overload', [entry()], require_external=True)
        assert guide_decision(wrong)['state'] != 'resolved'
        guide_path.write_text(original_text.replace(exact_selector, 'example'))
        ambiguous_guide, _ = generate('guide-unselected-overload-is-ambiguous', [entry()], require_external=True)
        assert guide_decision(ambiguous_guide)['state'] == 'ambiguous', 'bare guide member selected first overload'
    finally:
        guide_path.write_bytes(original_guide)
        os.utime(guide_path, ns=(guide_stat.st_atime_ns, guide_stat.st_mtime_ns))
    source = consumer / 'src/api.cj'
    original_source = source.read_bytes(); source_stat = source.stat()
    try:
        source.write_text('package consumer\nimport library.Box\npublic func ambiguous(input: Box<Int64>): Box<Int64> { input }\n')
        compiled = subprocess.run(['cjpm', 'build'], cwd=consumer, capture_output=True, text=True)
        compiler_log = compiled.stdout + compiled.stderr
        (evidence / 'actual-implicit-core-conflict.log').write_text(compiler_log)
        assert compiled.returncode != 0 and 'Box' in compiler_log and 'ambiguous' in compiler_log.lower()
        collision, _ = generate('implicit-core-import-conflict', [entry()])
        assert any('implicit std.core conflict' in item['reason'] for item in navigation(collision))
    finally:
        source.write_bytes(original_source)
        os.utime(source, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
    colon_fragment = copy.deepcopy(index)
    for symbol in colon_fragment['entries']:
        symbol['href'] = symbol['href'].split('#', 1)[0] + '#symbol:name'
    (root / 'colon-fragment-index.json').write_text(json.dumps(colon_fragment))
    _, admitted_colon = generate('relative-fragment-colon', [entry('colon-fragment-index.json', base='./deps')], require_external=True)
    assert all(item['url'].endswith('#symbol:name') for item in admitted_colon), 'safe inventory fragment was rejected or rewritten during navigation consumption'
    upstream_query = copy.deepcopy(index)
    for symbol in upstream_query['entries']:
        symbol['href'] = symbol['href'].split('#', 1)[0] + '?plain=1#L3'
    (root / 'upstream-query-index.json').write_text(json.dumps(upstream_query))
    _, admitted_query = generate('official-plain-query-route', [entry('upstream-query-index.json', base='./deps')], require_external=True)
    assert all(item['url'].endswith('?plain=1#L3') for item in admitted_query), 'safe entry query was rejected or changed between binding and rendering'
    frozen = decode_document_navigation(json.loads((root / 'consumer-v1-offline/docs.json').read_text()))
    for name, url, valid in [
        ('render-absolute-bad-percent', 'https://docs.example.test/type.html#%ZZ', False),
        ('render-absolute-invalid-port', 'https://docs.example.test:99999/type.html', False),
        ('render-absolute-encoded-control', 'https://docs.example.test/type.html#%0Ainjected', False),
        ('render-absolute-encoded-traversal', 'https://docs.example.test/%2e%2e/type.html', False),
        ('render-absolute-encoded-separator', 'https://docs.example.test/type.html#%2f', False),
        ('render-absolute-truncated-utf8', 'https://docs.example.test/%E4%B8/type.html', False),
        ('render-relative-path-colon', './unsafe:path.html#symbol', False),
        ('render-absolute-duplicate-query', 'https://docs.example.test/api.md?plain=1&plain=2#L3', False),
        ('render-absolute-query-control', 'https://docs.example.test/api.md?plain=%0A#L3', False),
        ('render-relative-query-no-key', './external.html?=1#symbol', False),
        ('render-relative-nested-query', './external.html?plain=1?extra=2#symbol', False),
        ('render-relative-query-separator', './external.html?plain=1;extra=2#symbol', False),
        ('render-relative-query-unicode', './external.html?view=中文#symbol', False),
        ('render-relative-query-encoded-unicode', './external.html?view=%E4%B8%AD#symbol', False),
        ('render-relative-query-over-limit', './external.html?' + '&'.join(f'k{i}=v' for i in range(33)) + '#symbol', False),
        ('render-absolute-plain-query', 'https://docs.example.test/api.md?plain=1#L3', True),
        ('render-relative-plain-query', './external.html?plain=1#symbol:name', True),
        ('render-relative-query-at-limit', './external.html?' + '&'.join(f'k{i}=v' for i in range(32)) + '#symbol', True),
        ('render-absolute-unicode', 'https://docs.example.test:8443/%E4%B8%AD%E6%96%87.html#%E7%B1%BB', True),
        ('render-relative-unicode', './%E4%B8%AD%E6%96%87.html#%E7%B1%BB', True),
    ]:
        supplied = copy.deepcopy(frozen)
        binding = next(binding for page in supplied['pages'] for binding in page['bindings']
                       if binding.get('navigation') and binding['navigation']['documentSetId'])
        binding['state'] = 'unresolved'
        binding['targetSymbolId'] = None
        binding['navigation'].update(state='resolved', matchLevel='manual', url=url,
                                     reason='Explicit public IR reference; hosting not authenticated')
        path = root / (name + '.json')
        path.write_text(json.dumps(encode_document_navigation(supplied)))
        destination = root / name
        rendered = subprocess.run([str(binary), 'render', '--input', str(path), '--output', str(destination),
            '--format', 'html', '--format', 'markdown', '--format', 'symbol-index'],
            cwd=root, capture_output=True, text=True)
        (evidence / (name + '.log')).write_text((rendered.stdout + rendered.stderr).replace(str(root), '<acceptance>'))
        if valid:
            assert rendered.returncode == 0, name + ' rejected a supported UTF-8 navigation route'
            assert any(html.escape(url.removeprefix('./'), quote=True) in file.read_text() for file in (destination / 'html/concepts').rglob('*.html')), name + ' omitted the valid guide navigation'
        else:
            assert rendered.returncode == 2, name + ' published an unsafe absolute navigation URL'
            assert not destination.exists(), name + ' left a partial published output'
        results.append({'case': name, 'exitCode': rendered.returncode, 'routeAccepted': valid})
    (evidence / 'rejection-matrix.json').write_text(json.dumps(results, indent=2, sort_keys=True))
    print('PASS: ' + str(len(results)) + ' real CLI selection/rejection cases; original content+mtime restored')


if __name__ == '__main__':
    main()
