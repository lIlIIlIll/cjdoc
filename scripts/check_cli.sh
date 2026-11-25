# CLI acceptance checks sourced by scripts/check.sh.

stage_cli() {
    cd "${repo}"
    require_identity
    refuse_existing_outputs fixtures
    if [[ -n "${output_root}" ]]; then
        check_dir="${output_root}"
        prepare_workdir "${check_dir}"
    else
        "${python_cmd}" "${repo}/scripts/safe_output_root.py" --repo "${repo}" \
            --directory "${repo}/target/acceptance" --allow-missing >/dev/null
        check_dir="${repo}/target/acceptance"
        rm -rf "${check_dir}"
    fi
    mkdir -p "${check_dir}/schemas"
    cleanup_cli() {
        if [[ "${cli_cleaned}" == "1" ]]; then
            return 0
        fi
        cli_cleaned=1
        while IFS= read -r owned; do
            owned="${owned%$'\r'}"
            [[ -z "${owned}" ]] && continue
            remove_owned_outputs "${owned}"
        done < <(existing_build_outputs fixtures)
    }
    trap cleanup_cli EXIT

    if [[ -z "${main_binary}" ]]; then
        main_binary="${repo}/target/release/bin/main"
        if [[ -f "${main_binary}.exe" ]]; then
            main_binary="${main_binary}.exe"
        fi
    fi
    if [[ -z "${worker_binary}" ]]; then
        worker_binary="$(resolve_worker_binary)"
    fi
    export CJDOC_CHIR_WORKER="${worker_binary}"
    local binary="${main_binary}"
    check_cli_wire "${binary}" "${check_dir}"
    check_cli_roundtrip "${binary}" "${check_dir}"
    check_cli_agent_publication "${binary}" "${check_dir}"
    check_cli_versions "${binary}" "${check_dir}"
    check_cli_rejections "${binary}" "${check_dir}"
    "${python_cmd}" scripts/test_api_parameter_compat.py --binary "${binary}" \
        --output "${check_dir}/api-parameter-compat"
    "${python_cmd}" scripts/test_png_idat.py --binary "${binary}" \
        --output "${check_dir}/png-idat"
    "${python_cmd}" scripts/check_cli_option_contract.py --binary "${binary}" \
        --output "${check_dir}/cli-option-contract"
    "${python_cmd}" scripts/test_conceptual_contract.py --binary "${binary}" \
        --output "${check_dir}/conceptual-contract"
    check_cli_output_ownership "${binary}" "${check_dir}"
    check_cli_external_artifacts "${binary}" "${check_dir}"
    cleanup_cli
    trap - EXIT
}

