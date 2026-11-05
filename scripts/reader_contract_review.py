#!/usr/bin/env python3
"""Run copied caller guides and selected author-fact cases against PocketKit source."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import tomllib
from dataclasses import dataclass

from reader_benchmark import scrub
from reader_process import measured_process

CASES = (
    'C01-input-copy-order-duplicates-empty', 'C02-optional-domain',
    'C03-at-invalid-no-mutation', 'C04-default-decimal-add', 'C05-invalid-radix-pre-mutation',
    'C06-addAll-copy-and-order', 'C07-snapshot-container-independent',
    'C08-clear-does-not-change-existing-snapshot', 'R01-empty-eof-stable-open',
    'R02-ordered-read-stable-eof', 'R03-open-rewind', 'R04-idempotent-close',
    'R05-closed-read-and-rewind-reject-without-reopening',
)

GUIDE_TASKS = ('store-read', 'snapshot-clear', 'index-errors', 'reader-close')
GUIDE_SOURCES = {'zh-CN': 'docs/guide.md', 'en': 'docs/en/guide.md'}


@dataclass(frozen=True)
class GuidePrograms:
    manifest: bytes
    programs: dict[str, bytes]
    command: list[str]


def extract_guide_programs(path: Path, sections: dict[str, str]) -> GuidePrograms:
    """Read complete fenced inputs by the author's shared section identities."""
    expected_sections = {'caller-setup', *GUIDE_TASKS}
    if set(sections) != expected_sections or len(set(sections.values())) != len(sections):
        raise ValueError('caller guide requires distinct headings for all five section identities')
    by_heading = {heading: identity for identity, heading in sections.items()}
    found: dict[tuple[str, str], bytes] = {}
    seen_sections: set[str] = set()
    section, fence, language = '', '', ''
    body: list[str] = []
    for line in path.read_bytes().decode('utf-8').splitlines(keepends=True):
        value = line.rstrip('\r\n')
        if fence:
            if re.fullmatch(r' {0,3}' + re.escape(fence[0]) + '{' + str(len(fence)) + r',}\s*', value):
                if language in ('toml', 'cangjie', 'cj', 'sh'):
                    expected = 'caller-setup' if language in ('toml', 'sh') else section
                    if section != expected or section not in expected_sections:
                        raise ValueError('caller input fence is outside its task section')
                    kind = 'cangjie' if language == 'cj' else language
                    key = (section, kind)
                    if key in found:
                        raise ValueError('duplicate caller input fence: ' + section + '/' + kind)
                    found[key] = ''.join(body).encode('utf-8')
                fence, language, body = '', '', []
            else:
                body.append(line)
            continue
        opening = re.fullmatch(r' {0,3}(`{3,}|~{3,})([^`]*)', value)
        if opening:
            fence, language = opening[1], opening[2].strip()
            continue
        heading = re.fullmatch(r' {0,3}##\s+(.+?)\s*#*\s*', value)
        if heading:
            title = heading[1]
            section = by_heading.get(title, by_heading.get(title.lower().replace(' ', '-'), ''))
            if section:
                if section in seen_sections:
                    raise ValueError('duplicate caller section: ' + section)
                seen_sections.add(section)
    if fence:
        raise ValueError('unclosed caller guide fence')
    required = {('caller-setup', 'toml'), ('caller-setup', 'sh'),
                *((section, 'cangjie') for section in GUIDE_TASKS)}
    if set(found) != required or seen_sections != expected_sections:
        raise ValueError('caller guide must contain one manifest, one command and four complete programs')
    manifest = found[('caller-setup', 'toml')]
    config = tomllib.loads(manifest.decode('utf-8'))
    if config.get('package', {}).get('output-type') != 'executable' or \
            config.get('dependencies', {}).get('pocketkit') != \
            {'path': '../demo-v2', 'output-type': 'static'}:
        raise ValueError('caller manifest must use the documented executable/static sibling layout')
    command = shlex.split(found[('caller-setup', 'sh')].decode('utf-8'))
    if command != ['cjpm', 'run', '--build-args', '--jobs 1']:
        raise ValueError('caller guide command differs from the required run command')
    return GuidePrograms(manifest, {section: found[(section, 'cangjie')] for section in GUIDE_TASKS}, command)


