#!/usr/bin/env bash
# Run the existing Node Playwright configurations against native-generated sites.
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

if [[ $# != 2 ]]; then
    echo 'usage: check_browser.sh <cjdoc-binary> <new-output-directory>' >&2
    exit 2
fi
python_cmd="${CJDOC_PYTHON:-python3}"
node_path="$(command -v node)"
[[ "$("${node_path}" --version)" == 'v26.11.1' ]] || {
    echo 'browser acceptance requires Node v26.11.1' >&2
    exit 2
}
binary="$("${python_cmd}" -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$1")"
out="$("${python_cmd}" - "$2" <<'PY'
from pathlib import Path
import sys
from scripts.safe_output_root import lexical_absolute, verify_directory_chain

out = lexical_absolute(Path(sys.argv[1]))
verify_directory_chain(out.parent)
out.mkdir(mode=0o700)  # Refuse to reuse any path, including dangling links.
print(out)
PY
)"

# Keep package build outputs, the PocketKit support index and npm dependencies
# inside the browser stage's committed source copy, never in the checkout.
revision="$(git rev-parse HEAD)"
inputs="${out}/inputs"
mkdir "${inputs}"
git archive "${revision}" tests/browser examples/pocketkit scripts/publication_ir.py \
    tests/fixtures/projects/{html_reference,admonitions,declaration-groups,declaration-tags,basic} \
    tools/highlight/adapter.mjs tools/highlight/package.json tools/highlight/package-lock.json |
    tar -x -C "${inputs}"
harness="${inputs}/tests/browser"
adapter="${inputs}/tools/highlight"
npm ci --ignore-scripts --prefix "${harness}"
npm ci --ignore-scripts --prefix "${adapter}"
playwright="${harness}/node_modules/@playwright/test/cli.js"
# The Python Pages/accessibility driver uses a separate Playwright pin.
# The Node installer must not prune that driver's Chromium cache.
export PLAYWRIGHT_BROWSERS_PATH="${out}/chromium"
"${node_path}" "${playwright}" install chromium

fixtures="${inputs}/tests/fixtures/projects"
repository=(--repository-url https://github.com/example/reference
    --repository-revision "${revision}" --repository-root "${inputs}")
for locale in en zh-CN; do
    if ! "${binary}" generate --project "${fixtures}/html_reference" \
        --format html --format json --locale "${locale}" "${repository[@]}" \
        --output "${out}/reference-${locale}" --no-cache 2>"${out}/reference-${locale}.stderr.log"; then
        cat "${out}/reference-${locale}.stderr.log" >&2
        exit 1
    fi
    "${python_cmd}" scripts/validate_html_site.py "${out}/reference-${locale}/html"
    "${binary}" generate --project "${fixtures}/admonitions" \
        --format html --locale "${locale}" --output "${out}/admonitions/${locale}" --no-cache
done
"${binary}" generate --project "${fixtures}/declaration-groups" \
    --format html --all-languages --output "${out}/groups" --no-cache
"${binary}" generate --project "${fixtures}/declaration-tags" \
    --format html --all-languages "${repository[@]}" --output "${out}/tags" --no-cache
for version in 1.2.0 1.3.0; do
    "${binary}" generate --project "${fixtures}/basic" --format html --locale en \
        --doc-version "${version}" --output "${out}/version-${version}" --no-cache
done
"${binary}" versions compose --version "1.2.0=${out}/version-1.2.0/html" \
    --version "1.3.0=${out}/version-1.3.0/html" --latest 1.3.0 --output "${out}/versions"
"${python_cmd}" "${inputs}/examples/pocketkit/reproduce.py" \
    --cjdoc "${binary}" --output "${out}/pocketkit" --locale both
"${python_cmd}" scripts/i18n_gate.py --binary "${binary}" --repo . --workdir "${out}/i18n"
"${python_cmd}" scripts/test_package_overviews.py --binary "${binary}" --output "${out}/overviews"

# Replay the original CRLF code from the native snapshot. The fixture declares
# one local Token and uses it as both parameter and result, even without CHIR.
PYTHONPATH="${PWD}/scripts${PYTHONPATH:+:${PYTHONPATH}}" \
    "${python_cmd}" - "${binary}" "${out}/highlight" "${adapter}/adapter.mjs" "${node_path}" <<'PY'
