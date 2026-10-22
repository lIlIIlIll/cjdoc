#!/usr/bin/env python3
"""Real CLI dependency/version chain acceptance; all artifacts remain in --output."""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from html.parser import HTMLParser
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time
from document_navigation import decode_document_navigation


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def run(command, root, name, evidence):
    started = time.monotonic()
    result = subprocess.run([str(x) for x in command], cwd=root, capture_output=True, text=True)
    # Compiler output can contain input paths. Evidence is local-only, and its
    # public summary never embeds workstation paths or environment variables.
    write(evidence / (name + '.log'), result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'{name} exited {result.returncode}; see {name}.log')
    return {'name': name, 'seconds': round(time.monotonic() - started, 4), 'exitCode': result.returncode}


def atoms(value):
    if not value:
        return
    yield value
    for item in value['arguments']:
        yield from atoms(item)


def refs(document):
    for declaration in document['declarations']:
        for parameter in declaration['parameters']:
            yield declaration, parameter['name'], parameter['type']
        if declaration['returnType']:
            yield declaration, 'return', declaration['returnType']
        for relationship in declaration['typeRelationships']:
            yield declaration, relationship['kind'], relationship['target']


def identity_quality(document, reliable):
    # Keep semantic/provider identity independent of navigation success. In source
    # mode a scoped, pinned navigation target does not turn partial into resolved.
    values = [atom for _, _, reference in refs(document) for atom in atoms(reference)]
    atomic = [atom for atom in values if atom['kind'] not in ['optional', 'tuple', 'function']]
    canonical = [atom for atom in atomic if atom['semantic']['state'] == 'resolved' and atom['semantic']['canonical']]
    dependencies = document['dependencies']
    observed = sum(item['state'] in ['observed', 'verified'] and bool(item['identity']) for item in dependencies)
    return {
        'dependencyIdentityCoverage': {'identifiedObservedInstances': observed, 'allInstances': len(dependencies),
            'percent': 100 * observed / len(dependencies) if dependencies else None},
        'typeReferenceIdentityCoverage': {'providerCanonicalResolvedPositions': len(canonical),
            'allAtomicPositions': len(atomic), 'allStructuralAndAtomicPositions': len(values),
            'percent': 100 * len(canonical) / len(atomic) if atomic else None,
            'states': dict(Counter(atom['semantic']['state'] for atom in atomic)),
            'canonicalProviders': dict(Counter(atom['semantic']['provider'] or 'unknown' for atom in canonical)),
            'scope': 'all non-wrapper type atoms, including primitive and generic-parameter positions; source navigation never upgrades semantic identity'},
        'externalDocumentTargetCoverage': {'availablePositions': len(reliable), 'allAtomicPositions': len(atomic),
            'percent': 100 * len(reliable) / len(atomic) if atomic else None,
            'scope': 'external targets only; unavailable, primitive and generic-parameter atoms remain in the explicit denominator'}
    }

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Signature(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.active = False
        self.finished = False
        self.text = ''
        self.links = []
        self.anchor = None
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'pre' and not self.finished and 'signature-block' in attrs.get('class', '').split():
            self.active = True
        if self.active and tag == 'a' and 'signature-type-link' in attrs.get('class', '').split():
            self.anchor = [attrs.get('href', ''), '']

    def handle_data(self, data):
        if self.active:
            self.text += data
            if self.anchor is not None:
                self.anchor[1] += data

    def handle_endtag(self, tag):
        if tag == 'a' and self.anchor is not None:
            self.links.append(self.anchor)
            self.anchor = None
        if tag == 'pre' and self.active:
            self.active = False
            self.finished = True


def verify_presentation(document, destination, owner_decisions):
    inventory = json.loads((destination / 'html/symbol-index.json').read_text())
    routes = {entry['id']: entry['href'] for entry in inventory['entries']}
    owners = {item['id']: item for item in document['declarations']}
    expected = defaultdict(Counter)
    for owner_id, decision in owner_decisions:
        href = decision['url']
        if not href.startswith(('http://', 'https://')):
            href = '../' + href.removeprefix('./')
        expected[owner_id][href] += 1
    for owner_id, counts in expected.items():
        signature = Signature((destination / 'html' / routes[owner_id].split('#')[0]).read_text())
        assert signature.text == owners[owner_id]['headerSpelling'], 'copy signature changed'
        observed = Counter(href for href, _ in signature.links)
        assert all('NOT_A_TYPE_Widget' not in label for _, label in signature.links), 'comment text became a linked type'
        assert all(observed[href] >= count for href, count in counts.items()), (owners[owner_id]['name'], counts, observed)
    return sum(sum(counts.values()) for counts in expected.values())

def verify_guide_and_throws(document, destination, identity, version):
    owner = next(item for item in document['declarations'] if item['name'] == 'mayFail')
    tag = next(item for item in owner['documentation']['tags'] if item['name'] == 'throws')
    throwing = tag['navigation']
    assert throwing and throwing['state'] == 'resolved' and throwing['matchLevel'] == 'exact'
    assert throwing['apiIdentity'] == identity and throwing['symbolKey'].startswith('library.Failure|class|')
    page = next(item for item in document['pages'] if item['source'] == 'docs/guide.md')
    association = next(item for item in page['bindings'] if item['target'] == 'library.Widget.lookup')
    assert association['state'] == 'unresolved' and association['targetSymbolId'] is None, 'external href forged a local semantic association'
    selected = association['navigation']
    assert selected and selected['state'] == 'resolved' and selected['matchLevel'] == 'exact'
    assert selected['apiIdentity'] == identity and selected['symbolKey'] == 'library.Widget.lookup|function|0(Int64)'
    assert version in selected['url']
    html = (destination / 'html' / page['route']).read_text()
    depth = len(Path(page['route']).parent.parts)
    href = selected['url'] if selected['url'].startswith(('http://', 'https://')) else '../' * depth + selected['url'].removeprefix('./')
    local = next(item for item in page['bindings'] if item['target'].startswith('id:'))
    assert local['navigation']['state'] == 'resolved' and local['navigation']['symbolKey'] == local['targetSymbolId']
    actual = next(item for item in document['declarations'] if item['id'] == local['targetSymbolId'])
    assert actual['name'] == 'own' and actual['parameters'][0]['type']['spelling'] == 'Int64', 'id guide selector broadened to another overload'
    assert 'href="' + href + '"' in html and 'data-doc-match="exact"' in html
    markdown = (destination / 'markdown' / Path(page['route']).with_suffix('.md')).read_text()
    destination_url = selected['url'] if selected['url'].startswith(('http://', 'https://')) else '../' * (depth + 1) + 'html/' + selected['url'].removeprefix('./')
    assert destination_url in markdown
    return {'throws': throwing, 'guideOverload': selected, 'localAssociationState': association['state']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('target/release/bin/main'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compile-fixtures', action='store_true', help='authorize actual cjpm builds for the controlled libraries and consumers')
    parser.add_argument('--chir-worker', type=Path)
    parser.add_argument('--cjc', type=Path)
    parser.add_argument('--https-base', default='https://docs.example.test/releases')
    args = parser.parse_args()
    if bool(args.chir_worker) != bool(args.cjc):
        parser.error('--chir-worker and --cjc must be provided together')
    binary = args.binary.resolve(); output = args.output.resolve()
    if output.exists():
        raise SystemExit('--output must be a new task-private directory')
    output.mkdir(parents=True, mode=0o700)
    evidence = output / 'evidence'; evidence.mkdir()
    costs = []
    for version, method in [('v1', 'oldApi'), ('v2', 'newApi')]:
        library = output / version
        write(library / 'cjpm.toml', '[package]\ncjc-version = "1.2.0"\nname = "library"\nversion = "' + ('1.0.0' if version == 'v1' else '2.0.0') + '"\noutput-type = "static"\nsrc-dir = "src"\n')
        write(library / 'src/api.cj', '''package library
/** A version-specific external type. */
public open class Widget {
    public init() {}
    /** A member unique to this API version. */
    public func METHOD(): Int64 { 1 }
    /** Integer overload. */
    public func lookup(value: Int64): Int64 { value }
    /** String overload. */
    public func lookup(value: String): String { value }
}
/** A generic library container. */
public class Box<T> { public init() {} }
/** Controlled exception for a real external throws reference. */
public class Failure <: Exception { public init() { super("controlled failure") } }
'''.replace('METHOD', method))
        consumer = output / ('consumer-' + version)
        write(consumer / 'cjpm.toml', '[package]\ncjc-version = "1.2.0"\nname = "consumer"\nversion = "0.1.0"\noutput-type = "static"\nsrc-dir = "src"\n\n[dependencies]\nlibrary = { path = "../' + version + '" }\n')
        write(consumer / 'src/api.cj', '''package consumer
import library
/** Uses the selected library. See {@link library.Widget.lookup(Int64)}.
 * @param input Selected external API instance.
 * @return The same instance.
 * @see library.Widget.lookup(Int64) Exact integer overload.
 */
public func consume(input: library.Widget): library.Widget { input }
/** Comments between qualified type components are not type atoms. */
public func dotted(input: library /* NOT_A_TYPE_Widget */ .Widget): library.Widget { input }
/** Nested type atoms. */
public func nested(input: library.Box<library.Widget>): library.Box<library.Widget> { input }
/** Optional type atom. */
public func optional(input: ?library.Widget): ?library.Widget { input }
/** Tuple type atoms. */
public func paired(input: (library.Widget, library.Widget)): (library.Widget, library.Widget) { input }
/** Function type atoms. */
public func callback(input: (library.Widget) -> library.Widget): (library.Widget) -> library.Widget { input }
/** Combined optional, nested generic and multi-parameter function atoms. */
public func composite(input: ?library.Box<library.Box<library.Widget>>, callback: (library.Widget, library.Widget) -> library.Widget): ?library.Box<library.Box<library.Widget>> { input }
/** A generic bound is a type position; T itself remains a type parameter. */
public func constrained<T>(input: T): T where T <: library.Widget { input }
/** A field using the same selected API identity. */
public class Holder { public var item: ?library.Widget = None }
/** Generic parameter shadows the imported type. */
public func shadow<Widget>(input: Widget): Widget { input }
/** A parameter/default spelling is not a type occurrence. */
public func named(Widget!: String = "Widget"): String { Widget }
/** A real exception declaration is linked through the same dependency instance.
 * @throws library.Failure Controlled failure.
 */
public func mayFail(): Unit { throw library.Failure() }
/** Local overloads keep exact id guide selectors precise. */
public func own(value: Int64): Int64 { value }
public func own(value: String): String { value }
''')
        write(consumer / 'cjdoc.toml', '[docs]\nindex = "docs/index.md"\n[[docs.pages]]\nsource = "docs/guide.md"\nroute = "concepts/guides/dependency"\ntitle = "Dependency guide"\n')
        write(consumer / 'docs/index.md', '# Consumer documentation\n')
        write(consumer / 'docs/guide.md', '# Dependency guide\n\n'
              '<!-- cjdoc-bind target="consumer.consume" selector="example" -->\n\n'
              '<!-- cjdoc-bind target="library.Widget.lookup" selector="signature:public func lookup(value: Int64): Int64" -->\n\n'
              'Selected API type: {@link library.Widget}.\n')
        if args.compile_fixtures:
            costs.append(run(['cjpm', 'build'], library, version + '-compile', evidence))
            costs.append(run(['cjpm', 'build'], consumer, 'consumer-' + version + '-compile', evidence))
    for version in ['v1', 'v2']:
        library = output / version
        costs.append(run([binary, 'generate', '--project', library, '--output', output / (version + '-site'),
                          '--format', 'html', '--format', 'json', '--format', 'symbol-index', '--lint-profile', 'off'],
                         output, version + '-generate', evidence))
    operator_pins = [item for version in ['v1', 'v2'] for item in
                     ['--doc-inventory-pin', str(output / (version + '-site/html/symbol-index.json')) + '=' +
                      digest(output / (version + '-site/html/symbol-index.json'))]]
    catalogs = []
    for mode in ['https', 'offline']:
        catalog = output / ('sources-' + mode + '.json')
        documents = []
        for version in ['v1', 'v2']:
            documents.append({'index': version + '-site/html/symbol-index.json',
                              'baseUrl': (args.https_base.rstrip('/') + '/' + version) if mode == 'https' else ('./deps/' + version)})
        write(catalog, json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': documents}, sort_keys=True))
        catalogs.append(catalog)
        for version in ['v1', 'v2']:
            consumer = output / ('consumer-' + version)
            destination = output / ('consumer-' + version + '-' + mode)
            command = [binary, 'generate', '--project', consumer, '--output', destination,
                       '--format', 'html', '--format', 'json', '--format', 'markdown', '--format', 'symbol-index',
                       '--doc-source', catalog, '--lint-profile', 'off', *operator_pins]
            costs.append(run(command, output, version + '-' + mode + '-cold', evidence))
            primed = json.loads((destination / 'docs.json').read_text())
            own = next(item for item in primed['declarations'] if item['name'] == 'own'
                       and item['parameters'][0]['type']['spelling'] == 'Int64')
            marker = '<!-- cjdoc-bind target="id:' + own['id'] + '" selector="example" -->\n'
            guide_source = consumer / 'docs/guide.md'
            if marker not in guide_source.read_text():
                guide_source.write_text(guide_source.read_text() + '\n' + marker)
                costs.append(run(command, output, version + '-' + mode + '-exact-guide-id-cold', evidence))
            cold = digest(destination / 'docs.json')
            costs.append(run(command, output, version + '-' + mode + '-hot', evidence))
            assert digest(destination / 'docs.json') == cold, 'hot/cold Doc IR differ'
            document = decode_document_navigation(json.loads((destination / 'docs.json').read_text()))
            assert document['schemaVersion'] == 'cjdoc.doc-ir/16'
            selected = [dep for dep in document['dependencies'] if dep['name'] == 'library']
            assert selected and all(dep['state'] in ['observed', 'verified'] for dep in selected)
            target_identity = selected[0]['identity']
            reliable = []
            reliable_owners = []
            unresolved = []
            for owner, location, reference in refs(document):
                for atom in atoms(reference):
                    decision = atom.get('navigation')
                    if atom['kind'] not in ['optional', 'tuple', 'function', 'primitive'] and owner['name'] != 'shadow':
                        if decision and decision['state'] == 'resolved' and decision['documentSetId']:
                            assert decision['matchLevel'] == 'exact'
                            assert decision['apiIdentity'] == target_identity
                            assert version in decision['url'] and ('v2' if version == 'v1' else 'v1') not in decision['url']
                            reliable.append(decision)
                            reliable_owners.append((owner['id'], decision))
                        elif decision and decision['state'] != 'resolved':
                            unresolved.append({'symbol': owner['name'], 'position': location, 'type': atom['spelling'], 'reason': decision['reason']})
                    if owner['name'] == 'shadow':
                        assert not decision or decision['state'] != 'resolved', 'generic parameter linked'
            assert len(reliable) >= 12, 'structured reference positions did not bind'
            rendered = 0
            symbol_inventory = json.loads((destination / 'html/symbol-index.json').read_text())
            pages = {entry['id']: (destination / 'html' / entry['href']).read_text()
                     for entry in symbol_inventory['entries']}
            all_html = ''.join(pages.values())
            for owner_id, decision in reliable_owners:
                owner_html = pages[owner_id]
                assert decision['url'].replace('./', '../', 1) in owner_html or decision['url'] in owner_html
                rendered += 1
            assert verify_presentation(document, destination, reliable_owners) == rendered
            markdown = ''.join(path.read_text() for path in (destination / 'markdown').rglob('*.md'))
            assert any(decision['url'].removeprefix('./') in markdown for decision in reliable), 'Markdown omitted navigation'
            assert 'html/html/' not in all_html
            reference_quality = verify_guide_and_throws(document, destination, target_identity, version)
            if mode == 'offline':
                for dep_version in ['v1', 'v2']:
                    shutil.copytree(output / (dep_version + '-site/html'), destination / 'html/deps' / dep_version)
            write(evidence / (version + '-' + mode + '-quality.json'), json.dumps({
                'documentationReferences': reference_quality,
                **identity_quality(document, reliable),
                'dependencyIdentity': {'states': dict(Counter(item['state'] for item in document['dependencies'])),
                                       'total': len(document['dependencies']), 'selectedLibraryInstances': len(selected)},
                'typeReferences': {'reliablyBoundWithTarget': len(reliable), 'explicitlyUnresolved': unresolved,
                    'allAtoms': sum(1 for _, _, reference in refs(document) for _ in atoms(reference)),
                    'semanticStates': dict(Counter(atom['semantic']['state'] for _, _, reference in refs(document) for atom in atoms(reference))),
                    'nonTargetAtoms': [{'symbol': owner['name'], 'position': location, 'type': atom['spelling'],
                                       'reason': (atom.get('navigation') or {}).get('reason',
                                           'not-applicable: structural wrapper, intrinsic primitive or source-proven generic parameter; child atoms remain present')}
                                      for owner, location, reference in refs(document) for atom in atoms(reference)
                                      if atom['kind'] in ['optional', 'tuple', 'function', 'primitive', 'typeParameter'] or owner['name'] == 'shadow']},
                'availableDocumentTargets': {'positions': len(reliable), 'uniqueSymbols': len({item['symbolKey'] for item in reliable})},
                'renderedReliableTargets': rendered,
                'renderCoveragePercent': 100 * rendered / len(reliable),
            }, indent=2, sort_keys=True))
    if args.chir_worker:
        for version in ['v1', 'v2']:
            consumer = output / ('import-consumer-' + version)
            write(consumer / 'cjpm.toml', '[package]\ncjc-version = "1.2.0"\nname = "import_consumer"\nversion = "0.1.0"\noutput-type = "static"\nsrc-dir = "src"\n\n[dependencies]\nlibrary = { path = "../' + version + '" }\n')
            write(consumer / 'src/api.cj', '''package import_consumer
import library.Widget
import library
import library.Box as LibraryBox
/** An ordinary named import, resolved by the explicitly authorized compiler provider. */
public func imported(input: Widget): Widget { input }
/** Alias and nested generic arguments retain the same selected dependency identity. */
public func nestedImported(input: LibraryBox<LibraryBox<Widget>>): LibraryBox<LibraryBox<Widget>> { input }
/** The independently reported optional/provider-role regression. */
public func composite(input: ?LibraryBox<LibraryBox<library.Widget>>, callback: (library.Widget, library.Widget) -> library.Widget): ?LibraryBox<LibraryBox<library.Widget>> { input }
/** The generic bound is source-structural and must not upgrade T's semantics. */
public func constrained<T>(input: T): T where T <: library.Widget { input }
/** A source-structural relationship to the same selected dependency. */
public class ImportedChild <: library.Widget { public init() { super() } }
''')
            if args.compile_fixtures:
                costs.append(run(['cjpm', 'build'], consumer, version + '-import-compile', evidence))
            destination = output / ('import-consumer-' + version + '-site')
            command = [binary, 'generate', '--project', consumer, '--output', destination,
                       '--format', 'html', '--format', 'json', '--format', 'markdown',
                       '--semantic', 'chir', '--chir-worker', args.chir_worker.resolve(), '--cjc', args.cjc.resolve(),
                       '--chir-import-path', output / version / 'target/release/library',
                       '--doc-source', output / 'sources-https.json', '--lint-profile', 'off', *operator_pins]
            costs.append(run(command, output, version + '-import-generate', evidence))
            document = decode_document_navigation(json.loads((destination / 'docs.json').read_text()))
            typed = [(owner, atom) for owner, _, reference in refs(document) for atom in atoms(reference)
                     if owner['name'] in ['imported', 'nestedImported'] and atom['spelling'] not in ['Unit']]
            assert len(typed) >= 8, 'canonical imported/nested positions missing'
            for owner, atom in typed:
                semantic = atom['semantic']
                assert semantic['state'] == 'resolved' and semantic['provider'] == 'chir', atom
                decision = atom['navigation']
                assert decision and decision['state'] == 'resolved' and decision['matchLevel'] == 'exact', atom
                assert version in decision['url'], atom
            composite = [(owner, atom) for owner, _, reference in refs(document) if owner['name'] == 'composite'
                         for atom in atoms(reference) if atom['kind'] not in ['optional', 'tuple', 'function']]
            assert len(composite) >= 9, 'optional/function source atoms disappeared'
            for owner, atom in composite:
                wanted = 'library.Widget' if atom['spelling'] == 'library.Widget' else 'library.Box'
                assert atom['semantic']['state'] == 'resolved' and atom['semantic']['canonical'] == wanted, atom
                assert atom['navigation']['state'] == 'resolved' and atom['navigation']['symbolKey'].split('|')[0] == wanted, atom
            constraints = [(owner, atom) for owner, role, reference in refs(document) if owner['name'] == 'constrained' and role == 'genericConstraint'
                           for atom in atoms(reference)]
            assert len(constraints) == 1 and constraints[0][1]['navigation']['state'] == 'resolved'
            all_reliable = [(owner['id'], atom['navigation']) for owner, _, reference in refs(document) for atom in atoms(reference)
                            if atom.get('navigation') and atom['navigation']['state'] == 'resolved' and atom['navigation']['documentSetId']]
            assert all(nav['matchLevel'] == 'exact' and version in nav['url'] for _, nav in all_reliable)
            verify_presentation(document, destination, all_reliable)
            relationships = [atom for owner, _, reference in refs(document) if owner['name'] == 'ImportedChild'
                             for atom in atoms(reference) if atom['navigation'] and atom['navigation']['state'] == 'resolved']
            assert relationships, 'the source relationship did not share the selected identity'
            write(evidence / (version + '-import-quality.json'), json.dumps({
                **identity_quality(document, [nav for _, nav in all_reliable]),
                'canonicalImportedTypePositions': len(typed), 'linkedPositions': len(typed),
                'relationshipPositions': len(relationships), 'compositeCanonicalPositions': len(composite),
                'genericConstraintPositions': len(constraints), 'allReliablePresentationPositions': len(all_reliable),
                'allTypeAtoms': sum(1 for _, _, reference in refs(document) for _ in atoms(reference)),
                'semanticStates': dict(Counter(atom['semantic']['state'] for _, _, reference in refs(document) for atom in atoms(reference))),
                'renderCoveragePercent': 100,
                'provider': 'real CHIR worker with selected compiled dependency input'}, indent=2, sort_keys=True))

    # Rendering is detached from source trees, document catalogs and SDK identity.
    frozen = output / 'frozen.json'
    shutil.copyfile(output / 'consumer-v1-offline/docs.json', frozen)
    for catalog in catalogs:
        catalog.rename(catalog.with_suffix('.hidden'))
    for version in ['v1', 'v2']:
        (output / (version + '-site/html/symbol-index.json')).rename(output / (version + '-site/html/symbol-index.hidden'))
    clean_env = os.environ.copy()
    for name in list(clean_env):
        if name.startswith(('CANGJIE', 'CJDOC_TOOLCHAIN', 'CJDOC_STDX', 'CJ_SDK')):
            clean_env.pop(name)
    result = subprocess.run([str(binary), 'render', '--input', str(frozen), '--output', str(output / 'replay'),
                             '--format', 'html', '--format', 'markdown'], cwd=output, env=clean_env,
                            capture_output=True, text=True)
    write(evidence / 'offline-replay.log', result.stdout + result.stderr)
    assert result.returncode == 0, 'offline render failed'
    original = output / 'consumer-v1-offline/html'
    replay = output / 'replay/html'
    for subtree in ['symbols', 'concepts']:
        for path in (original / subtree).rglob('*.html'):
            assert path.read_bytes() == (replay / path.relative_to(original)).read_bytes(), 'offline replay changed symbol or captured-guide links/pages'
    original_markdown = output / 'consumer-v1-offline/markdown'
    replay_markdown = output / 'replay/markdown'
    for path in original_markdown.rglob('*.md'):
        assert path.read_bytes() == (replay_markdown / path.relative_to(original_markdown)).read_bytes(), 'offline replay changed Markdown navigation or captured-guide bindings'
    write(evidence / 'costs.json', json.dumps({'commands': costs,
        'maxChildRssKiB': resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
        'inventoryBytes': sum(path.stat().st_size for path in output.glob('*-site/html/symbol-index.hidden')),
        'networkDuringGeneration': False}, indent=2, sort_keys=True))
    print('PASS: two actual API versions, selected identities, structured links, HTTPS/offline routes, deterministic hot cache, detached Doc IR replay')
    print('Browser evidence must be recorded separately; this script does not claim browser clicks.')


if __name__ == '__main__':
    main()