check_cli_wire() {
    local binary="$1" check_dir="$2"
    local entry published schema_name
    "${python_cmd}" scripts/check_doc_ir_limits.py --binary "${binary}" \
        --workdir "${check_dir}/doc-ir-limits"

    run_golden() {
        local name="$1"
        local project="$2"
        local expected="$3"
        shift 3
        "${binary}" generate --project "${project}" --semantic source --format json \
            --output "${check_dir}/${name}/first" --cache-dir "${check_dir}/cache/${name}" "$@" >/dev/null
        "${binary}" generate --project "${project}" --semantic source --format json \
            --output "${check_dir}/${name}/second" --cache-dir "${check_dir}/cache/${name}" "$@" >/dev/null
        if ! cmp -s "${expected}" "${check_dir}/${name}/first/docs.json"; then
            diff -u --label "expected ${name}" --label "generated ${name}" \
                "${expected}" "${check_dir}/${name}/first/docs.json" \
                >"${check_dir}/${name}/golden.diff" 2>&1 || true
            cat "${check_dir}/${name}/golden.diff"
            return 1
        fi
        cmp "${check_dir}/${name}/first/docs.json" "${check_dir}/${name}/second/docs.json"
        "${binary}" render --input "${check_dir}/${name}/first/docs.json" \
            --format json --stdout | tr -d '\r' >"${check_dir}/${name}/validated.json"
        cmp "${check_dir}/${name}/first/docs.json" "${check_dir}/${name}/validated.json"
    }

    "${binary}" generate --project tests/fixtures/projects/chir_semantics \
        --semantic chir --chir-worker "${worker_binary}" --format json --stdout \
        >"${check_dir}/chir-worker-cli.json" 2>"${check_dir}/chir-worker-cli.stderr"
    "${python_cmd}" -c 'import json,sys; document=json.load(open(sys.argv[1], encoding="utf-8")); names={item["name"] for item in document["declarations"]}; assert document["providers"][0]["name"]=="chir" and {"State","extra"} <= names and not any(item["code"]=="CJDOC2101" for item in document["diagnostics"])' \
        "${check_dir}/chir-worker-cli.json"

    "${binary}" generate --project tests/fixtures/projects/basic \
        --format json --stdout >"${check_dir}/chir-default-cli.json" \
        2>"${check_dir}/chir-default-cli.stderr"
    "${python_cmd}" -c 'import json,sys; document=json.load(open(sys.argv[1], encoding="utf-8")); assert len(document["declarations"])==25 and document["providers"][0]["name"]=="chir" and not any(item["code"]=="CJDOC2101" for item in document["diagnostics"])' \
        "${check_dir}/chir-default-cli.json"

    "${python_cmd}" scripts/check_schemas.py --repo . --binary "${binary}" \
        --output "${check_dir}/schemas"

    run_golden basic tests/fixtures/projects/basic tests/fixtures/golden-v19/basic.docs.json
    run_golden functions tests/fixtures/projects/functions tests/fixtures/golden-v19/functions.docs.json
    run_golden types tests/fixtures/projects/types tests/fixtures/golden-v19/types.docs.json
    run_golden extend tests/fixtures/projects/extend_visibility tests/fixtures/golden-v19/extend.docs.json
    run_golden source-edges "${source_edges_project}" tests/fixtures/golden-v19/source-edges.docs.json
    run_golden unsupported tests/fixtures/projects/unsupported tests/fixtures/golden-v19/unsupported.docs.json
    run_golden workspace tests/fixtures/projects/workspace tests/fixtures/golden-v19/workspace.docs.json
    run_golden conditional-linux tests/fixtures/projects/conditional \
        tests/fixtures/golden-v19/conditional-linux.docs.json --cfg os=Linux
    run_golden path-dependencies tests/fixtures/projects/path_dependencies \
        tests/fixtures/golden-v19/path-dependencies.docs.json --include-path-dependencies
}

check_cli_roundtrip() {
    local binary="$1" check_dir="$2"
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
    "${python_cmd}" scripts/test_package_overviews.py --binary "${binary}" \
        --output "${check_dir}/package-overviews"
}

