#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_runner="${CJDOC_CANGJIE_RUNNER:-${repo_root}/scripts/cangjie_env_runner.sh}"
check_dir="${repo_root}/target/cjdoc-check"
binary="${repo_root}/target/release/bin/main"
schema="${repo_root}/docs/schema/doc-ir.schema.json"
schema_validator="${repo_root}/scripts/validate_schema.py"
html_validator="${repo_root}/scripts/validate_html_site.py"
search_schema="${repo_root}/docs/schema/search-index.schema.json"
cfg_matrix_schema="${repo_root}/docs/schema/cfg-matrix.schema.json"

"${env_runner}" --cwd "${repo_root}" cjpm clean
"${env_runner}" --cwd "${repo_root}" cjpm build
if [[ ! -x "${binary}" && -x "${binary}.exe" ]]; then
    binary="${binary}.exe"
fi
test -x "${binary}"
"${env_runner}" --cwd "${repo_root}/packages/cjdoc_core" cjpm test
jq -e . "${schema}" >/dev/null
jq -e . "${search_schema}" >/dev/null
jq -e . "${cfg_matrix_schema}" >/dev/null

rm -rf "${check_dir}"
mkdir -p "${check_dir}"

run_golden() {
    local name="$1"
    local project="$2"
    local expected="$3"
    shift 3
    mkdir -p "${check_dir}/${name}/first" "${check_dir}/${name}/second"
    "${env_runner}" --cwd "${repo_root}" "${binary}" \
        --project "${project}" --format json \
        --output "${check_dir}/${name}/first/docs.json" "$@"
    "${env_runner}" --cwd "${repo_root}" "${binary}" \
        --project "${project}" --format json \
        --output "${check_dir}/${name}/second/docs.json" "$@"
    jq -e '.schemaVersion == "cjdoc.doc-ir/4"' "${check_dir}/${name}/first/docs.json" >/dev/null
    "${schema_validator}" "${schema}" "${check_dir}/${name}/first/docs.json"
    jq -e '([.symbols[].id] as $ids | all(.symbols[]; .ownerId as $owner | ($owner == null or ($ids | index($owner) != null))))' \
        "${check_dir}/${name}/first/docs.json" >/dev/null
    jq -e '([.project.modules[].id] as $ids | all(.project.modules[]; all(.dependencyIds[]; . as $dependency | ($ids | index($dependency) != null))))' \
        "${check_dir}/${name}/first/docs.json" >/dev/null
    jq -e '([.project.modules[].id] as $ids | ($ids | unique | length) == ($ids | length))' \
        "${check_dir}/${name}/first/docs.json" >/dev/null
    cmp "${expected}" "${check_dir}/${name}/first/docs.json"
    cmp "${check_dir}/${name}/first/docs.json" "${check_dir}/${name}/second/docs.json"
    if rp-rg -n '/home/|/tmp/' "${check_dir}/${name}/first/docs.json"; then
        echo "absolute path leaked into ${name} docs.json" >&2
        exit 1
    fi
}

run_markdown_golden() {
    local name="$1"
    local project="$2"
    local expected="$3"
    shift 3
    mkdir -p "${check_dir}/${name}/first" "${check_dir}/${name}/second"
    "${env_runner}" --cwd "${repo_root}" "${binary}" \
        --project "${project}" --format markdown \
        --output "${check_dir}/${name}/first/docs.md" "$@"
    "${env_runner}" --cwd "${repo_root}" "${binary}" \
        --project "${project}" --format markdown \
        --output "${check_dir}/${name}/second/docs.md" "$@"
    cmp "${expected}" "${check_dir}/${name}/first/docs.md"
    cmp "${check_dir}/${name}/first/docs.md" "${check_dir}/${name}/second/docs.md"
    if rp-rg -n '/home/|/tmp/' "${check_dir}/${name}/first/docs.md"; then
        echo "absolute path leaked into ${name} docs.md" >&2
        exit 1
    fi
}

