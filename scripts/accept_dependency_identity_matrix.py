#!/usr/bin/env python3
"""Compile isolated fixtures and accept actual dependency identities (Python 3.11+).

Example (SDKs are read-only; every build stays under the new --output directory)::

    python3 scripts/accept_dependency_identity_matrix.py --binary <cjdoc> \
      --sdk-a <installed-sts>/cangjie --sdk-b <installed-prerelease>/cangjie \
      --output <disk-backed-task-temp>/matrix

Optional --stdx-a/--stdx-b select the actual stdx import directories. Otherwise
only the selected wrapper's whitelisted CJ_SDK_LIBPATH is inspected. No SDK is
modified, no environment is dumped, and no shared repository target is built.
Generated source inventories supply all symbol routes. Receipts observe inputs;
separate successful compiler commands provide build evidence, not attestation.
A rejected combined workspace is reported as unsupported, never as co-compilable;
independent targets remain mandatory. Failures retain minimized fixture inputs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from document_navigation import decode_navigation


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def load(path):
    return json.loads(path.read_text(encoding='utf-8'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def navigations(value):
    if isinstance(value, dict):
        if value.get('navigation'):
            yield decode_navigation(value['navigation'])
        for child in value.values():
            yield from navigations(child)
    elif isinstance(value, list):
        for child in value:
            yield from navigations(child)


class Matrix:
    def __init__(self, args):
        self.args = args
        self.repo = Path(__file__).resolve().parents[1]
        self.root = args.output.resolve()
        if self.root.exists():
            raise ValueError('--output must be a new task-private directory')
        self.root.mkdir(parents=True, mode=0o700)
        self.logs = self.root / 'evidence'
        self.logs.mkdir()
        self.temp = self.root / 'tmp'
        self.temp.mkdir(mode=0o700)
        self.env = os.environ.copy()
        self.env.update(PYTHONDONTWRITEBYTECODE='1', DISABLE_ZOXIDE='1',
                        TMPDIR=str(self.temp), TMP=str(self.temp), TEMP=str(self.temp))
        self.commands = []
        self.cases = []
        self.observations = {}
        self.sdk = {}
        self.counter = 0

    def run(self, name, command, cwd=None, allow_failure=False):
        start = time.monotonic()
        result = subprocess.run([str(item) for item in command], cwd=cwd or self.root,
                                env=self.env, capture_output=True, text=True, timeout=240)
        # Logs are sanitized too: they may be copied into a public issue later.
        text = result.stdout + result.stderr
        replacements = [(str(self.root), '<matrix>'), (str(self.repo), '<repo>'),
                        (str(Path.home()), '$HOME')]
        for original, portable in sorted(replacements, key=lambda item: -len(item[0])):
            text = text.replace(original, portable)
        write(self.logs / (name + '.log'), text)
        self.commands.append({'name': name, 'exitCode': result.returncode,
                              'seconds': round(time.monotonic() - start, 4)})
        if result.returncode and not allow_failure:
            raise RuntimeError(f'{name}: exit {result.returncode}; see evidence/{name}.log')
        return result

    def wrapped(self, label, command):
        return [self.args.wrapper, '--sdk-root', self.sdk[label]['root'], *command]

    def case(self, name, function):
        try:
            detail = function() or {}
            self.cases.append({'case': name, 'state': 'passed', **detail})
        except (AssertionError, RuntimeError, ValueError, StopIteration, KeyError) as error:
            self.cases.append({'case': name, 'state': 'failed', 'reason': str(error)})

    def select_sdk(self, label, selected, stdx):
        # Deliberately print only these three variables, never env/print-env.
        probe = ('import json,os,shutil; print(json.dumps({"root":os.environ.get("CANGJIE_HOME", ""),'
                 '"sdkRoot":os.environ.get("CANGJIE_SDK_ROOT", ""),'
                 '"libpath":os.environ.get("CJ_SDK_LIBPATH", ""),'
                 '"cjc":shutil.which("cjc"),"cjpm":shutil.which("cjpm")}))')
        result = self.run('sdk-' + label + '-selection',
                          [self.args.wrapper, '--sdk-root', selected, sys.executable, '-c', probe])
        observed = json.loads(result.stdout)
        root = Path(observed['root']).resolve(strict=True)
        compiler = Path(observed['cjc']).resolve(strict=True)
        assert compiler.is_relative_to(root), 'wrapper compiler escaped explicit SDK selection'
        candidates = [Path(part) for part in observed['libpath'].split(os.pathsep) if part]
        imports = Path(stdx).resolve(strict=True) if stdx else next(
            path.resolve() for path in candidates if (path / 'stdx.encoding.json.cjo').is_file())
        standard = root / 'modules' / self.args.module_target / 'std/std.collection.cjo'
        assert standard.is_file(), 'selected SDK lacks requested target standard-library artifact'
        self.sdk[label] = {'root': root, 'cjc': compiler, 'std': standard,
                           'stdx': imports / 'stdx.encoding.json.cjo', 'imports': imports}
        result = self.run('sdk-' + label + '-version', self.wrapped(label, ['cjc', '-v']))
        return {'compilerVersionOutput': result.stdout.strip(), 'selection': 'installed wrapper observation',
                'releaseAuthentication': 'none', 'compilerSha256': sha(compiler),
                'stdSha256': sha(standard), 'stdxSha256': sha(imports / 'stdx.encoding.json.cjo')}

    def package(self, path, name, source, dependencies=None, version='1.0.0', sdk='a', organization=''):
        path.mkdir(parents=True)
        self.counter += 1
        self.run(f'init-{self.counter}', self.wrapped(sdk, ['cjpm', 'init', '--name', name, '--type', 'static']), path)
        manifest = ('[package]\ncjc-version = "1.2.0"\nname = ' + json.dumps(name) +
                    '\nversion = ' + json.dumps(version) + '\noutput-type = "static"\nsrc-dir = "src"\n')
        if organization:
            manifest += 'organization = ' + json.dumps(organization) + '\n'
        if dependencies:
            manifest += '\n[dependencies]\n'
            for dep, target in dependencies.items():
                manifest += json.dumps(dep) + ' = { path = ' + json.dumps(os.path.relpath(target, path)) + ' }\n'
        write(path / 'cjpm.toml', manifest)
        # cjpm init's default source would otherwise add unrelated declarations.
        for item in (path / 'src').glob('*.cj'):
            item.unlink()
        package_name = organization + '::' + name if organization else name
        write(path / 'src/api.cj', 'package ' + package_name + '\n' + source)
        return path

    def compile(self, path, name, sdk='a', allow_failure=False):
        return self.run(name, self.wrapped(sdk, ['cjpm', 'build']), path, allow_failure)

    def receipt(self, project, name, inputs=()):
        path = self.root / (name + '-context.json')
        command = [sys.executable, self.repo / 'scripts/capture_build_context.py', '--project', project,
                   '--output', path, '--target', self.args.target]
        for owner, kind, dep, selected in inputs:
            command += ['--dependency', f'{owner}:{kind}:{dep}={selected}']
        self.run(name + '-capture', command)
        return path

    def generate(self, project, name, receipt=None, catalog=None, extra=()):
        destination = self.root / (name + '-site')
        command = [self.args.binary, 'generate', '--project', project, '--output', destination,
                   '--format', 'json', '--format', 'html', '--format', 'symbol-index', '--lint-profile', 'off']
        if receipt:
            command += ['--build-context', receipt]
        if catalog:
            command += ['--doc-source', catalog]
            # This harness is the host authority: it has just compiled/generated
            # these controlled producer files. No publisher-reported digest is trusted.
            for source in load(catalog)['documents']:
                path = catalog.parent / source['index']
                command += ['--doc-inventory-pin', str(path.resolve()) + '=' + sha(path)]
        self.run(name + '-generate', self.wrapped('a', [*command, *extra]))
        document = load(destination / 'docs.json')
        assert document['schemaVersion'] == 'cjdoc.doc-ir/15'
        encoded = json.dumps(document)
        for local in [str(self.root), str(self.repo), *(str(item['root']) for item in self.sdk.values())]:
            assert local not in encoded, 'published Doc IR leaked a local root'
        return document, destination

    def catalog(self, name, sites):
        path = self.root / (name + '-catalog.json')
        documents = [{'index': os.path.relpath(site / 'html/symbol-index.json', self.root),
                      'baseUrl': 'https://docs.example.test/matrix/' + label} for label, site in sites]
        write(path, json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': documents}))
        return path

    @staticmethod
    def dependency(document, owner, name, kind='source'):
        modules = [item['id'] for item in document['modules'] if item['name'] == owner]
        assert len(modules) == 1, f'{owner}: module must be unambiguous'
        matches = [item for item in document['dependencies'] if item['moduleId'] == modules[0]
                   and item['name'] == name and item['kind'] == kind]
        assert len(matches) == 1, f'{owner}/{name}/{kind}: expected exactly one dependency'
        return matches[0]

    def exact_links(self, document, owner, identity, label):
        declarations = [item for item in document['declarations'] if item['packageName'] == owner]
        decisions = [nav for item in declarations for nav in navigations(item)
                     if nav['state'] == 'resolved' and nav['documentSetId']]
        assert len(decisions) >= 2, f'{owner}: external parameter and return links missing'
        assert all(nav['matchLevel'] == 'exact' and nav['apiIdentity'] == identity
                   and ('/' + label + '/') in nav['url'] for nav in decisions), 'cross-identity external link'
        return len(decisions)

    def ordinary(self):
        libraries = []
        consumers = []
        sites = []
        hashes = []
        for label, marker in [('a', 11), ('b', 29)]:
            library = self.package(self.root / ('library-' + label), 'library',
                '/** Same label, genuinely different implementation. */\npublic class Widget {\n'
                ' public init() {}\n public func value(): Int64 { ' + str(marker) + ' }\n}\n')
            consumer = self.package(self.root / ('consumer-' + label), 'consumer_' + label,
                'import library\n/** Selected ordinary dependency. */\n'
                'public func echo(input: library.Widget): library.Widget { input }\n', {'library': library})
            self.compile(library, 'library-' + label + '-compile')
            self.compile(consumer, 'consumer-' + label + '-compile')
            artifacts = sorted((library / 'target').rglob('*.a'))
            assert artifacts, 'no real compiled static library artifact'
            hashes.append([sha(path) for path in artifacts])
            context = self.receipt(library, 'library-' + label)
            _, site = self.generate(library, 'library-' + label, context)
            sites.append((label, site))
            libraries.append(library)
            consumers.append(consumer)
        assert hashes[0] != hashes[1], 'same-version compiled artifact bytes unexpectedly identical'
        catalog = self.catalog('ordinary', sites)
        self.libraries, self.consumers, self.ordinary_catalog = libraries, consumers, catalog
        identities = []
        count = 0
        for label, consumer in zip(['a', 'b'], consumers):
            context = self.receipt(consumer, 'consumer-' + label)
            document, _ = self.generate(consumer, 'consumer-' + label, context, catalog)
            dep = self.dependency(document, 'consumer_' + label, 'library')
            assert dep['state'] == 'verified' and dep['version'] == '1.0.0'
            identities.append(dep['identity'])
            count += self.exact_links(document, 'consumer_' + label, dep['identity'], label)
        assert identities[0] != identities[1], 'different same-version source bytes collapsed'
        return {'versionLabel': '1.0.0', 'sourceIdentities': identities,
                'compiledArtifactSha256': hashes, 'exactPositions': count,
                'actualIndependentTargetCompiles': 4}

    def sdk_matrix(self, label):
        selected = self.sdk[label]
        official = self.root / ('official-' + label)
        self.run('official-' + label + '-prepare', [sys.executable, self.repo / 'scripts/prepare_official_inventory.py',
            '--manifest', self.repo / 'tests/fixtures/external_docs/official83/manifest.json',
            '--bundle', self.repo / 'tests/fixtures/external_docs/official83',
            '--output', official / 'symbol-index.json', '--html-output', official / 'pages'])
        inventory = load(official / 'symbol-index.json')
        project = self.package(self.root / ('sdk-consumer-' + label), 'sdk_consumer',
            'import std.collection as selectedStd\nimport stdx.encoding.json as selectedStdx\n'
            '/** Actual selected std input. */\n'
            'public func deque(input: selectedStd.ArrayDeque<Int64>): selectedStd.ArrayDeque<Int64> { input }\n'
            '/** Actual selected stdx input. */\n'
            'public func json(input: selectedStdx.JsonArray): selectedStdx.JsonArray { input }\n', sdk=label)
        with (project / 'cjpm.toml').open('a', encoding='utf-8') as output:
            output.write('\n[target.' + self.args.target + '.bin-dependencies]\npath-option = [' +
                         json.dumps(str(selected['imports'])) + ']\n')
        self.compile(project, 'sdk-' + label + '-actual-compile', label)
        inputs = [('sdk_consumer', kind, kind, selected[key])
                  for kind, key in [('std', 'std'), ('stdx', 'stdx'), ('toolchain', 'cjc')]]
        context = self.receipt(project, 'sdk-' + label, inputs)
        self.observations['sdk-' + label] = {'actualTargetCompile': 'passed',
            'receipt': context.name, 'releaseAuthentication': 'none'}
        record = load(context)
        mappings = []
        for dep in record['modules'][0]['dependencies']:
            if dep['kind'] not in ['std', 'stdx']:
                continue
            target = next(item for item in inventory['documentSets'] if item['library'] == dep['name'])
            mappings.append({'fromIdentity': dep['identity'], 'toIdentity': target['identity'],
                'target': self.args.target, 'cfg': '',
                'evidence': 'User-scoped pinned documented-symbol mapping; compiled consumer; not release/API/ABI attestation'})
        catalog = self.root / ('sdk-' + label + '-catalog.json')
        write(catalog, json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': [
            {'index': official.name + '/symbol-index.json', 'baseUrl': './' + official.name + '/pages', 'compatibilityMappings': mappings}]}))
        document, _ = self.generate(project, 'sdk-' + label, context, catalog,
                                    ['--link-compatible', '--link-language', 'en'])
        components = {kind: self.dependency(document, 'sdk_consumer', kind, kind)
                      for kind in ['std', 'stdx', 'toolchain']}
        assert all(item['state'] == 'verified' for item in components.values())
        assert all(not item['version'] for item in components.values()), 'installed bytes invented release versions'
        assert not document['generator']['toolchain'], 'generator SDK provenance was fabricated'
        decisions = [nav for nav in navigations(document) if nav['documentSetId']]
        assert len(decisions) >= 4 and all(nav['state'] == 'resolved' and nav['matchLevel'] == 'compatible'
            and nav['apiIdentity'].startswith('official-doc-source:') for nav in decisions), 'SDK source-reference mapping was lost or promoted to exact'
        # Identical std/stdx bytes across installations are not invented differences.
        return {'observedIdentities': {kind: item['identity'] for kind, item in components.items()},
                'actualTargetCompiles': 1, 'generatorSdkPropagation': 'none',
                'sourceReferenceMapping': 'explicit compatible, never exact', 'releaseAuthentication': 'none'}

    def workspace(self):
        workspace = self.root / 'workspace'
        workspace.mkdir()
        members = []
        independently_selected = []
        # Prove each standalone build context before introducing a workspace
        # combination that the selected cjpm may explicitly reject.
        for label, library in zip(['a', 'b'], self.libraries):
            member = self.package(workspace / ('member-' + label), 'member_' + label,
                'import library\n/** Member-local selected API. */\n'
                'public func echo(input: library.Widget): library.Widget { input }\n', {'library': library})
            self.compile(member, 'workspace-' + label + '-independent-compile')
            context = self.receipt(member, 'workspace-' + label + '-independent')
            single, _ = self.generate(member, 'workspace-' + label + '-independent', context, self.ordinary_catalog)
            selected = self.dependency(single, 'member_' + label, 'library')
            assert selected['state'] == 'verified', 'actual standalone member selection was not observed'
            self.exact_links(single, 'member_' + label, selected['identity'], label)
            independently_selected.append(selected['identity'])
            members.append(member.name)
        assert independently_selected[0] != independently_selected[1], 'standalone selected identities collapsed'
        write(workspace / 'cjpm.toml', '[workspace]\nmembers = ' + json.dumps(members) +
              '\nbuild-members = ' + json.dumps(members) + '\n')
        combined = self.compile(workspace, 'workspace-combined-compile', allow_failure=True)
        if combined.returncode:
            assert 'dependency tree are conflicted' in combined.stdout + combined.stderr, 'combined workspace failed for a reason other than unsupported same-name dependency selection'
        compile_state = 'supported' if combined.returncode == 0 else 'unsupported by selected real cjpm; standalone members compiled and linked before workspace composition'
        self.observations['workspace'] = {'combinedWorkspaceCompile': compile_state,
            'combinedExitCode': combined.returncode, 'independentMemberCompiles': 2}
        context = self.receipt(workspace, 'workspace')
        document, _ = self.generate(workspace, 'workspace', context, self.ordinary_catalog)
        dependencies = [self.dependency(document, 'member_' + label, 'library') for label in ['a', 'b']]
        if combined.returncode == 0:
            assert all(dep['state'] == 'verified' for dep in dependencies), 'supported workspace graph observation collided'
            assert dependencies[0]['identity'] != dependencies[1]['identity'], 'supported workspace selections collapsed'
            for label, dep in zip(['a', 'b'], dependencies):
                self.exact_links(document, 'member_' + label, dep['identity'], label)
        else:
            assert any(dep['state'] == 'conflict' for dep in document['dependencies']), 'unsupported same-name graph composition must retain its conflicting component'
            assert all(dep['state'] != 'verified' for dep in dependencies), 'rejected combined receipt must not authenticate member selections'
            assert any(item['code'] in {'CJDOC2300', 'CJDOC2301'} for item in document['diagnostics']), 'unsupported graph must explain rejected context or conflicting selections'
            assert not any(nav['state'] == 'resolved' and nav['documentSetId'] for nav in navigations(document)), 'unsupported combined build must not invent an exact selected dependency'
        return {'combinedWorkspaceCompile': compile_state, 'combinedExitCode': combined.returncode,
                'independentMemberCompiles': 2, 'independentMemberSelections': independently_selected,
                'sameNameDependencyIsolation': 'standalone exact matches; unsupported composition explicitly rejected' if combined.returncode else 'supported workspace exact matches'}

    def transitive(self):
        result = []
        bridge_identities = []
        for label, original in zip(['a', 'b'], self.libraries):
            scope = self.root / ('transitive-scope-' + label)
            library = scope / 'library'
            library.mkdir(parents=True)
            shutil.copyfile(original / 'cjpm.toml', library / 'cjpm.toml')
            shutil.copytree(original / 'src', library / 'src')
            bridge = self.package(scope / 'bridge', 'bridge',
                'import library\n/** Transitive owner. */\n'
                'public func echo(input: library.Widget): library.Widget { input }\n', {'library': library})
            top = self.package(scope / 'top', 'top',
                'import bridge\n/** Transitive selection must not become a direct dependency. */\n'
                'public func value(): Int64 { 1 }\n', {'bridge': bridge})
            self.compile(top, 'transitive-' + label + '-compile')
            context = self.receipt(top, 'transitive-' + label)
            document, _ = self.generate(top, 'transitive-' + label, context, self.ordinary_catalog,
                                        ['--include-path-dependencies'])
            selected = self.dependency(document, 'bridge', 'library')
            bridge_identities.append(self.dependency(document, 'top', 'bridge')['identity'])
            assert selected['state'] == 'verified'
            root = next(item['id'] for item in document['modules'] if item['name'] == 'top')
            assert not any(item['moduleId'] == root and item['name'] == 'library' for item in document['dependencies']), 'transitive selection leaked to root'
            # Included declarations may link locally, but never select the other inventory.
            wrong = 'b' if label == 'a' else 'a'
            assert not any('/' + wrong + '/' in nav['url'] for nav in navigations(document)
                           if nav['state'] == 'resolved' and nav['documentSetId']), 'transitive cross-target link'
            result.append(selected['identity'])
        assert bridge_identities[0] == bridge_identities[1], 'fixture must have identical bridge source/manifest/lock bytes'
        assert result[0] != result[1], 'independent transitive selections collapsed'
        return {'actualTargetCompiles': 2, 'selectedIdentities': result, 'rootPropagation': 'none',
                'identicalBridgeSourceIdentity': bridge_identities[0]}

    def organization_alias(self):
        libraries, consumers, contexts, sites, identities = [], [], [], [], []
        for label, version, value in [('a', '1.0.0', 11), ('b', '2.0.0', 29)]:
            library = self.package(self.root / ('org-library-' + label), 'library',
                'public class Widget { public init() {}\n public func value(): Int64 { ' + str(value) + ' } }\n',
                version=version, organization='cjdoc')
            consumer = self.package(self.root / ('org-consumer-' + label), 'org_consumer',
                'import cjdoc::library as remote\n/** {@link cjdoc::library.Widget}. */\n'
                'public func echo(value: remote.Widget): remote.Widget { value }\n', {'cjdoc::library': library})
            self.compile(consumer, 'organization-' + label + '-compile')
            context = self.receipt(library, 'organization-producer-' + label)
            producer, site = self.generate(library, 'organization-producer-' + label, context,
                                          extra=['--doc-version', 'docs-build-' + label])
            own_sources = [item for item in producer['dependencies'] if item['kind'] == 'source'
                           and item['componentModuleId'] == item['moduleId']]
            assert len(own_sources) == 1, 'producer must have one actual source root'
            selected = own_sources[0]
            metadata = next(item for item in load(site / 'html/symbol-index.json')['documentSets']
                            if item['moduleId'] == selected['moduleId'])
            assert metadata['library'] == 'cjdoc::library'
            assert metadata['apiVersion'] == version and metadata['documentationRevision'] == 'docs-build-' + label
            assert producer['documentationRevision'] == 'docs-build-' + label
            libraries.append(library); consumers.append(consumer); sites.append(site); identities.append(selected['identity'])
            contexts.append(self.receipt(consumer, 'organization-consumer-' + label))
        only_a = self.catalog('organization-only-a', [('organization-a', sites[0])])
        first, _ = self.generate(consumers[0], 'organization-a-exact', contexts[0], only_a,
                                 ['--doc-version', 'consumer-display-not-api'])
        assert self.exact_links(first, 'org_consumer', identities[0], 'organization-a') >= 2
        wrong, _ = self.generate(consumers[1], 'organization-b-no-neighbour', contexts[1], only_a)
        assert not any(nav['state'] == 'resolved' and nav['documentSetId'] for nav in navigations(wrong)), 'organization scope became a documentation-only wrong-version fallback'
        both = self.catalog('organization-both', [('organization-a', sites[0]), ('organization-b', sites[1])])
        second, _ = self.generate(consumers[1], 'organization-b-exact', contexts[1], both)
        assert self.exact_links(second, 'org_consumer', identities[1], 'organization-b') >= 2
        selected = self.dependency(second, 'org_consumer', 'cjdoc::library')
        policy = load(only_a)
        policy['documents'][0]['compatibilityMappings'] = [{
            'fromIdentity': selected['identity'], 'toIdentity': identities[0], 'target': self.args.target, 'cfg': '',
            'evidence': 'controlled matching class signatures; explicit reference mapping only, no ABI or behavior attestation'}]
        compatible_catalog = self.root / 'organization-compatible.json'
        write(compatible_catalog, json.dumps(policy))
        compatible, _ = self.generate(consumers[1], 'organization-b-compatible-a', contexts[1], compatible_catalog,
                                      ['--link-compatible'])
        choices = [nav for nav in navigations(compatible) if nav['documentSetId']]
        assert len(choices) >= 2 and all(nav['state'] == 'resolved' and nav['matchLevel'] == 'compatible'
               and nav['apiIdentity'] == identities[0] and 'documentationRevision=docs-build-a' in nav['reason']
               and 'apiVersion (publisher package declaration)=1.0.0' in nav['reason'] for nav in choices)
        return {'actualConsumerCompiles': 2, 'packageNamespace': 'cjdoc::library', 'sourceAlias': 'remote',
                'wrongVersionDefault': 'plaintext including explicit body reference', 'explicitMapping': 'compatible',
                'apiVersions': ['1.0.0', '2.0.0'], 'documentationRevisions': ['docs-build-a', 'docs-build-b']}

    def closure_selection(self):
        contexts = []
        libraries = []
        consumers = []
        sites = []
        for label, original in zip(['a', 'b'], self.libraries):
            scope = self.root / ('closure-' + label)
            leaf = scope / 'library'
            leaf.mkdir(parents=True)
            shutil.copyfile(original / 'cjpm.toml', leaf / 'cjpm.toml')
            shutil.copytree(original / 'src', leaf / 'src')
            library = self.package(scope / 'carrier', 'carrier',
                'import library\npublic class Carrier { public init() {}\n'
                ' public func echo(value: library.Widget): library.Widget { value } }\n', {'library': leaf})
            consumer = self.package(scope / 'consumer', 'closure_consumer',
                'import carrier\npublic func echo(value: carrier.Carrier): carrier.Carrier { value }\n', {'carrier': library})
            self.compile(consumer, 'closure-' + label + '-compile')
            producer_context = self.receipt(library, 'closure-producer-' + label)
            producer, site = self.generate(library, 'closure-producer-' + label, producer_context)
            contexts.append(self.receipt(consumer, 'closure-consumer-' + label))
            libraries.append(self.dependency(producer, 'carrier', 'carrier')['identity'])
            consumers.append(consumer)
            sites.append(site)
        assert libraries[0] == libraries[1], 'carrier source/manifest/lock must be byte-identical'
        only_a = self.catalog('closure-only-a', [('closure-a', sites[0])])
        selected_a, _ = self.generate(consumers[0], 'closure-a-only-a', contexts[0], only_a)
        selected_b, _ = self.generate(consumers[1], 'closure-b-only-a', contexts[1], only_a)
        assert self.exact_links(selected_a, 'closure_consumer', libraries[0], 'closure-a') >= 2
        assert not any(nav['state'] == 'resolved' and nav['documentSetId'] for nav in navigations(selected_b)), 'different transitive input reused old documentation'
        edge_a = self.dependency(selected_a, 'closure_consumer', 'carrier')
        edge_b = self.dependency(selected_b, 'closure_consumer', 'carrier')
        assert edge_a['identity'] == edge_b['identity'] and edge_a['instanceId'] != edge_b['instanceId']
        both = self.catalog('closure-both', [('closure-a', sites[0]), ('closure-b', sites[1])])
        rebound_b, _ = self.generate(consumers[1], 'closure-b-both', contexts[1], both)
        assert self.exact_links(rebound_b, 'closure_consumer', libraries[1], 'closure-b') >= 2
        return {'actualConsumerCompiles': 2, 'unchangedCarrierSourceIdentity': libraries[0],
                'differentScopedInstances': [edge_a['instanceId'], edge_b['instanceId']],
                'onlyWrongClosure': 'plaintext', 'bothClosures': 'correct unique exact target'}

    def git_dirty(self):
        checkout = self.root / 'git-fixture'
        self.run('git-fixture-clone', ['git', 'clone', '--local', '--no-hardlinks', self.repo, checkout])
        before_head = self.run('git-fixture-head-before', ['git', '-C', checkout, 'rev-parse', 'HEAD']).stdout.strip()
        library = checkout / 'tests/fixtures/projects/basic'
        write(library / 'cjpm.toml', '[package]\ncjc-version = "1.2.0"\nname = "basic"\nversion = "0.1.0"\noutput-type = "static"\nsrc-dir = "src"\n')
        consumer = self.package(self.root / 'git-consumer', 'git_consumer',
            'import basic\npublic func echo(value: basic.Status): basic.Status { value }\n', {'basic': library})
        self.compile(consumer, 'git-source-before-compile')
        producer_context = self.receipt(library, 'git-producer')
        producer, site = self.generate(library, 'git-producer', producer_context)
        catalog = self.catalog('git-source', [('git-before', site)])
        before_context = self.receipt(consumer, 'git-consumer-before')
        before, _ = self.generate(consumer, 'git-consumer-before', before_context, catalog)
        identity_before = self.dependency(before, 'git_consumer', 'basic')['identity']
        self.exact_links(before, 'git_consumer', identity_before, 'git-before')
        source = library / 'src/api.cj'
        original = source.read_bytes()
        metadata = source.stat()
        source.write_bytes(original + b'\n/** Controlled uncommitted content change. */\npublic func gitDirtyMarker(): Int64 { 7 }\n')
        self.compile(consumer, 'git-source-after-compile')
        os.utime(source, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        after_head = self.run('git-fixture-head-after', ['git', '-C', checkout, 'rev-parse', 'HEAD']).stdout.strip()
        assert before_head == after_head, 'acceptance must not commit the source modification'
        after_context = self.receipt(consumer, 'git-consumer-after')
        after, destination = self.generate(consumer, 'git-consumer-after', after_context, catalog)
        identity_after = self.dependency(after, 'git_consumer', 'basic')['identity']
        assert identity_before != identity_after
        assert not any(nav['state'] == 'resolved' and nav['documentSetId'] for nav in navigations(after)), 'dirty Git source retained an old exact documentation target'
        cold = sha(destination / 'docs.json')
        self.generate(consumer, 'git-consumer-after', after_context, catalog)
        assert sha(destination / 'docs.json') == cold, 'same-mtime dirty source changed between cold and hot generation'
        assert source.stat().st_mtime_ns == metadata.st_mtime_ns
        return {'actualConsumerCompiles': 2, 'unchangedCommit': before_head,
                'sourceIdentities': [identity_before, identity_after], 'sourceMtime': 'restored',
                'oldInventory': 'rejected after byte change', 'releaseAuthentication': 'none'}

    def honesty(self):
        project = self.consumers[0]
        document, _ = self.generate(project, 'explicit-conflict', catalog=self.ordinary_catalog,
            extra=['--dependency-source', 'library=' + str(self.libraries[1])])
        conflict = self.dependency(document, 'consumer_a', 'library')
        assert conflict['state'] == 'conflict', 'explicit and manifest selections silently reconciled'
        assert not any(nav['state'] == 'resolved' and nav['documentSetId'] for nav in navigations(document))
        # An explicit version claim cannot override the observed manifest bytes.
        false_version = '2.0.0-alpha.9+declared.1'
        record = load(self.root / 'consumer-a-context.json')
        selected_module = next(item for item in record['modules'] if item['name'] == 'consumer_a')
        selected_module['dependencies'][0]['version'] = false_version
        false_context = self.root / 'declared-version-conflict-context.json'
        write(false_context, json.dumps(record))
        observed_conflict, _ = self.generate(project, 'declared-version-conflict', false_context, self.ordinary_catalog)
        selected = self.dependency(observed_conflict, 'consumer_a', 'library')
        assert selected['state'] == 'conflict' and selected['identity'] and selected['version'] == false_version
        assert not any(nav['state'] == 'resolved' and nav['documentSetId'] for nav in navigations(observed_conflict))
        prerelease = '1.3.0-alpha.7+matrix.2'
        library = self.package(self.root / 'prerelease-library', 'library',
            '/** Prerelease declaration, not authenticated release provenance. */\n'
            'public class Widget { public init() {} }\n', version=prerelease)
        consumer = self.package(self.root / 'prerelease-consumer', 'preview_consumer',
            'import library\n/** Preview dependency. */\n'
            'public func echo(input: library.Widget): library.Widget { input }\n', {'library': library})
        compiled = self.compile(consumer, 'prerelease-compile', allow_failure=True)
        if compiled.returncode:
            assert 'version' in compiled.stdout + compiled.stderr, 'prerelease rejected for an unexpected reason'
        context = self.receipt(consumer, 'prerelease')
        document, _ = self.generate(consumer, 'prerelease', context)
        dep = self.dependency(document, 'preview_consumer', 'library')
        assert dep['state'] == 'verified' and dep['version'] == prerelease, 'prerelease version was normalized or promoted'
        declaration = self.package(self.root / 'declaration-only', 'declaration_only',
            '/** No actual dependency selection supplied. */\npublic func value(): Int64 { 1 }\n')
        with (declaration / 'cjpm.toml').open('a', encoding='utf-8') as output:
            output.write('\n[dependencies]\nlibrary = ' + json.dumps(prerelease) + '\n')
        document, _ = self.generate(declaration, 'declaration-only', catalog=self.ordinary_catalog)
        dep = self.dependency(document, 'declaration_only', 'library')
        assert dep['state'] == 'declared' and dep['version'] == prerelease and not dep['identity']
        assert not any(nav['state'] == 'resolved' and nav['matchLevel'] == 'exact' for nav in navigations(document))
        return {'conflictingSelections': 'conflict, no external links', 'prereleaseVersion': prerelease,
                'prereleaseCompile': 'passed' if not compiled.returncode else 'unsupported by selected real cjpm version syntax; source observation only',
                'observedBytes': 'verified receipt binding, version remains declared; does not imply successful compilation',
                'declarationOnly': 'declared, empty identity; deliberately not compiled'}

    def binary_artifacts(self):
        identities = []
        for label, library in zip(['a', 'b'], self.libraries):
            artifact = library / 'target/release/library'
            assert (artifact / 'library.cjo').is_file() and (artifact / 'liblibrary.a').is_file()
            consumer = self.package(self.root / ('binary-consumer-' + label), 'binary_consumer',
                'import library\n/** Actual selected compiled dependency. */\n'
                'public func echo(input: library.Widget): library.Widget { input }\n')
            with (consumer / 'cjpm.toml').open('a', encoding='utf-8') as output:
                output.write('\n[target.' + self.args.target + '.bin-dependencies]\npath-option = [' +
                             json.dumps(str(artifact)) + ']\n')
            self.compile(consumer, 'binary-' + label + '-compile')
            context = self.receipt(consumer, 'binary-' + label,
                [('binary_consumer', 'binary', 'library', artifact)])
            record = load(context)
            # Binary bytes have no intrinsic release label. This is explicitly a
            # user declaration; the receipt identity still comes from capture.
            record['modules'][0]['dependencies'][0]['version'] = '1.0.0'
            write(context, json.dumps(record))
            selected = record['modules'][0]['dependencies'][0]['identity']
            inventory = load(self.root / ('library-' + label + '-site/html/symbol-index.json'))
            documented = next(item for item in inventory['documentSets'] if item['library'] == 'library')
            mapping = {'fromIdentity': selected, 'toIdentity': documented['identity'],
                'target': self.args.target, 'cfg': '',
                'evidence': 'User-scoped mapping of compiled fixture to its generated source inventory; not authenticated release/API/ABI equivalence'}
            catalog = self.root / ('binary-' + label + '-catalog.json')
            write(catalog, json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': [{
                'index': 'library-' + label + '-site/html/symbol-index.json',
                'baseUrl': 'https://docs.example.test/matrix/' + label, 'compatibilityMappings': [mapping]}]}))
            document, _ = self.generate(consumer, 'binary-' + label, context, catalog, ['--link-compatible'])
            dep = self.dependency(document, 'binary_consumer', 'library', 'binary')
            assert dep['state'] == 'verified' and dep['identity'] == selected and dep['version'] == '1.0.0'
            decisions = [nav for nav in navigations(document) if nav['documentSetId']]
            assert len(decisions) >= 2 and all(nav['state'] == 'resolved' and nav['matchLevel'] == 'compatible'
                and nav['apiIdentity'] == documented['identity'] and '/' + label + '/' in nav['url'] for nav in decisions), 'compiled artifact selection crossed identity or promoted mapping to exact'
            identities.append(selected)
        assert identities[0] != identities[1], 'different compiled artifact bundles collapsed'
        return {'actualBinaryConsumerCompiles': 2, 'artifactIdentities': identities,
                'versionLabel': '1.0.0, user-declared', 'mappingLevel': 'compatible, not exact'}

    def execute(self):
        versions = {}
        for label in ['a', 'b']:
            versions[label] = self.select_sdk(label, getattr(self.args, 'sdk_' + label),
                                               getattr(self.args, 'stdx_' + label))
        assert self.sdk['a']['root'] != self.sdk['b']['root'], 'A/B must select different installed roots'
        self.case('T001-S001-P001-same-label-compiled-independent-targets', self.ordinary)
        assert versions['a']['compilerSha256'] != versions['b']['compilerSha256'], 'SDK A/B compiler bytes are identical'
        self.case('T002a-S002-P002-installed-sdk-a', lambda: self.sdk_matrix('a'))
        self.case('T002b-S002-P002-installed-sdk-b', lambda: self.sdk_matrix('b'))
        if hasattr(self, 'libraries'):
            self.case('T006-S006-P006-actual-compiled-binary-inputs', self.binary_artifacts)
            self.case('T003-S003-P003-workspace-same-name-dependencies', self.workspace)
            self.case('T004-S004-P004-transitive-owner-isolation', self.transitive)
            self.case('T007-S007-P007-unchanged-library-different-transitive-closure', self.closure_selection)
            self.case('T008-S008-P008-dirty-git-same-commit-same-mtime', self.git_dirty)
            self.case('T009-S009-P009-organization-alias-and-independent-document-revision', self.organization_alias)
            self.case('T005-S005-P005-conflict-and-prerelease-honesty', self.honesty)
        else:
            for case in ['binary-artifacts', 'workspace', 'transitive', 'honesty']:
                self.cases.append({'case': case, 'state': 'failed', 'reason': 'ordinary fixture prerequisite failed'})
        # Compiler version text is preserved in full, including prerelease suffixes.
        report = {'schemaVersion': 'cjdoc.identity-matrix-acceptance/1', 'binarySha256': sha(self.args.binary),
                  'sdkObservations': versions, 'cases': self.cases, 'commands': self.commands,
                  'actualFixtureObservations': self.observations,
                  'browserAcceptance': 'not performed', 'sdkWrites': 'none',
                  'scope': 'real fixture compiles; input observation is not authenticated build/release attestation'}
        write(self.root / 'evidence.json', json.dumps(report, indent=2, sort_keys=True) + '\n')
        failed = [item['case'] for item in self.cases if item['state'] != 'passed']
        print(f'{len(self.cases) - len(failed)}/{len(self.cases)} actual identity matrix cases passed')
        for case in self.cases:
            print(case['state'].upper() + ': ' + case['case'] + (': ' + case['reason'] if 'reason' in case else ''))
        return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary', type=Path, default=Path('target/release/bin/main'))
    parser.add_argument('--wrapper', type=Path, default=Path.home() / '.codex/scripts/codex_cangjie_env')
    parser.add_argument('--sdk-a', type=Path, required=True)
    parser.add_argument('--sdk-b', type=Path, required=True)
    parser.add_argument('--stdx-a', type=Path)
    parser.add_argument('--stdx-b', type=Path)
    parser.add_argument('--target', default='x86_64-unknown-linux-gnu')
    parser.add_argument('--module-target', default='linux_x86_64_cjnative',
                        help='installed SDK module-directory target (not the cjpm target triple)')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.wrapper = args.wrapper.resolve(strict=True)
    return Matrix(args).execute()


if __name__ == '__main__':
    sys.exit(main())