check_cli_agent_publication() {
    local binary="$1" check_dir="$2"
    local language
    rm -rf "${check_dir}/agent" "${check_dir}/agent-second" \
        "${check_dir}/versions" "${check_dir}/versions-second" \
        "${check_dir}/versions-v1" "${check_dir}/api-diff-v1.json"
    # Fixed query expectations require a complete source inventory, independent
    # of optional CHIR capability. The all/first and all/second gates above
    # exercise default CHIR with every ordinary output format.
    "${binary}" generate --project tests/fixtures/projects/basic --semantic source --format html --format api-surface --agent-full --doc-version 1.3.0 --output "${check_dir}/agent" --cache-dir "${check_dir}/cache/agent" >/dev/null
    "${binary}" generate --project tests/fixtures/projects/basic --semantic source --format html --format api-surface --agent-full --doc-version 1.3.0 --output "${check_dir}/agent-second" --cache-dir "${check_dir}/cache/agent" >/dev/null
    diff -qr "${check_dir}/agent/html" "${check_dir}/agent-second/html"
    test -f "${check_dir}/agent/html/navigation-index.json"
    test -f "${check_dir}/agent/html/llms.txt"
    test -f "${check_dir}/agent/html/llms-full.txt"
    "${python_cmd}" scripts/validate_html_site.py "${check_dir}/agent/html"
    # The integration check reads the real generated document root: navigation
    # continuations, the full-reference index, the manifest, every declaration
    # and page artifact, plus schema export equality with docs/schema.
    "${python_cmd}" scripts/test_agent_artifacts.py --binary "${binary}" \
        --root "${check_dir}/agent/html"
    # One independently expected fixture drives the CLI, live MCP session and
    # kernel actually published in this site's identical bounded projection.
    "${python_cmd}" scripts/test_query_mcp.py --binary "${binary}" \
        --snapshot "${check_dir}/agent/html/agent/manifest.json" \
        --search-cases tests/fixtures/query-semantics/cases.json \
        --static-site "${check_dir}/agent/html"
    "${binary}" generate --project tests/fixtures/projects/declaration-tags --semantic source \
        --format json --format html --format markdown --all-languages --agent-full \
        --output "${check_dir}/declaration-tags" \
        --cache-dir "${check_dir}/cache/declaration-tags" >/dev/null
    for language in en zh-CN; do
        "${python_cmd}" scripts/test_query_mcp.py --binary "${binary}" \
            --snapshot "${check_dir}/declaration-tags/html/${language}/agent/manifest.json" \
            --search-cases tests/fixtures/query-semantics/cases.json \
            --static-site "${check_dir}/declaration-tags/html/${language}"
        "${python_cmd}" scripts/test_agent_artifacts.py --binary "${binary}" \
            --root "${check_dir}/declaration-tags/html/${language}"
    done
    "${python_cmd}" scripts/test_declaration_metadata.py --binary "${binary}" \
        --output-root "${check_dir}/metadata-replay"
    "${python_cmd}" scripts/test_admonitions.py --binary "${binary}" \
        --output "${check_dir}/admonitions"
    "${python_cmd}" scripts/test_source_provenance.py --binary "${binary}" \
        --output "${check_dir}/source-provenance"
    "${python_cmd}" scripts/test_doc_ir_gc.py --binary "${binary}" \
        --snapshot "${check_dir}/all/first/docs.json"
    "${python_cmd}" -c 'import json,sys; root=sys.argv[1]; nav=json.load(open(root+"/navigation-index.json", encoding="utf-8")); assert nav["schemaVersion"]=="cjdoc.navigation-index/2" and nav["project"]["version"]=="1.3.0" and any(page["kind"]=="symbol" for page in nav["pages"]); assert "1.3.0" in open(root+"/llms.txt", encoding="utf-8").read() and len(open(root+"/llms-full.txt", encoding="utf-8").read().encode()) <= 16*1024*1024' "${check_dir}/agent/html"
}

