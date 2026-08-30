#!/usr/bin/env bash
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_cmd="${CJDOC_PYTHON:-python3}"
"${python_cmd}" "${repo_root}/scripts/safe_output_root.py" --repo "${repo_root}" \
    --directory "${repo_root}/target" --create >/dev/null
target_root="${repo_root}/target"
check_dir="${target_root}/acceptance"
binary="${target_root}/release/bin/main"
source_edges_project="${CJDOC_SOURCE_EDGES_PROJECT:-tests/fixtures/projects/source_edges}"
unset CJDOC_SOURCE_EDGES_PROJECT CJDOC_SOURCE_EDGES_COMMIT CJDOC_SOURCE_EDGES_TREE

cd "${repo_root}"
"${python_cmd}" scripts/verify_repository_inputs.py --repo "${repo_root}" --require-tracked
"${python_cmd}" "${repo_root}/scripts/safe_output_root.py" --repo "${repo_root}" \
    --directory "${target_root}/release/bin" --allow-missing >/dev/null
cjpm build
if [[ -x "${binary}" || ( -f "${binary}" && ( "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ) ) ]]; then
    :
elif [[ -f "${binary}.exe" ]]; then
    binary="${binary}.exe"
else
    echo "cjdoc binary is missing or not executable: ${binary}" >&2
    exit 1
fi
"${python_cmd}" scripts/verify_repository_inputs.py --repo "${repo_root}" \
    --require-tracked --legacy-binary "${binary}"
cjpm test
"${python_cmd}" -m unittest discover -s scripts -p 'test_*.py'

"${python_cmd}" "${repo_root}/scripts/safe_output_root.py" --repo "${repo_root}" \
    --directory "${check_dir}" --allow-missing >/dev/null
rm -rf "${check_dir}"
mkdir -p "${check_dir}/schemas"

for schema_name in doc-ir doc-ir-v6 doc-ir-v7 doc-ir-v8 diagnostics cfg-matrix search-index; do
    "${binary}" schema "${schema_name}" | tr -d '\r' \
        >"${check_dir}/schemas/${schema_name}.schema.json"
done
cmp docs/schema/doc-ir.schema.json "${check_dir}/schemas/doc-ir.schema.json"
cmp docs/schema/doc-ir-v6.schema.json "${check_dir}/schemas/doc-ir-v6.schema.json"
cmp docs/schema/doc-ir-v7.schema.json "${check_dir}/schemas/doc-ir-v7.schema.json"
cmp docs/schema/doc-ir-v8.schema.json "${check_dir}/schemas/doc-ir-v8.schema.json"
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
        --format json --stdout | tr -d '\r' >"${check_dir}/${name}/validated.json"
    cmp "${check_dir}/${name}/first/docs.json" "${check_dir}/${name}/validated.json"
}

run_golden basic tests/fixtures/projects/basic tests/fixtures/golden-v8/basic.docs.json
run_golden functions tests/fixtures/projects/functions tests/fixtures/golden-v8/functions.docs.json
run_golden types tests/fixtures/projects/types tests/fixtures/golden-v8/types.docs.json
run_golden extend tests/fixtures/projects/extend_visibility tests/fixtures/golden-v8/extend.docs.json
run_golden source-edges "${source_edges_project}" tests/fixtures/golden-v8/source-edges.docs.json
run_golden unsupported tests/fixtures/projects/unsupported tests/fixtures/golden-v8/unsupported.docs.json
run_golden workspace tests/fixtures/projects/workspace tests/fixtures/golden-v8/workspace.docs.json
run_golden conditional-linux tests/fixtures/projects/conditional \
    tests/fixtures/golden-v8/conditional-linux.docs.json --cfg os=Linux
run_golden path-dependencies tests/fixtures/projects/path_dependencies \
    tests/fixtures/golden-v8/path-dependencies.docs.json --include-path-dependencies

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
"${python_cmd}" -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); assert value["schemaVersion"] == "cjdoc.doc-ir/8" and len(value["declarations"]) == 25' \
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

"${binary}" generate --project tests/fixtures/projects/basic \
    --format json --format html --output "${check_dir}/ownership" \
    --cache-dir "${check_dir}/cache/ownership" >/dev/null
printf '%s\n' 'docs.example.test' >"${check_dir}/ownership/CNAME"
printf '%s\n' 'user-owned edit' >"${check_dir}/ownership/docs.json"
cp -R "${check_dir}/ownership" "${check_dir}/ownership-before"
set +e
"${binary}" generate --project tests/fixtures/projects/basic --format json \
    --output "${check_dir}/ownership" --cache-dir "${check_dir}/cache/ownership" \
    >/dev/null 2>"${check_dir}/ownership.stderr"
ownership_code=$?
set -e
test "${ownership_code}" -eq 2
diff -qr "${check_dir}/ownership" "${check_dir}/ownership-before"
"${binary}" generate --project tests/fixtures/projects/basic --format json \
    --output "${check_dir}/ownership" --cache-dir "${check_dir}/cache/ownership" \
    --force-owned >/dev/null
test "$(cat "${check_dir}/ownership/CNAME")" = 'docs.example.test'
test ! -e "${check_dir}/ownership/html"
"${python_cmd}" -c 'import hashlib,json,sys; root=sys.argv[1]; value=json.load(open(root+"/.cjdoc-output.json", encoding="utf-8")); assert value["schemaVersion"]=="cjdoc.output/3" and value["digestAlgorithm"]=="sha256"; expected=sorted({d for item in value["files"] for d in ["/".join(item["path"].split("/")[:i]) for i in range(1,len(item["path"].split("/")))]}); assert value["directories"]==expected; assert all(hashlib.sha256(open(root+"/"+item["path"],"rb").read()).hexdigest()==item["sha256"] for item in value["files"])' \
    "${check_dir}/ownership"

mkdir -p "${check_dir}/missing-manifest"
printf '%s\n' 'preserve me' >"${check_dir}/missing-manifest/docs.json"
set +e
"${binary}" generate --project tests/fixtures/projects/basic --format json \
    --output "${check_dir}/missing-manifest" --no-cache --force-owned \
    >/dev/null 2>"${check_dir}/missing-manifest.stderr"
missing_manifest_code=$?
set -e
test "${missing_manifest_code}" -eq 2
test "$(cat "${check_dir}/missing-manifest/docs.json")" = 'preserve me'

mkdir -p "${check_dir}/unowned-collision"
printf '%s\n' 'unowned' >"${check_dir}/unowned-collision/docs.json"
printf '%s\n' '{"schemaVersion":"cjdoc.output/2","digestAlgorithm":"sha256","files":[]}' \
    >"${check_dir}/unowned-collision/.cjdoc-output.json"
set +e
"${binary}" generate --project tests/fixtures/projects/basic --format json \
    --output "${check_dir}/unowned-collision" --no-cache --force-owned \
    >/dev/null 2>"${check_dir}/unowned-collision.stderr"
unowned_collision_code=$?
set -e
test "${unowned_collision_code}" -eq 2
test "$(cat "${check_dir}/unowned-collision/docs.json")" = 'unowned'

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        mkdir -p "${check_dir}/symlink-target" "${check_dir}/symlink-output"
        printf '%s\n' '{"schemaVersion":"cjdoc.output/2","digestAlgorithm":"sha256","files":[]}' \
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

provider_project="${repo_root}/tests/fixtures/projects/provider_plugin"
provider_build_cache="${provider_project}/build-script-cache"
provider_target="${provider_project}/target"
test ! -e "${provider_build_cache}"
test ! -e "${provider_target}"
cleanup_provider_outputs() {
    rm -rf -- "${provider_build_cache}" "${provider_target}"
}
trap cleanup_provider_outputs EXIT
(cd "${provider_project}" && cjpm run)
cleanup_provider_outputs
trap - EXIT

echo "cjdoc acceptance gate passed"