from pathlib import Path
import sys
from types import SimpleNamespace

from highlight_acceptance import check_crlf_replay
from highlight_acceptance_worker import fixture, generate

binary, workdir, adapter, node = map(Path, sys.argv[1:])
project = workdir / 'project'
fixture(project)
with (project / 'cjdoc.toml').open('a', encoding='utf-8') as config:
    config.write('\n[semantic]\nmode = "source"\n')
real = workdir / 'real'
generate(binary, project, real, adapter, node)
check_crlf_replay(SimpleNamespace(workdir=workdir), binary, real, {})
PY

export CJDOC_HTML_FIXTURE="${out}/reference-en/html"
export CJDOC_HTML_FIXTURE_ZH="${out}/reference-zh-CN/html"
export CJDOC_DECLARATION_GROUPS_FIXTURE="${out}/groups/html"
export CJDOC_DECLARATION_TAGS_FIXTURE="${out}/tags/html"
export CJDOC_VERSION_FIXTURE="${out}/versions"
export CJDOC_READING_FIXTURE="${out}/pocketkit/native/demo-v2/html"
export CJDOC_I18N_SITE="${out}/i18n/multi"
export CJDOC_I18N_COMPOSED_SITE="${out}/i18n/composed"
export CJDOC_ADMONITION_FIXTURE="${out}/admonitions"
export CJDOC_PACKAGE_OVERVIEW_SITE="${out}/overviews"
export CJDOC_HIGHLIGHT_FIXTURE="${out}/highlight/crlf/html"
export CJDOC_HIGHLIGHT_EXPECT_TYPE_LINKS=2

# Preserve independent traces/reports for each configuration. The reference and
# highlight specs use a real clipboard, so do not overlap their browser runs.
mkdir "${out}/reports"
status=0
for suite in playwright i18n admonition highlight package-overview; do
    report="${out}/reports/${suite}"
    mkdir "${report}"
    (
        cd "${harness}"
        PLAYWRIGHT_JSON_OUTPUT_FILE="${report}/results.json" \
        PLAYWRIGHT_HTML_OUTPUT_DIR="${report}/html" PLAYWRIGHT_HTML_OPEN=never \
            "${node_path}" "${playwright}" test --config "${suite}.config.mjs" \
                --retries=0 --workers=1 --forbid-only --reporter=list,json,html \
                --output "${report}/artifacts"
    ) || status=1
done

"${python_cmd}" - "${out}/reports" <<'PY'
from collections import Counter
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
expected = {'highlight.spec.mjs', 'html-admonition.spec.mjs', 'html-reading.spec.mjs',
            'html-reference.spec.mjs', 'i18n.spec.mjs', 'package-overview.spec.mjs'}
counts = Counter()
failed = False


def visit(suite):
    global failed
    for spec in suite.get('specs', []):
        for test in spec['tests']:
            if test['status'] != 'expected' or not test['results'] or test['results'][-1]['status'] != 'passed':
                failed = True
            else:
                counts[Path(spec['file']).name] += 1
    for child in suite.get('suites', []):
        visit(child)


for name in ('playwright', 'i18n', 'admonition', 'highlight', 'package-overview'):
    path = root / name / 'results.json'
    if not path.is_file():
        print(f'{name}: no Playwright report', file=sys.stderr)
        failed = True
        continue
    result = json.loads(path.read_text(encoding='utf-8'))
    failed |= bool(result['errors'] or result['stats']['unexpected'] or
                   result['stats']['flaky'] or result['stats']['skipped'] or not result['stats']['expected'])
    for suite in result['suites']:
        visit(suite)
if expected != counts.keys():
    print(f'browser spec inventory mismatch: missing={sorted(expected - counts.keys())}, '
          f'unexpected={sorted(counts.keys() - expected)}', file=sys.stderr)
    failed = True
for spec, cases in sorted(counts.items()):
    print(f'{spec}: {cases} passed')
if failed:
    raise SystemExit('browser acceptance requires every selected case to pass; inspect the saved reports')
print(f'Browser acceptance: {len(counts)} spec files, {sum(counts.values())} passed, 0 skipped')
PY
exit "${status}"
