"""Check cjdoc comments and locate the generated HTML pages for selected APIs."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib

LANGUAGES = ('zh-CN', 'en')
INDEX_SCHEMA = 'cjdoc.symbol-index/2'


def configured_languages(project: Path) -> tuple[str, ...]:
    try:
        with (project / 'cjdoc.toml').open('rb') as config:
            i18n = tomllib.load(config).get('i18n', {})
    except FileNotFoundError:
        return ()
    languages = i18n.get('languages') if isinstance(i18n, dict) else None
    if isinstance(languages, list) and len(languages) == 2 and {
            language.lower() for language in languages if isinstance(language, str)
    } == {'zh-cn', 'en'}:
        return LANGUAGES
    return ()


def index_matches(root: Path, targets: list[str]) -> dict[str, list[dict[str, str]]]:
    path = (root / 'symbol-index.json').resolve(strict=True)
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError('symbol-index.json is not a regular file inside the HTML root')
    index = json.loads(path.read_text(encoding='utf-8'))
    if (not isinstance(index, dict) or index.get('schemaVersion') != INDEX_SCHEMA
            or not isinstance(index.get('entries'), list)):
        raise ValueError(f'incompatible symbol-index.json; expected {INDEX_SCHEMA}')
    matches = {target: [] for target in targets}
    for entry in index['entries']:
        fields = ('id', 'qualifiedName', 'sourceHeader', 'href')
        if not isinstance(entry, dict) or any(not isinstance(entry.get(key), str) for key in fields):
            raise ValueError(f'incompatible entry in symbol-index.json; expected {INDEX_SCHEMA}')
        name, symbol_id = entry['qualifiedName'], entry['id']
        if name in matches:
            matches[name].append(entry)
        if symbol_id != name and symbol_id in matches:
            matches[symbol_id].append(entry)
    return matches


def page_uri(root: Path, href: str) -> str:
    relative = Path(href)
    if relative.anchor or '..' in relative.parts or relative.suffix != '.html':
        raise ValueError('expected a relative HTML path inside the site')
    page = (root / relative).resolve(strict=True)
    if not page.is_relative_to(root) or page.suffix != '.html' or not page.is_file():
        raise ValueError('expected a regular HTML file inside the site')
    return page.as_uri()


def report_targets(site: Path, languages: tuple[str, ...], targets: list[str]) -> int:
    failed = False
    for locale in languages or ('',):
        root = site / 'html' / locale
        label = locale or 'html'
        try:
            matches = index_matches(root, targets)
        except (OSError, ValueError, RuntimeError) as error:
            print(f'{label}: cannot read symbol index: {error}', file=sys.stderr)
            failed = True
            continue
        for target, entries in matches.items():
            if not entries:
                print(f'{label}: no exact match for {target}', file=sys.stderr)
                failed = True
                continue
            ambiguous = len(entries) > 1
            if ambiguous:
                print(f'{label}: {target} matches {len(entries)} entries; choose a symbol ID:', file=sys.stderr)
                failed = True
            for entry in entries:
                signature, symbol_id = entry['sourceHeader'], entry['id']
                try:
                    uri = page_uri(root, entry['href'])
                except (OSError, ValueError, RuntimeError):
                    print(f'{label}: {signature} [{symbol_id}]: missing or invalid HTML page', file=sys.stderr)
                    failed = True
                    continue
                print(f'{label}: {signature} [{symbol_id}]\n  {uri}',
                      file=sys.stderr if ambiguous else sys.stdout)
    return int(failed)


def run_cjdoc(executable: Path, project: Path, *args: str) -> int:
    try:
        code = subprocess.run([executable, *args], cwd=project).returncode
    except OSError as error:
        print(f'Cannot run cjdoc: {error}. Check the installation and load the matching SDK.', file=sys.stderr)
        return 2
    return 128 - code if code < 0 else code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', required=True, type=Path, help='project or workspace root with cjpm.toml')
    parser.add_argument('targets', metavar='TARGET', nargs='+', help='exact qualified name or cjdoc symbol ID')
    args = parser.parse_args()
    project = args.project.absolute()
    if not (project / 'cjpm.toml').is_file():
        parser.error('no cjpm.toml at --project; pass the cjpm project or workspace root')
    executable = shutil.which('cjdoc')
    if executable is None:
        parser.error('cjdoc not found in PATH; install cjdoc and load the matching SDK')
    cli = Path(executable).absolute()
    code = run_cjdoc(cli, project, 'check', '--project', '.')
    if code:
        return code
    try:
        languages = configured_languages(project)
        cache = Path.home() / '.cache' / 'cjdoc'
        cache.mkdir(parents=True, exist_ok=True)
        site = Path(tempfile.mkdtemp(prefix='preview-', dir=cache)).resolve() / 'site'
    except (OSError, ValueError, RuntimeError) as error:
        print(f'Cannot prepare preview: {error}', file=sys.stderr)
        return 1
    options = ('--all-languages',) if languages else ()
    code = run_cjdoc(cli, project, 'generate', '--project', '.', '--format', 'html', '--output', str(site), *options)
    if code:
        return code
    return report_targets(site, languages, args.targets)


if __name__ == '__main__':
    raise SystemExit(main())
