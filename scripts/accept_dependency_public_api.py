#!/usr/bin/env python3
"""Compile an external public-API caller and compare real producer/consumer IR.

Run under the repository's authenticated SDK/stdx environment, after any shared
native gate has finished. --prepare-only writes the caller and fixture sources
but does not invoke compilers or cjdoc. All build/output paths belong to the new
--output directory; existing output roots are never reused or deleted.
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


REPO = Path(__file__).resolve().parents[1]
CALLER = REPO / 'tests/fixtures/projects/dependency_public_api/src/main.cj'
POISON = 'untrusted-generator-sdk-claim'


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(64 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load(path):
    return json.loads(path.read_text(encoding='utf-8'))


def first_difference(left, right, path='$'):
    if type(left) is not type(right):
        return path
    if isinstance(left, dict):
        if left.keys() != right.keys():
            return path + '.keys'
        for key in left:
            difference = first_difference(left[key], right[key], path + '.' + key)
            if difference:
                return difference
    elif isinstance(left, list):
        if len(left) != len(right):
            return path + '.length'
        for index, (a, b) in enumerate(zip(left, right)):
            difference = first_difference(a, b, f'{path}[{index}]')
            if difference:
                return difference
    elif left != right:
        return path
    return None


def navigations(value):
    if isinstance(value, dict):
        navigation = decode_navigation(value.get('navigation'))
        if navigation and navigation['state'] == 'resolved' and navigation['documentSetId']:
            yield navigation
        for child in value.values():
            yield from navigations(child)
    elif isinstance(value, list):
        for child in value:
            yield from navigations(child)


def semantics(value, path='$'):
    result = {}
    if isinstance(value, dict):
        for key, child in value.items():
            if key == 'semantic':
                result[path + '.' + key] = child
            else:
                result.update(semantics(child, path + '.' + key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            result.update(semantics(child, f'{path}[{index}]'))
    return result


def dependency(document, name):
    owner = next(module['id'] for module in document['modules'] if module['role'] == 'root')
    selected = [item for item in document['dependencies'] if item['moduleId'] == owner
                and item['name'] == name and item['kind'] == 'source']
    assert len(selected) == 1, 'expected one root-owned source dependency'
    return selected[0]


class Acceptance:
    def __init__(self, args):
        self.args = args
        self.root = args.output.absolute()
        if self.root.exists() or self.root.is_symlink():
            raise ValueError('--output must be a new task-private directory')
        self.root.mkdir(parents=True, mode=0o700)
        self.evidence = self.root / 'evidence'
        self.evidence.mkdir(mode=0o700)
        self.temporary = self.root / 'tmp'
        self.temporary.mkdir(mode=0o700)
        self.env = os.environ.copy()
        self.env.update(TMPDIR=str(self.temporary), TMP=str(self.temporary), TEMP=str(self.temporary),
                        PYTHONDONTWRITEBYTECODE='1')
        self.runtime_env = self.env.copy()
        self.runtime_env.update(CJDOC_TOOLCHAIN_VERSION=POISON, CJDOC_TOOLCHAIN_TARGET=POISON,
                                CJDOC_TOOLCHAIN_FINGERPRINT=POISON, CJDOC_STDX_DIGEST=POISON)
        self.commands = []
        self.cases = []
        self.binary = args.binary.resolve(strict=True)
        self.binary_digest = sha(self.binary)
        if args.binary_sha256 and self.binary_digest != args.binary_sha256:
            raise ValueError('--binary does not match the explicitly expected complete bytes')
        self.driver = self.root / 'public-caller'
        self.caller_binary = self.driver / "bin/api-consumer"
        self.artifact_pins = []
        self.library_a = self.root / 'library-a'
        self.library_b = self.root / 'library-b'
        self.consumer_a = self.root / 'consumer-a'
        self.consumer_b = self.root / 'consumer-b'
        self.prepare()

    def run(self, name, command, cwd=None, runtime=False):
        started = time.monotonic()
        result = subprocess.run([str(part) for part in command], cwd=cwd or self.root,
                                env=self.runtime_env if runtime else self.env,
                                capture_output=True, text=True, timeout=self.args.timeout)
        text = result.stdout + result.stderr
        for local, portable in sorted([(str(self.root), '<acceptance>'), (str(REPO), '<repo>'),
                                       (str(Path.home()), '$HOME')], key=lambda item: -len(item[0])):
            text = text.replace(local, portable)
        write(self.evidence / (name + '.log'), text)
        self.commands.append({'name': name, 'exitCode': result.returncode,
                              'seconds': round(time.monotonic() - started, 4)})
        if result.returncode:
            raise RuntimeError(f'{name} failed with exit {result.returncode}; see evidence/{name}.log')
        return result

    @staticmethod
    def package(path, name, source, version='1.0.0', dependencies=None):
        manifest = ('[package]\ncjc-version = "1.2.0"\nname = ' + json.dumps(name) +
                    '\nversion = ' + json.dumps(version) + '\noutput-type = "static"\n'
                    'override-compile-option = "-O2"\n')
        if dependencies:
            manifest += '\n[dependencies]\n'
            for library, selected in dependencies.items():
                manifest += json.dumps(library) + ' = { path = ' + json.dumps(str(selected)) + ' }\n'
        write(path / 'cjpm.toml', manifest)
        write(path / 'src/api.cj', 'package ' + name + '\n' + source)

    def prepare(self):
        caller = self.driver / 'src/main.cj'
        caller.parent.mkdir(parents=True)
        shutil.copyfile(CALLER, caller)
        manifest = ('[package]\ncjc-version = "1.2.0"\nname = "dependency_public_api"\n'
                    'version = "0.1.0"\noutput-type = "executable"\noverride-compile-option = "-O2"\n')
        write(self.driver / 'cjpm.toml', manifest)
        for path, value, version in [(self.library_a, 11, '1.0.0'), (self.library_b, 29, '2.0.0')]:
            self.package(path, 'library', '/** Public producer type. */\npublic class Widget {\n'
                         '    public init() {}\n    public func value(): Int64 { ' + str(value) + ' }\n}\n', version)
            write(path / 'cjdoc.toml', '[i18n]\ndefault-language = "en"\nlanguages = ["en"]\n')
        for path, library in [(self.consumer_a, self.library_a), (self.consumer_b, self.library_b)]:
            self.package(path, 'consumer', 'import library\n/** Uses the actual selected producer. */\n'
                         'public func echo(value: library.Widget): library.Widget { value }\n',
                         dependencies={'library': library})
        write(self.root / 'prepared.json', json.dumps({'state': 'prepared', 'verification': 'not run',
              'callerSourceSha256': sha(caller), 'cliBinarySha256': self.binary_digest,
              'cases': ['no-pin', 'host-pinned-exact', 'wrong-pin', 'whole-byte-pin-change',
                        'language-required', 'language-fallback', 'compatible-default-rejected',
                        'compatible-explicit', 'documentation-revision-independent']}, indent=2) + '\n')

    def receipt(self, project, name):
        destination = self.root / (name + '-context.json')
        self.run(name + '-capture', [sys.executable, REPO / 'scripts/capture_build_context.py',
                 '--project', project, '--output', destination, '--target', self.args.target])
        return destination

    def catalog(self, directory, index, mapping=None):
        directory.mkdir()
        copied = directory / 'symbol-index.json'
        shutil.copyfile(index, copied)
        entry = {'index': copied.name, 'baseUrl': 'https://docs.example.test/public-api/library-a'}
        if mapping is not None:
            entry['compatibilityMappings'] = [mapping]
        write(directory / 'cjdoc-documents.json', json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': [entry]}))
        return directory, copied

    def pair(self, name, project, receipt, catalog=None, index=None, pin=None, language='en',
             fallback=False, compatible=False, revision='consumer-publication-a'):
        api_output = self.root / (name + '-api.json')
        cli_output = self.root / (name + '-cli')
        extra = self.root / 'extra-sources'
        self.run(name + '-api', [self.caller_binary, project, api_output, self.binary,
                 receipt or '-', catalog or '-', index if pin is not None else '-', pin or '-',
                 language or '-', str(fallback).lower(), str(compatible).lower(), revision,
                 extra if catalog else '-'], runtime=True)
        command = [self.binary, 'generate', '--project', project, '--output', cli_output,
                   '--format', 'json', '--format', 'html', '--lint-profile', 'off', '--no-cache', '--doc-version', revision]
        if receipt:
            command += ['--build-context', receipt]
        if catalog:
            command += ['--doc-source', catalog, '--doc-source', extra]
        if pin is not None:
            command += ['--doc-inventory-pin', str(index) + '=' + pin]
        if language:
            command += ['--link-language', language]
        if fallback:
            command += ['--link-language-fallback']
        if compatible:
            command += ['--link-compatible']
        self.run(name + '-cli', command, runtime=True)
        api, cli = load(api_output), load(cli_output / 'docs.json')
        difference = first_difference(api, cli)
        assert difference is None, 'public API and CLI Doc IR differ at ' + str(difference)
        assert api['schemaVersion'] == 'cjdoc.doc-ir/16'
        assert any(item["name"] == "echo" for item in api["declarations"]), "preflight/source collection produced no consumer API"
        assert api['documentationRevision'] == revision
        assert api['generator']['toolchain'] == '', 'ambient SDK metadata authenticated an unknown linked parser'
        published = json.dumps(api)
        assert POISON not in published, 'ambient generator SDK claim leaked into target provenance'
        for local in [str(self.root), str(REPO), str(Path.home())]:
            assert local not in published, 'local path leaked into public IR'
        self.cases.append({'case': name, 'state': 'equivalent', 'apiCliCompleteIrEqual': True,
                           'resolvedExternalPositions': len(list(navigations(api))),
                           'apiIrSha256': sha(api_output), 'cliIrSha256': sha(cli_output / 'docs.json')})
        return api

    def compile_caller(self):
        # Snapshot exported packages only. Never build/mutate the shared facade,
        # reuse a cached executable, or import a cjdoc internal helper.
        exports = self.args.public_artifacts.resolve(strict=True)
        snapshot = self.root / "public-artifacts"
        directories = set()
        libraries = set()
        required = {"cjdoc.cjo", "cjdoc.model.cjo", "cjdoc.render.cjo"}
        found = set()
        for source in sorted(exports.rglob("*")):
            relative = source.relative_to(exports)
            if any(part.startswith(".") or part in ("bin", "unittest_bin") for part in relative.parts):
                continue
            if not source.is_file() or source.suffix not in (".cjo", ".a", ".so"):
                continue
            if source.is_symlink():
                raise ValueError("public export inputs must not be symbolic links")
            before = sha(source)
            destination = snapshot / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            if sha(destination) != before or sha(source) != before:
                raise ValueError("public exports changed while capturing; wait for the build to finish")
            self.artifact_pins.append({"path": relative.as_posix(), "sha256": before})
            directories.add(destination.parent)
            found.add(source.name)
            if source.name.startswith("lib") and source.suffix == ".a":
                libraries.add(source.name[3:-2])
        if not required.issubset(found):
            raise ValueError("complete exported cjdoc/model/render static package artifacts are required")
        stdx_value = self.args.stdx or self.env.get("CANGJIE_STDX_PATH")
        if not stdx_value:
            raise ValueError("authenticated static stdx import path must be explicitly supplied")
        stdx = Path(stdx_value).resolve(strict=True)
        directories.add(stdx)
        for archive in stdx.glob("lib*.a"):
            libraries.add(archive.name[3:-2])
        self.caller_binary.parent.mkdir(parents=True)
        command = ["cjc", "--static", "--output-type", "exe", "-O2",
                   "--output-dir", self.caller_binary.parent, "-o", self.caller_binary.name]
        for directory in sorted(directories):
            command += ["--import-path", directory, "--library-path", directory]
        for library in sorted(libraries):
            command += ["--library", library]
        command += [self.driver / "src/main.cj"]
        self.run("public-caller-compile", command, self.driver)

    def execute(self):
        self.compile_caller()
        for name, project in [('library-a', self.library_a), ('library-b', self.library_b),
                              ('consumer-a', self.consumer_a), ('consumer-b', self.consumer_b)]:
            self.run(name + '-compile', ['cjpm', 'build', '--jobs', '1'], project)
        producer_context = self.receipt(self.library_a, 'producer')
        a_context = self.receipt(self.consumer_a, 'consumer-a')
        b_context = self.receipt(self.consumer_b, 'consumer-b')
        producer_site = self.root / 'producer-site'
        self.run('producer-generate', [self.binary, 'generate', '--project', self.library_a,
                 '--output', producer_site, '--format', 'json', '--format', 'html', '--format', 'symbol-index',
                 '--locale', 'en', '--lint-profile', 'off', '--build-context', producer_context,
                 '--doc-version', 'producer-publication-one'], runtime=True)
        producer = load(producer_site / 'docs.json')
        produced_index = producer_site / 'html/symbol-index.json'
        inventory = load(produced_index)
        assert inventory['schemaVersion'] == 'cjdoc.symbol-index/2'
        produced_set = next(item for item in inventory['documentSets'] if item['library'] == 'library')
        assert produced_set['language'] == 'en'
        assert produced_set['apiVersion'] == '1.0.0'
        assert produced_set['documentationRevision'] == 'producer-publication-one'
        catalog, index = self.catalog(self.root / 'sources', produced_index)
        extra = self.root / 'extra-sources'
        write(extra / 'cjdoc-documents.json', json.dumps({'schemaVersion': 'cjdoc.doc-sources/1', 'documents': []}))
        before = self.pair('no-source-baseline', self.consumer_a, a_context)
        no_pin = self.pair('no-pin', self.consumer_a, a_context, catalog)
        unverified = list(navigations(no_pin))
        assert len(unverified) >= 2 and all(item['matchLevel'] == 'manual' and
            'unverified' in item['reason'] for item in unverified), 'unpinned reference must remain explicitly manual, never authenticated exact'
        pinned = self.pair('host-pinned-exact', self.consumer_a, a_context, catalog, index, sha(index))
        exact = list(navigations(pinned))
        assert len(exact) >= 2 and all(item['matchLevel'] == 'exact' for item in exact)
        assert all(item['apiIdentity'] == dependency(producer, 'library')['identity'] for item in exact)
        assert dependency(pinned, 'library')['state'] == 'verified', 'public buildContext was not consumed'
        assert semantics(before['declarations']) == semantics(pinned['declarations']), 'navigation upgraded semantic identity'
        wrong = self.pair('wrong-pin', self.consumer_a, a_context, catalog, index, '0' * 64)
        assert not list(navigations(wrong)), 'wrong complete-byte digest authorized an inventory'
        changed_catalog, changed_index = self.catalog(self.root / 'changed-sources', produced_index)
        previous = sha(changed_index)
        changed_index.write_bytes(changed_index.read_bytes() + b'\n')
        assert load(changed_index) == inventory and sha(changed_index) != previous
        changed = self.pair('whole-byte-pin-change', self.consumer_a, a_context, changed_catalog, changed_index, previous)
        assert not list(navigations(changed)), 'pin was checked against reconstructed JSON instead of actual complete bytes'
        missing_language = self.pair('language-required', self.consumer_a, a_context, catalog, index, sha(index), language='zh-CN')
        assert not list(navigations(missing_language)), 'language fallback was enabled implicitly'
        fallback = self.pair('language-fallback', self.consumer_a, a_context, catalog, index, sha(index),
                             language='zh-CN', fallback=True)
        assert len(list(navigations(fallback))) >= 2
        assert all(item['language'] == 'en' and item['matchLevel'] == 'exact' for item in navigations(fallback))
        wrong_version = self.pair('compatible-default-rejected', self.consumer_b, b_context, catalog, index, sha(index))
        assert not list(navigations(wrong_version)), 'different actual source identity borrowed neighbouring docs'
        mapping = {'fromIdentity': dependency(wrong_version, 'library')['identity'],
                   'toIdentity': produced_set['identity'], 'target': self.args.target, 'cfg': '',
                   'evidence': 'controlled source-generated class reference mapping; no ABI/behavior attestation'}
        compatible_catalog, compatible_index = self.catalog(self.root / 'compatible-sources', produced_index, mapping)
        disabled = self.pair('compatible-mapping-no-opt-in', self.consumer_b, b_context,
                             compatible_catalog, compatible_index, sha(compatible_index))
        assert not list(navigations(disabled)), 'catalog policy bypassed linkCompatible=false'
        compatible = self.pair('compatible-explicit', self.consumer_b, b_context,
                               compatible_catalog, compatible_index, sha(compatible_index), compatible=True)
        choices = list(navigations(compatible))
        assert len(choices) >= 2 and all(item['matchLevel'] == 'compatible' for item in choices)
        assert all('documentationRevision=producer-publication-one' in item['reason'] and
                   'apiVersion (publisher package declaration)=1.0.0' in item['reason'] for item in choices)
        revised = self.pair('documentation-revision-independent', self.consumer_a, a_context,
                            catalog, index, sha(index), revision='consumer-publication-b')
        assert pinned['dependencies'] == revised['dependencies'], 'publication revision changed selected target dependency identity'
        assert semantics(pinned['declarations']) == semantics(revised['declarations'])
        assert list(navigations(pinned)) == list(navigations(revised)), 'consumer display revision changed external target choice'
        assert sha(self.binary) == self.binary_digest, "CLI binary changed during acceptance; freeze the build first"
        for case in self.cases:
            case["state"] = "passed"
        report = {'state': 'passed', 'schemaVersion': 'cjdoc.public-api-acceptance/1',
                  'cliBinarySha256': self.binary_digest,
                  'externalCallerSourceSha256': sha(CALLER),
                  'externalCallerBinarySha256': sha(self.caller_binary),
                  "staticPublicExportInputs": self.artifact_pins,
                  'actualIndependentCompiles': 5, 'generatorParserBuildIdentity': 'unknown',
                  'cases': self.cases, 'commands': self.commands}
        write(self.root / 'evidence.json', json.dumps(report, indent=2) + '\n')
        print('PASS: independent public API / CLI complete-IR equivalence; ' + str(len(self.cases)) + ' real-input cases')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--binary-sha256', help='optional host assertion for the exact CLI bytes being accepted')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument("--public-artifacts", type=Path, default=REPO / "target/release",
                        help="read-only .cjo/.a package exports from the accepted build; never rebuilt")
    parser.add_argument("--stdx", type=Path, help="explicit static stdx import directory; defaults to authenticated CANGJIE_STDX_PATH")
    parser.add_argument('--target', default='x86_64-unknown-linux-gnu')
    parser.add_argument('--timeout', type=int, default=900)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    acceptance = Acceptance(args)
    if args.prepare_only:
        print('PREPARED: private external caller and actual producer/consumer sources; no verification run')
        return 0
    try:
        acceptance.execute()
    except (AssertionError, RuntimeError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired) as error:
        reason = str(error).replace(str(acceptance.root), '<acceptance>').replace(str(REPO), '<repo>').replace(str(Path.home()), '$HOME')
        write(acceptance.root / 'evidence.json', json.dumps({'state': 'failed', 'reason': reason,
              'cliBinarySha256': acceptance.binary_digest, 'cases': acceptance.cases,
              'commands': acceptance.commands}, indent=2) + '\n')
        raise SystemExit(reason)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