check_cli_versions() {
    local binary="$1" check_dir="$2"
    local version_traversal_code
    "${binary}" diff --baseline "${check_dir}/agent/api-surface/api-surface.json" --current "${check_dir}/agent-second/api-surface/api-surface.json" --format json >"${check_dir}/agent/api-diff.json"
    "${binary}" versions compose --version 1.2.0="${check_dir}/all/first/html" --version 1.3.0="${check_dir}/agent/html" --diff 1.3.0="${check_dir}/agent/api-diff.json" --latest 1.3.0 --output "${check_dir}/versions" >/dev/null
    "${binary}" versions compose --version 1.2.0="${check_dir}/all/first/html" --version 1.3.0="${check_dir}/agent/html" --diff 1.3.0="${check_dir}/agent/api-diff.json" --latest 1.3.0 --output "${check_dir}/versions-second" >/dev/null
    diff -qr "${check_dir}/versions" "${check_dir}/versions-second"
    "${python_cmd}" -c 'import json,sys; root=sys.argv[1]; value=json.load(open(root+"/versions.json", encoding="utf-8")); assert value["schemaVersion"]=="cjdoc.versions/2" and value["latest"]=="1.3.0" and value["versions"][1]["apiDiff"]=="1.3.0/api-diff.json"; assert json.load(open(root+"/1.3.0/navigation-index.json", encoding="utf-8"))["schemaVersion"]=="cjdoc.navigation-index/2"; assert json.load(open(root+"/1.3.0/api-diff.json", encoding="utf-8"))["schemaVersion"]=="cjdoc.api-diff/2"' "${check_dir}/versions"
    "${python_cmd}" - "${check_dir}/api-diff-v1.json" <<'PY'
import json
import pathlib
import sys

identity = {
    "project": "basic",
    "audience": "external",
    "cfgProfile": "default",
    "schemaVersion": "cjdoc.api-surface/2",
    "collectionState": "resolved",
}
report = {
    "schemaVersion": "cjdoc.api-diff/1",
    "baseline": identity,
    "current": identity,
    "comparisonState": "resolved",
    "summary": {
        "breaking": 0,
        "potentiallyBreaking": 0,
        "additive": 0,
        "documentationOnly": 0,
        "metadataOnly": 0,
        "unchanged": 0,
    },
    "entries": [],
}
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(report, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
    "${binary}" versions compose \
        --version 1.2.0="${check_dir}/all/first/html" \
        --version 1.3.0="${check_dir}/agent/html" \
        --diff 1.3.0="${check_dir}/api-diff-v1.json" \
        --latest 1.3.0 \
        --output "${check_dir}/versions-v1" >/dev/null
    "${python_cmd}" -c 'import json,pathlib,sys; root=pathlib.Path(sys.argv[1]); expected=pathlib.Path(sys.argv[2]).read_bytes(); manifest=json.loads((root/"versions.json").read_text(encoding="utf-8")); assert manifest["versions"][1]["apiDiff"]=="1.3.0/api-diff.json"; assert (root/"1.3.0/api-diff.json").read_bytes()==expected' \
        "${check_dir}/versions-v1" "${check_dir}/api-diff-v1.json"
    set +e
    "${binary}" versions compose --version ../bad="${check_dir}/all/first/html" --output "${check_dir}/versions-bad" >/dev/null 2>"${check_dir}/versions-bad.stderr"
    version_traversal_code=$?
    set -e
    test "${version_traversal_code}" -eq 2
    test -s "${check_dir}/versions-bad.stderr"
}

check_cli_rejections() {
    local binary="$1" check_dir="$2"
    local strict_code invalid_code render_invalid_code resource_limit_code
    "${binary}" generate --project tests/fixtures/projects/basic --format json --stdout \
        --cache-dir "${check_dir}/cache/stdout" >"${check_dir}/stdout.json"
    "${python_cmd}" -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); assert value["schemaVersion"] == "cjdoc.doc-ir/19" and len(value["declarations"]) == 25' \
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
}

check_cli_output_ownership() {
    local binary="$1" check_dir="$2"
    local ownership_code missing_manifest_code unowned_collision_code symlink_code
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
    printf '%s\n' '{"schemaVersion":"cjdoc.output/3","digestAlgorithm":"sha256","files":[],"directories":[]}' \
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
            printf '%s\n' '{"schemaVersion":"cjdoc.output/3","digestAlgorithm":"sha256","files":[],"directories":[]}' \
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
}

check_cli_external_artifacts() {
    local binary="$1" check_dir="$2"
    "${python_cmd}" -m unittest scripts.test_fixture_contracts
    "${python_cmd}" scripts/i18n_gate.py --binary "${binary}" --repo "${repo}" \
        --workdir "${check_dir}/i18n"
    "${python_cmd}" scripts/external_snapshot_gate.py --binary "${binary}" \
        --workdir "${check_dir}/external-snapshot"
    "${python_cmd}" scripts/validate_html_site.py "${check_dir}/i18n/multi/html/en" \
        --publication-root "${check_dir}/i18n/multi/html"
    "${python_cmd}" scripts/validate_html_site.py "${check_dir}/i18n/multi/html/zh-CN" \
        --publication-root "${check_dir}/i18n/multi/html"
}