run_golden basic "${repo_root}/tests/fixtures/projects/basic" \
    "${repo_root}/tests/fixtures/golden/basic.expected.json" --lint-missing-params
run_golden functions "${repo_root}/tests/fixtures/projects/functions" \
    "${repo_root}/tests/fixtures/golden/functions.expected.json" --lint-missing-params
run_golden types "${repo_root}/tests/fixtures/projects/types" \
    "${repo_root}/tests/fixtures/golden/types.expected.json" --lint-missing-params
run_golden extend_visibility "${repo_root}/tests/fixtures/projects/extend_visibility" \
    "${repo_root}/tests/fixtures/golden/extend_visibility.expected.json"
run_golden extend_visibility_public "${repo_root}/tests/fixtures/projects/extend_visibility" \
    "${repo_root}/tests/fixtures/golden/extend_visibility.public.expected.json" --public-only
run_golden lint "${repo_root}/tests/fixtures/projects/lint" \
    "${repo_root}/tests/fixtures/golden/lint.expected.json" --lint-missing-params
run_golden source_edges "${repo_root}/tests/fixtures/projects/source_edges" \
    "${repo_root}/tests/fixtures/golden/source_edges.expected.json"
run_golden source_edges_public "${repo_root}/tests/fixtures/projects/source_edges" \
    "${repo_root}/tests/fixtures/golden/source_edges.public.expected.json" --public-only
run_golden unsupported "${repo_root}/tests/fixtures/projects/unsupported" \
    "${repo_root}/tests/fixtures/golden/unsupported.expected.json"
run_golden workspace "${repo_root}/tests/fixtures/projects/workspace" \
    "${repo_root}/tests/fixtures/golden/workspace.expected.json"
run_golden conditional "${repo_root}/tests/fixtures/projects/conditional" \
    "${repo_root}/tests/fixtures/golden/conditional.expected.json"
run_golden conditional_linux "${repo_root}/tests/fixtures/projects/conditional" \
    "${repo_root}/tests/fixtures/golden/conditional.linux.expected.json" --cfg os=Linux

mkdir -p "${check_dir}/cfg_matrix"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/conditional" --format json \
    --cfg-matrix-profile windows:os=Windows,arch=x86_64 \
    --cfg-matrix-profile linux:arch=x86_64,os=Linux \
    --output "${check_dir}/cfg_matrix/first.json"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/conditional" --format json \
    --cfg-matrix-profile linux:os=Linux,arch=x86_64 \
    --cfg-matrix-profile windows:arch=x86_64,os=Windows \
    --output "${check_dir}/cfg_matrix/second.json"
cmp "${repo_root}/tests/fixtures/golden/conditional.matrix.expected.json" \
    "${check_dir}/cfg_matrix/first.json"
cmp "${check_dir}/cfg_matrix/first.json" "${check_dir}/cfg_matrix/second.json"
"${schema_validator}" "${cfg_matrix_schema}" "${check_dir}/cfg_matrix/first.json"
if rp-rg -q '/home/|/tmp/' "${check_dir}/cfg_matrix/first.json"; then
    echo "absolute path leaked into cfg matrix" >&2
    exit 1
fi
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/conditional" --format json \
    --cfg-matrix-profile linux:os=Linux,arch=x86_64 \
    --cfg-matrix-profile windows:os=Windows,arch=x86_64 \
    --stdout --diagnostic-output "${check_dir}/cfg_matrix/stdout-diagnostics.txt" \
    >"${check_dir}/cfg_matrix/stdout.json"
cmp "${check_dir}/cfg_matrix/first.json" "${check_dir}/cfg_matrix/stdout.json"
test ! -s "${check_dir}/cfg_matrix/stdout-diagnostics.txt"

set +e
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/lint_quality" --format json \
    --cfg-matrix-profile docs:docs=true --cfg-matrix-profile nodocs:docs=false \
    --lint-missing-params --lint-missing-symbols --deny-warnings \
    --diagnostic-format json \
    --diagnostic-output "${check_dir}/cfg_matrix/diagnostics.json" \
    --output "${check_dir}/cfg_matrix/lint.json"