def validate_guide_result(result: dict, stdout: str, stderr: str, section: str) -> None:
    if result['timedOut'] or result['exitCode']:
        raise ValueError('caller program did not complete successfully: ' + section)
    markers = [line for line in (stdout + '\n' + stderr).splitlines() if re.search(r'\bPASS\b', line)]
    if markers != ['PASS guide-' + section]:
        raise ValueError('caller program must report exactly its own success marker: ' + section)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_sources(repo: Path, output: Path) -> list[dict]:
    inventory = []
    for version in ('demo-v2', 'support-v1'):
        project = repo / 'examples/pocketkit' / version
        for source in [project / 'cjpm.toml', *sorted((project / 'src').rglob('*.cj'))]:
            destination = output / 'sources' / version / source.relative_to(project)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            # Bind evidence to the compiler input, not a later read of an edited original.
            inventory.append({'path': source.relative_to(repo).as_posix(), 'sha256': sha256(destination)})
    project = repo / 'examples/pocketkit/demo-v2'
    for relative in ('cjdoc.toml', *GUIDE_SOURCES.values()):
        source = project / relative
        destination = output / 'sources/demo-v2' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        inventory.append({'path': source.relative_to(repo).as_posix(), 'sha256': sha256(destination)})
    consumer = repo / 'examples/pocketkit/contract_review.cj'
    destination = output / 'contract_review.cj'
    shutil.copyfile(consumer, destination)
    inventory.append({'path': consumer.relative_to(repo).as_posix(), 'sha256': sha256(destination)})
    return inventory


def run_guide_programs(output: Path, report: dict, stage) -> None:
    captured = output / 'sources/demo-v2'
    pages = tomllib.loads((captured / 'cjdoc.toml').read_text(encoding='utf-8'))['docs']['pages']
    for locale, source in GUIDE_SOURCES.items():
        matches = [page for page in pages if page.get('id') == 'first-catalogue' and page.get('language') == locale]
        if len(matches) != 1 or matches[0]['source'] != source:
            raise ValueError('caller guide must have one explicit localized page: ' + locale)
        guide = captured / source
        inputs = extract_guide_programs(guide, matches[0]['sections'])
        layout = output / 'guides' / locale / 'examples/pocketkit'
        layout.mkdir(parents=True)
        for version in ('demo-v2', 'support-v1'):
            shutil.copytree(output / 'sources' / version, layout / version)
        caller = layout / 'guide-caller'
        (caller / 'src').mkdir(parents=True)
        manifest = caller / 'cjpm.toml'
        manifest.write_bytes(inputs.manifest)
        for section, program in inputs.programs.items():
            preserved = output / 'guides' / locale / 'programs' / section / 'src/main.cj'
            preserved.parent.mkdir(parents=True)
            preserved.write_bytes(program)
            main = caller / 'src/main.cj'
            main.write_bytes(program)
            name = 'guide-' + locale + '-' + section
            receipt = {'language': locale, 'sectionId': section, 'status': 'failed',
                       'guideSha256': sha256(guide), 'manifestSha256': sha256(manifest),
                       'programSha256': sha256(main), 'programPath': preserved.relative_to(output).as_posix()}
            report['guidePrograms'].append(receipt)
            result = stage(name, inputs.command, caller, 300)
            validate_guide_result(result,
                (output / (name + '.stdout.log')).read_text(encoding='utf-8'),
                (output / (name + '.stderr.log')).read_text(encoding='utf-8'), section)
            if main.read_bytes() != program or manifest.read_bytes() != inputs.manifest:
                raise ValueError('caller inputs changed during execution: ' + name)
            receipt['status'] = 'pass'


