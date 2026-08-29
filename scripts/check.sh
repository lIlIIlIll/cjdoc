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
        --output "${check_dir}/${name}/first" --cache-dir "${check_dir}/cache/${name}" "$@" >/dev/null
    "${binary}" generate --project "${project}" --format json \
        --output "${check_dir}/${name}/second" --cache-dir "${check_dir}/cache/${name}" "$@" >/dev/null
    cmp "${expected}" "${check_dir}/${name}/first/docs.json"
    cmp "${check_dir}/${name}/first/docs.json" "${check_dir}/${name}/second/docs.json"
    "${binary}" render --input "${check_dir}/${name}/first/docs.json" \
        --format json --stdout >"${check_dir}/${name}/validated.json"
    cmp "${check_dir}/${name}/first/docs.json" "${check_dir}/${name}/validated.json"
}

run_golden basic tests/fixtures/projects/basic tests/fixtures/golden-v6/basic.docs.json
run_golden functions tests/fixtures/projects/functions tests/fixtures/golden-v6/functions.docs.json
run_golden types tests/fixtures/projects/types tests/fixtures/golden-v6/types.docs.json
run_golden extend tests/fixtures/projects/extend_visibility tests/fixtures/golden-v6/extend.docs.json
run_golden source-edges tests/fixtures/projects/source_edges tests/fixtures/golden-v6/source-edges.docs.json
run_golden unsupported tests/fixtures/projects/unsupported tests/fixtures/golden-v6/unsupported.docs.json
run_golden workspace tests/fixtures/projects/workspace tests/fixtures/golden-v6/workspace.docs.json
run_golden conditional-linux tests/fixtures/projects/conditional \
    tests/fixtures/golden-v6/conditional-linux.docs.json --cfg os=Linux
run_golden path-dependencies tests/fixtures/projects/path_dependencies \
    tests/fixtures/golden-v6/path-dependencies.docs.json --include-path-dependencies

"${binary}" generate --project tests/fixtures/projects/basic \
    --format json --format markdown --format html --output "${check_dir}/all/first" \
    --cache-dir "${check_dir}/cache/all" >/dev/null
"${binary}" generate --project tests/fixtures/projects/basic \
    --format json --format markdown --format html --output "${check_dir}/all/second" \
    --cache-dir "${check_dir}/cache/all" >/dev/null
cmp "${check_dir}/all/first/docs.json" "${check_dir}/all/second/docs.json"
diff -qr "${check_dir}/all/first/markdown" "${check_dir}/all/second/markdown"
diff -qr "${check_dir}/all/first/html" "${check_dir}/all/second/html"
"${python_cmd}" scripts/validate_html_site.py "${check_dir}/all/first/html"

"${binary}" render --input "${check_dir}/all/first/docs.json" \
    --format json --format markdown --format html --output "${check_dir}/roundtrip" >/dev/null
cmp "${check_dir}/all/first/docs.json" "${check_dir}/roundtrip/docs.json"
diff -qr "${check_dir}/all/first/markdown" "${check_dir}/roundtrip/markdown"
diff -qr "${check_dir}/all/first/html" "${check_dir}/roundtrip/html"

"${binary}" generate --project tests/fixtures/projects/basic --format json --stdout \
    --cache-dir "${check_dir}/cache/stdout" >"${check_dir}/stdout.json"
"${python_cmd}" -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); assert value["schemaVersion"] == "cjdoc.doc-ir/6" and len(value["declarations"]) == 25' \
    "${check_dir}/stdout.json"

set +e
"${binary}" check --project tests/fixtures/projects/basic --lint-profile strict \
    --deny-warnings --cache-dir "${check_dir}/cache/check" >/dev/null 2>"${check_dir}/strict.stderr"
strict_code=$?
"${binary}" unknown-command >/dev/null 2>"${check_dir}/invalid.stderr"
invalid_code=$?
"${binary}" render --input "${check_dir}/all/first/docs.json" --project . \
    >/dev/null 2>"${check_dir}/render-invalid.stderr"
render_invalid_code=$?
set -e
test "${strict_code}" -eq 1
test "${invalid_code}" -eq 2
test "${render_invalid_code}" -eq 2
test -s "${check_dir}/strict.stderr"
test -s "${check_dir}/render-invalid.stderr"

"${binary}" generate --project tests/fixtures/projects/html_security --format html \
    --output "${check_dir}/security" --cache-dir "${check_dir}/cache/security" >/dev/null
"${python_cmd}" scripts/validate_html_site.py "${check_dir}/security/html"

mkdir -p "${check_dir}/resource-limit/src"
cp tests/fixtures/projects/basic/cjpm.toml "${check_dir}/resource-limit/cjpm.toml"
"${python_cmd}" -c 'import sys; open(sys.argv[1], "wb").truncate(32 * 1024 * 1024 + 1)' \
    "${check_dir}/resource-limit/src/too-large.cj"
set +e
"${binary}" generate --project "${check_dir}/resource-limit" --format json \
    --output "${check_dir}/resource-limit-output" --no-cache >/dev/null 2>"${check_dir}/resource-limit.stderr"
resource_limit_code=$?
set -e
test "${resource_limit_code}" -eq 1
"${python_cmd}" -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); assert any(item["code"] == "CJDOC1026" for item in value["diagnostics"])' \
    "${check_dir}/resource-limit-output/docs.json"

"${binary}" generate --project tests/fixtures/projects/basic --format html \
    --output "${check_dir}/stale" --cache-dir "${check_dir}/cache/stale" >/dev/null
test -f "${check_dir}/stale/html/index.html"
"${binary}" generate --project tests/fixtures/projects/basic --format json \
    --output "${check_dir}/stale" --cache-dir "${check_dir}/cache/stale" >/dev/null
test -f "${check_dir}/stale/docs.json"
test ! -e "${check_dir}/stale/html"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        mkdir -p "${check_dir}/symlink-target" "${check_dir}/symlink-output"
        printf '%s\n' '{"schemaVersion":"cjdoc.output/1","files":[]}' \
            >"${check_dir}/symlink-output/.cjdoc-output.json"
        ln -s "${check_dir}/symlink-target" "${check_dir}/symlink-output/html"
        set +e
        "${binary}" generate --project tests/fixtures/projects/basic --format html \
            --output "${check_dir}/symlink-output" --no-cache \
            >/dev/null 2>"${check_dir}/symlink.stderr"
        symlink_code=$?
        set -e
        test "${symlink_code}" -eq 2
        test -s "${check_dir}/symlink.stderr"
        test -z "$(ls -A "${check_dir}/symlink-target")"
        ;;
esac

(cd tests/fixtures/projects/provider_plugin && cjpm run)

echo "cjdoc acceptance gate passed"