cfg_matrix_lint_code=$?
set -e
test "${cfg_matrix_lint_code}" -eq 1
jq -e '(.diagnostics | length) > 0 and
    all(.diagnostics[]; (.message | startswith("[cfg profile")))' \
    "${check_dir}/cfg_matrix/diagnostics.json" >/dev/null
"${schema_validator}" "${cfg_matrix_schema}" "${check_dir}/cfg_matrix/lint.json"
run_golden path_dependencies "${repo_root}/tests/fixtures/projects/path_dependencies" \
    "${repo_root}/tests/fixtures/golden/path_dependencies.expected.json" --include-path-dependencies
run_golden override "${repo_root}/tests/fixtures/projects/override" \
    "${repo_root}/tests/fixtures/golden/override.expected.json"

mkdir -p "${check_dir}/parallel"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/basic" --format json \
    --lint-missing-params --jobs 4 --output "${check_dir}/parallel/basic.json"
cmp "${repo_root}/tests/fixtures/golden/basic.expected.json" "${check_dir}/parallel/basic.json"
"${schema_validator}" "${schema}" "${check_dir}/parallel/basic.json"

mkdir -p "${check_dir}/cli"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/functions" --format json \
    --lint-missing-params --stdout --diagnostic-output "${check_dir}/cli/diagnostics.txt" \
    >"${check_dir}/cli/stdout.json"
cmp "${repo_root}/tests/fixtures/golden/functions.expected.json" "${check_dir}/cli/stdout.json"
test ! -s "${check_dir}/cli/diagnostics.txt"

set +e
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/lint_quality" --format json \
    --lint-missing-params --lint-missing-symbols --deny-warnings \
    --diagnostic-format json --diagnostic-output "${check_dir}/cli/diagnostics.json" \
    --output "${check_dir}/cli/lint-quality.json"
lint_quality_code=$?
set -e
test "${lint_quality_code}" -eq 1
jq -e '.schemaVersion == "cjdoc.diagnostics/1" and ([.diagnostics[].code] | index("CJDOC1025") != null)' \
    "${check_dir}/cli/diagnostics.json" >/dev/null

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/lint_quality" --format json \
    --diagnostic-format sarif --diagnostic-output "${check_dir}/cli/diagnostics.sarif" \
    --output "${check_dir}/cli/lint-quality-sarif.json"
jq -e '.version == "2.1.0" and .runs[0].tool.driver.name == "cjdoc"' \
    "${check_dir}/cli/diagnostics.sarif" >/dev/null

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/cached_dependencies" --format json \
    --include-cached-dependencies --cjpm-cache "${repo_root}/tests/fixtures/cjpm_cache" \
    --output "${check_dir}/cli/cached-dependencies.json"
jq -e '(.symbols | length) == 3 and (.project.modules | length) == 3 and
    ([.project.modules[] | select(.name == "cached_dep") | .dependencyIds[]] |
        index("cjdoc:module:v1:external:transitive_dep") != null) and
    ([.diagnostics[].code] | index("CJDOC1021") != null)' \
    "${check_dir}/cli/cached-dependencies.json" >/dev/null

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/path_dependencies" \
    --output "${check_dir}/path_dependencies_root_only.json"
jq -e '(.packages|length == 1) and (.symbols|length == 1)' \
    "${check_dir}/path_dependencies_root_only.json" >/dev/null
jq -e '(.project.modules|length == 1) and (.project.modules[0].dependencyIds == [])' \
    "${check_dir}/path_dependencies_root_only.json" >/dev/null

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/path_dependencies_invalid" \
    --include-path-dependencies --output "${check_dir}/path_dependencies_invalid.json"