def run(args: argparse.Namespace) -> int:
    if not re.fullmatch(r'[0-9a-f]{40}', args.revision):
        raise ValueError('--revision requires the actual full source commit')
    repo, output = args.repo.resolve(), args.output.resolve()
    output.mkdir(mode=0o700)
    replacements = {output: '<evidence>', repo: '<repo>', Path.home(): '$HOME'}
    for key, label in (('CANGJIE_HOME', '<sdk>'), ('CJDOC_STDX_PATH', '<stdx>')):
        if os.environ.get(key):
            replacements[Path(os.environ[key])] = label
    report = {'schemaVersion': 'cjdoc.reader-contract-review/1', 'sourceRevision': args.revision,
              'scope': 'eight copied caller-guide programs and thirteen selected real consumer cases; not complete contracts, concurrency, allocation-failure or complexity proof',
              'status': 'running', 'stages': [], 'cases': [], 'guidePrograms': [], 'sources': [],
              'toolchain': {key: os.environ.get(key) for key in
                            ('CJDOC_TOOLCHAIN_VERSION', 'CJDOC_TOOLCHAIN_FINGERPRINT', 'CJDOC_STDX_DIGEST')}}

    def stage(name: str, command: list[str], cwd: Path, timeout: int) -> dict:
        stdout, stderr = output / (name + '.stdout.log'), output / (name + '.stderr.log')
        result = measured_process(command, stdout, stderr, timeout, cwd=cwd)
        for log in (stdout, stderr):
            log.write_text(scrub(log.read_text(encoding='utf-8', errors='replace'), replacements), encoding='utf-8')
        report['stages'].append({'name': name, **result,
            'command': [scrub(value, replacements) for value in command],
            'workingDirectory': scrub(str(cwd), replacements), 'stdout': stdout.name, 'stderr': stderr.name})
        if result['timedOut'] or result['exitCode']:
            raise RuntimeError(name + ' did not complete successfully; retained actual logs')
        return result

    try:
        report['sources'] = copy_sources(repo, output)
        for tool in ('cjc', 'cjpm'):
            executable = shutil.which(tool)
            if not executable:
                raise ValueError(tool + ' is unavailable in the prepared SDK environment')
            stage(tool + '-version', [executable, '-v'], repo, 30)
            report['toolchain'][tool] = {'sha256': sha256(Path(executable)),
                'version': (output / (tool + '-version.stdout.log')).read_text(encoding='utf-8').strip()}
        library_root = output / 'libraries'
        stage('library-build', ['cjpm', 'build', '--jobs', '1', '--target-dir', str(library_root)],
              output / 'sources/demo-v2', 300)
        libraries = library_root / 'release/pocketkit'
        executable = output / 'reader-contract-review'
        stage('consumer-compile', ['cjc', str(output / 'contract_review.cj'), '--import-path', str(libraries),
              '-L', str(libraries), '-lpocketkit', '-lpocketkit.io', '-O2', '-o', str(executable)], output, 120)
        report['executableSha256'] = sha256(executable)
        stage('consumer-run', [str(executable)], output, 30)
        actual = (output / 'consumer-run.stdout.log').read_text(encoding='utf-8').splitlines()
        if actual != ['PASS ' + case for case in CASES]:
            raise ValueError('the real consumer did not report all fixed cases in order')
        report['cases'] = [{'id': case, 'status': 'pass'} for case in CASES]
        run_guide_programs(output, report, stage)
        report['status'] = 'pass'
    except (OSError, ValueError, RuntimeError) as error:
        report.update(status='failed', reason=scrub(str(error), replacements))
        report['inputIntegrity'] = 'not-yet-checked'
    finally:
        try:
            for source in report['sources']:
                if sha256(repo / source['path']) != source['sha256']:
                    raise ValueError('original example input changed during review: ' + source['path'])
            report['inputIntegrity'] = 'pass'
        except (OSError, ValueError) as error:
            report.update(status='failed', inputIntegrity='failed', reason=scrub(str(error), replacements))
        (output / 'reader-contract-review.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': report['status'], 'coveredCases': len(report['cases']),
                          'guidePrograms': sum(row['status'] == 'pass' for row in report['guidePrograms']),
                          'scope': report['scope']}))
    return 0 if report['status'] == 'pass' else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    args = parser.parse_args()
    return run(args)


if __name__ == '__main__':
    raise SystemExit(main())
