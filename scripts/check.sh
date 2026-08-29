#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_dir="${repo_root}/target/acceptance"
binary="${repo_root}/target/release/bin/main"
python_cmd="${CJDOC_PYTHON:-python3}"

cd "${repo_root}"
cjpm build
if [[ ! -x "${binary}" && -x "${binary}.exe" ]]; then
    binary="${binary}.exe"
fi
test -x "${binary}"
cjpm test

rm -rf "${check_dir}"
mkdir -p "${check_dir}/schemas"

for schema_name in doc-ir diagnostics cfg-matrix search-index; do
    "${binary}" schema "${schema_name}" >"${check_dir}/schemas/${schema_name}.schema.json"
done
cmp docs/schema/doc-ir.schema.json "${check_dir}/schemas/doc-ir.schema.json"
cmp docs/schema/diagnostics.schema.json "${check_dir}/schemas/diagnostics.schema.json"
cmp docs/schema/cfg-matrix.schema.json "${check_dir}/schemas/cfg-matrix.schema.json"
cmp docs/schema/search-index.schema.json "${check_dir}/schemas/search-index.schema.json"

run_golden() {
    local name="$1"
    local project="$2"
    local expected="$3"
    shift 3
    "${binary}" generate --project "${project}" --format json \
        --output "${check_dir}/${name}/first" "$@" >/dev/null
    "${binary}" generate --project "${project}" --format json \
        --output "${check_dir}/${name}/second" "$@" >/dev/null
    cmp "${expected}" "${check_dir}/${name}/first/docs.json"
    cmp "${check_dir}/${name}/first/docs.json" "${check_dir}/${name}/second/docs.json"
    "${python_cmd}" scripts/validate_schema.py docs/schema/doc-ir.schema.json \
        "${check_dir}/${name}/first/docs.json"
}

run_golden basic tests/fixtures/projects/basic tests/fixtures/golden-v5/basic.docs.json
run_golden functions tests/fixtures/projects/functions tests/fixtures/golden-v5/functions.docs.json
run_golden types tests/fixtures/projects/types tests/fixtures/golden-v5/types.docs.json
run_golden extend tests/fixtures/projects/extend_visibility tests/fixtures/golden-v5/extend.docs.json
run_golden source-edges tests/fixtures/projects/source_edges tests/fixtures/golden-v5/source-edges.docs.json
run_golden unsupported tests/fixtures/projects/unsupported tests/fixtures/golden-v5/unsupported.docs.json
run_golden workspace tests/fixtures/projects/workspace tests/fixtures/golden-v5/workspace.docs.json
run_golden conditional-linux tests/fixtures/projects/conditional \
    tests/fixtures/golden-v5/conditional-linux.docs.json --cfg os=Linux
run_golden path-dependencies tests/fixtures/projects/path_dependencies \
    tests/fixtures/golden-v5/path-dependencies.docs.json --include-path-dependencies

"${binary}" generate --project tests/fixtures/projects/basic \
    --format json --format markdown --format html --output "${check_dir}/all/first" >/dev/null
"${binary}" generate --project tests/fixtures/projects/basic \
    --format json --format markdown --format html --output "${check_dir}/all/second" >/dev/null
cmp "${check_dir}/all/first/docs.json" "${check_dir}/all/second/docs.json"
diff -qr "${check_dir}/all/first/markdown" "${check_dir}/all/second/markdown"
diff -qr "${check_dir}/all/first/html" "${check_dir}/all/second/html"
"${python_cmd}" scripts/validate_schema.py docs/schema/search-index.schema.json \
    "${check_dir}/all/first/html/search-index.json"
"${python_cmd}" scripts/validate_html_site.py "${check_dir}/all/first/html"

"${binary}" render --input "${check_dir}/all/first/docs.json" \
    --format json --format markdown --format html --output "${check_dir}/roundtrip" >/dev/null
cmp "${check_dir}/all/first/docs.json" "${check_dir}/roundtrip/docs.json"
diff -qr "${check_dir}/all/first/markdown" "${check_dir}/roundtrip/markdown"
diff -qr "${check_dir}/all/first/html" "${check_dir}/roundtrip/html"

"${binary}" generate --project tests/fixtures/projects/basic --format json --stdout \
    >"${check_dir}/stdout.json"
jq -e '.schemaVersion == "cjdoc.doc-ir/5" and (.declarations | length) == 25' \
    "${check_dir}/stdout.json" >/dev/null

set +e
"${binary}" check --project tests/fixtures/projects/basic --lint-profile strict \
    --deny-warnings >/dev/null 2>"${check_dir}/strict.stderr"
strict_code=$?
"${binary}" unknown-command >/dev/null 2>"${check_dir}/invalid.stderr"
invalid_code=$?
set -e
test "${strict_code}" -eq 1
test "${invalid_code}" -eq 2
test -s "${check_dir}/strict.stderr"

"${binary}" generate --project tests/fixtures/projects/html_security --format html \
    --output "${check_dir}/security" >/dev/null
"${python_cmd}" scripts/validate_html_site.py "${check_dir}/security/html"

(cd tests/fixtures/projects/provider_plugin && cjpm run)

echo "cjdoc acceptance gate passed"