jq -e '(.symbols|length == 1) and ([.diagnostics[].code] == ["CJDOC1015", "CJDOC1016"])' \
    "${check_dir}/path_dependencies_invalid.json" >/dev/null

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/path_dependencies" \
    --dependency-source "offline_alpha=${repo_root}/tests/fixtures/projects/path_dependencies/deps/alpha" \
    --dependency-source "offline_beta=${repo_root}/tests/fixtures/projects/path_dependencies/deps/beta" \
    --output "${check_dir}/offline_dependency_sources.json"
"${schema_validator}" "${schema}" "${check_dir}/offline_dependency_sources.json"
jq -e '([.project.modules[].role] | index("externalDependency") != null) and
    ([.symbols[].documentation.see[]?.state] | index("resolved") != null)' \
    "${check_dir}/offline_dependency_sources.json" >/dev/null
if rp-rg -q '/home/|/tmp/' "${check_dir}/offline_dependency_sources.json"; then
    echo "absolute dependency source path leaked into docs.json" >&2
    exit 1
fi

run_markdown_golden markdown_basic "${repo_root}/tests/fixtures/projects/basic" \
    "${repo_root}/tests/fixtures/golden/basic.expected.md" --lint-missing-params
run_markdown_golden markdown_functions "${repo_root}/tests/fixtures/projects/functions" \
    "${repo_root}/tests/fixtures/golden/functions.expected.md" --lint-missing-params
run_markdown_golden markdown_types "${repo_root}/tests/fixtures/projects/types" \
    "${repo_root}/tests/fixtures/golden/types.expected.md" --lint-missing-params
run_markdown_golden markdown_extend "${repo_root}/tests/fixtures/projects/extend_visibility" \
    "${repo_root}/tests/fixtures/golden/extend_visibility.expected.md"
run_markdown_golden markdown_source_edges "${repo_root}/tests/fixtures/projects/source_edges" \
    "${repo_root}/tests/fixtures/golden/source_edges.expected.md"

run_html_golden() {
    local name="$1"
    local project="$2"
    local expected="$3"
    shift 3
    mkdir -p "${check_dir}/${name}"
    "${env_runner}" --cwd "${repo_root}" "${binary}" \
        --project "${project}" --format html --output "${check_dir}/${name}/first" "$@"
    "${env_runner}" --cwd "${repo_root}" "${binary}" \
        --project "${project}" --format html --output "${check_dir}/${name}/second" "$@"
    diff -ru "${expected}" "${check_dir}/${name}/first"
    diff -ru "${check_dir}/${name}/first" "${check_dir}/${name}/second"
    "${html_validator}" "${check_dir}/${name}/first"
    "${schema_validator}" "${search_schema}" "${check_dir}/${name}/first/search-index.json"
}

run_html_golden html_functions "${repo_root}/tests/fixtures/projects/functions" \
    "${repo_root}/tests/fixtures/golden/html_functions" --lint-missing-params

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/functions" --format html \
    --output "${check_dir}/html_source_links" \
    --source-url-template 'https://example.test/repo/blob/main/{path}#L{line}C{column}'
"${html_validator}" "${check_dir}/html_source_links"
rp-rg -q 'class="source-link" href="https://example.test/repo/blob/main/src/fixture.cj#L[0-9]+C[0-9]+"' \
    "${check_dir}/html_source_links/packages/package-functions_fixture.html"

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/path_dependencies" --format html \
    --include-path-dependencies --output "${check_dir}/html_path_dependencies"
"${html_validator}" "${check_dir}/html_path_dependencies"
test -f "${check_dir}/html_path_dependencies/packages/package-path_dep_alpha.html"
test -f "${check_dir}/html_path_dependencies/packages/package-path_dep_beta.html"
rp-rg -q '<h2>Modules</h2>' "${check_dir}/html_path_dependencies/index.html"
rp-rg -q 'href="#module-cjdoc_3amodule_3av1_3apath_3apath_dep_beta"' \
    "${check_dir}/html_path_dependencies/index.html"

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/path_dependencies" --format html \
    --include-path-dependencies --output "${check_dir}/html_dependency_source_links" \
    --dependency-source-url 'path_dep_alpha=https://example.test/alpha/blob/{revision}/{path}#L{line}C{column}' \
    --dependency-revision 'path_dep_alpha=release/1.0'
