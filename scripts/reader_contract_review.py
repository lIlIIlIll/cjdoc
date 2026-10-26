#!/usr/bin/env python3
"""Run selected author-fact cases against unchanged PocketKit source, not a semantic score."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

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
    consumer = repo / 'examples/pocketkit/contract_review.cj'
    destination = output / 'contract_review.cj'
    shutil.copyfile(consumer, destination)
    inventory.append({'path': consumer.relative_to(repo).as_posix(), 'sha256': sha256(destination)})
    return inventory


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
              'scope': 'selected real consumer input/state cases; not complete contracts, concurrency, allocation-failure or complexity proof',
              'status': 'running', 'stages': [], 'cases': [], 'sources': [],
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
        for source in report['sources']:
            if sha256(repo / source['path']) != source['sha256']:
                raise ValueError('original example source changed during review: ' + source['path'])
        report['status'] = 'pass'
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        report.update(status='failed', reason=scrub(str(error), replacements))
        return 1
    finally:
        (output / 'reader-contract-review.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': report['status'], 'coveredCases': len(report['cases']), 'scope': report['scope']}))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    args = parser.parse_args()
    return run(args)


if __name__ == '__main__':
    raise SystemExit(main())