"${html_validator}" "${check_dir}/html_dependency_source_links"
rp-rg -q 'class="source-link" href="https://example.test/alpha/blob/release/1.0/src/alpha.cj#L[0-9]+C[0-9]+"' \
    "${check_dir}/html_dependency_source_links/packages/package-path_dep_alpha.html"
if rp-rg -q 'class="source-link"' \
    "${check_dir}/html_dependency_source_links/packages/package-path_dep_beta.html"; then
    echo "unconfigured dependency received a guessed source link" >&2
    exit 1
fi

"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/basic" --format html \
    --output "${check_dir}/html_stale_cleanup" >/dev/null
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/functions" --format html \
    --output "${check_dir}/html_stale_cleanup" --lint-missing-params
diff -ru "${repo_root}/tests/fixtures/golden/html_functions" "${check_dir}/html_stale_cleanup"

incremental_json="${check_dir}/incremental/docs.json"
mkdir -p "${check_dir}/incremental"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/basic" --format json \
    --lint-missing-params --output "${incremental_json}"
json_inode_before="$(python3 "${repo_root}/scripts/portable_probe.py" inode "${incremental_json}")"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/basic" --format json \
    --lint-missing-params --output "${incremental_json}"
json_inode_after="$(python3 "${repo_root}/scripts/portable_probe.py" inode "${incremental_json}")"
test "${json_inode_before}" = "${json_inode_after}"

incremental_html="${check_dir}/incremental/html"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/functions" --format html \
    --lint-missing-params --output "${incremental_html}"
html_inode_before="$(python3 "${repo_root}/scripts/portable_probe.py" inode "${incremental_html}/index.html")"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/functions" --format html \
    --lint-missing-params --output "${incremental_html}"
html_inode_after="$(python3 "${repo_root}/scripts/portable_probe.py" inode "${incremental_html}/index.html")"
test "${html_inode_before}" = "${html_inode_after}"

mkdir -p "${check_dir}/html_security"
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/html_security" --format html \
    --output "${check_dir}/html_security/site"
"${html_validator}" "${check_dir}/html_security/site"
if rp-rg -n '<script>alert|href="javascript:|src="javascript:|<[^>]+[[:space:]]onerror=' \
    "${check_dir}/html_security/site" -g '*.html'; then
    echo "unsafe documentation reached generated HTML" >&2
    exit 1
fi

default_markdown_project="${check_dir}/default-markdown-project"
mkdir -p "${default_markdown_project}/src"
cp "${repo_root}/tests/fixtures/projects/functions/cjpm.toml" "${default_markdown_project}/cjpm.toml"
cp "${repo_root}/tests/fixtures/projects/functions/src/fixture.cj" "${default_markdown_project}/src/fixture.cj"
"${env_runner}" --cwd "${repo_root}" "${binary}" --project "${default_markdown_project}" --format markdown
cmp "${repo_root}/tests/fixtures/golden/functions.expected.md" \
    "${default_markdown_project}/target/doc/docs.md"

default_html_project="${check_dir}/default-html-project"
mkdir -p "${default_html_project}/src"
cp "${repo_root}/tests/fixtures/projects/functions/cjpm.toml" "${default_html_project}/cjpm.toml"
cp "${repo_root}/tests/fixtures/projects/functions/src/fixture.cj" "${default_html_project}/src/fixture.cj"
"${env_runner}" --cwd "${repo_root}" "${binary}" --project "${default_html_project}" --format html
diff -ru "${repo_root}/tests/fixtures/golden/html_functions" \
    "${default_html_project}/target/doc/html"
"${html_validator}" "${default_html_project}/target/doc/html"

mkdir -p "${check_dir}/recovery"
set +e
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/recovery" --format json \
    --output "${check_dir}/recovery/docs.json"
recovery_code=$?
set -e
test "${recovery_code}" -eq 1
cmp "${repo_root}/tests/fixtures/golden/recovery.expected.json" "${check_dir}/recovery/docs.json"
jq -e '(.diagnostics | map(.code) | index("CJDOC1011")) != null and (.symbols | length == 1)' \
    "${check_dir}/recovery/docs.json" >/dev/null
"${schema_validator}" "${schema}" "${check_dir}/recovery/docs.json"

mkdir -p "${check_dir}/deep_binary"
set +e
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/deep_binary" --format json \
    --output "${check_dir}/deep_binary/docs.json"
deep_binary_code=$?
set -e
test "${deep_binary_code}" -eq 1
cmp "${repo_root}/tests/fixtures/golden/deep_binary.expected.json" \
    "${check_dir}/deep_binary/docs.json"
jq -e '(.diagnostics | map(.code) | index("CJDOC1012")) != null and (.symbols | length == 0)' \
    "${check_dir}/deep_binary/docs.json" >/dev/null
"${schema_validator}" "${schema}" "${check_dir}/deep_binary/docs.json"
mkdir -p "${check_dir}/deep_binary_parallel"
set +e
"${env_runner}" --cwd "${repo_root}" "${binary}" \
    --project "${repo_root}/tests/fixtures/projects/deep_binary" --format json --jobs 4 \
    --output "${check_dir}/deep_binary_parallel/docs.json"
deep_binary_parallel_code=$?
set -e
test "${deep_binary_parallel_code}" -eq 1
cmp "${check_dir}/deep_binary/docs.json" "${check_dir}/deep_binary_parallel/docs.json"

jq '.schemaVersion = "invalid"' "${check_dir}/recovery/docs.json" >"${check_dir}/invalid-schema.json"
set +e
"${schema_validator}" "${schema}" "${check_dir}/invalid-schema.json" >/dev/null 2>&1
invalid_schema_code=$?
set -e
test "${invalid_schema_code}" -eq 1

for invalid_project in duplicate workspace_invalid; do
    rm -f "${check_dir}/${invalid_project}.json"
    set +e
    "${env_runner}" --cwd "${repo_root}" "${binary}" \
        --project "${repo_root}/tests/fixtures/projects/${invalid_project}" \
        --output "${check_dir}/${invalid_project}.json" >/dev/null
    invalid_project_code=$?
    set -e
    test "${invalid_project_code}" -eq 1
    test ! -e "${check_dir}/${invalid_project}.json"
done

for valid_project in basic functions types extend_visibility lint source_edges unsupported workspace conditional deep_binary html_security path_dependencies override; do
    "${env_runner}" --cwd "${repo_root}/tests/fixtures/projects/${valid_project}" cjpm build
done

provider_plugin="${repo_root}/tests/fixtures/projects/provider_plugin"
test "$("${env_runner}" --cwd "${provider_plugin}" cjpm run)" = $'provider plugin ok\n\ncjpm run finished'

test "$("${repo_root}/cjdoc" --version)" = "cjdoc 0.3.0"
"${repo_root}/cjdoc" --help | rp-rg -q '^usage: cjdoc '
set +e
"${repo_root}/cjdoc" --format pdf >/dev/null
format_code=$?
"${repo_root}/cjdoc" --project "${check_dir}/missing" --output "${check_dir}/missing.json" >/dev/null
missing_code=$?
set -e
test "${format_code}" -eq 2
test "${missing_code}" -eq 1
test ! -e "${check_dir}/missing.json"

install_root="${check_dir}/install"
"${env_runner}" --cwd "${repo_root}" cjpm install --path "${repo_root}" --root "${install_root}"
installed_binary="${install_root}/bin/cjdoc"
if [[ ! -x "${installed_binary}" && -x "${installed_binary}.exe" ]]; then
    installed_binary="${installed_binary}.exe"
fi
test -x "${installed_binary}"
test "$("${env_runner}" "${installed_binary}" --version)" = "cjdoc 0.3.0"

"${repo_root}/scripts/perf_gate.sh"

echo "cjdoc acceptance checks passed"
