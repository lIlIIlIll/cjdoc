#!/usr/bin/env bash
# Staged acceptance gate for cjdoc.
#
# With no arguments this runs the complete local gate:
#   preflight -> build -> native -> python-tools -> cli -> provider
#
# CI and Pages call only the stages they need, so no orchestration repeats the
# whole gate. Every stage records machine-readable timing, identity and cache
# evidence through scripts/ci_stage.py. Callers that compile with the pinned STS
# toolchain must source scripts/with_sts_o1_cjpm.sh first, exactly as before.
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
python_cmd="${CJDOC_PYTHON:-python3}"
evidence_root="${CJDOC_CI_EVIDENCE:-${repo_root}/target/ci-evidence}"
fixture_project_root="${repo_root}/tests/fixtures/projects"
worker_project="${repo_root}/tools/chir-worker"
source_edges_project="${CJDOC_SOURCE_EDGES_PROJECT:-tests/fixtures/projects/source_edges}"
unset CJDOC_SOURCE_EDGES_PROJECT CJDOC_SOURCE_EDGES_COMMIT CJDOC_SOURCE_EDGES_TREE

usage() {
    cat <<'EOF'
Usage: check.sh [stage [options]]

Stages:
  (none)        complete local gate: preflight, build, native, python-tools, cli, provider
  preflight     tracked repository inputs and SDK-installer/stdx unit tests
  build         compile cjdoc and the CHIR worker, then write a build manifest
  native        cjpm test for the Cangjie unit suites
  python-tools  python -m unittest discover -s scripts (minus preflight modules)
  cli           CLI, schema, golden, HTML, output-safety and fixture contracts
  provider      provider-plugin fixture run
  smoke         real-repository smoke against a fresh two-run output tree

Common options:
  --repo DIR           repository root (default: this script's parent)
  --evidence DIR       ci_stage evidence directory
  --identity PATH      build manifest used to re-verify artifact identity
  --workdir DIR        stage-private writable root (must not already exist)
  --output-root DIR    stage-private output root for CLI artifacts

Build only:
  --main-binary-out PATH --worker-binary-out PATH --manifest PATH

Binary-consuming stages:
  --main-binary PATH --worker-binary PATH
EOF
}

stage_id=""
inner=""
original_args=("$@")
repo="${repo_root}"
evidence_dir="${evidence_root}"

identity=""
workdir=""
output_root=""
main_binary=""
worker_binary=""
main_binary_out=""
worker_binary_out=""
manifest=""

if [[ $# -gt 0 && "$1" == "--inner" ]]; then
    inner="$2"
    stage_id="$2"
    shift 2
elif [[ $# -gt 0 && "$1" != -* ]]; then
    stage_id="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inner) inner="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --evidence) evidence_dir="$2"; shift 2 ;;
        --identity) identity="$2"; shift 2 ;;
        --workdir) workdir="$2"; shift 2 ;;
        --output-root) output_root="$2"; shift 2 ;;
        --main-binary) main_binary="$2"; shift 2 ;;
        --worker-binary) worker_binary="$2"; shift 2 ;;
        --main-binary-out) main_binary_out="$2"; shift 2 ;;
        --worker-binary-out) worker_binary_out="$2"; shift 2 ;;
        --manifest) manifest="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "${stage_id}" in
    ""|preflight|build|native|python-tools|cli|provider|smoke) ;;
    *) echo "check.sh: unknown stage: ${stage_id}" >&2; usage >&2; exit 2 ;;
esac

run_stage() {
    local id="$1" kind="$2"
    local inner_args=("${original_args[@]}")
    # The inner process learns its stage from --inner, so drop the stage token
    # that the caller may have spelled out explicitly.
    if [[ ${#inner_args[@]} -gt 0 && "${inner_args[0]}" != -* ]]; then
        inner_args=("${inner_args[@]:1}")
    fi
    "${python_cmd}" "${repo}/scripts/ci_stage.py" run \
        --id "${id}" --kind "${kind}" --evidence "${evidence_dir}" \
        -- "${BASH:-bash}" "${self_path}" --inner "${id}" "${inner_args[@]}"
}

# Map a stage name to its ci_stage kind.
stage_kind() {
    case "$1" in
        preflight|python-tools) echo python ;;
        build) echo build ;;
        native) echo native ;;
        cli) echo cli ;;
        provider) echo provider ;;
        smoke) echo smoke ;;
        *) echo "check.sh: unknown stage: $1" >&2; exit 2 ;;
    esac
}

dispatch_stage() {
    case "$1" in
        preflight) stage_preflight ;;
        build) stage_build ;;
        native) stage_native ;;
        python-tools) stage_python_tools ;;
        cli) stage_cli ;;
        provider) stage_provider ;;
        smoke) stage_smoke ;;
        *) echo "check.sh: unknown stage: $1" >&2; exit 2 ;;
    esac
}

# Refuse to guess when a consumer stage was handed an identity manifest.
require_identity() {
    if [[ -z "${identity}" ]]; then
        return 0
    fi
    local args=(--manifest "${identity}" --repo "${repo}")
    if [[ -n "${main_binary}" ]]; then
        args+=(--main-binary "${main_binary}")
    fi
    if [[ -n "${worker_binary}" ]]; then
        args+=(--worker-binary "${worker_binary}")
    fi
    "${python_cmd}" "${repo}/scripts/ci_stage.py" verify-identity "${args[@]}"
}

# Create a stage-private writable root, refusing reuse and symlinks so one stage
# can never adopt or destroy another stage's (or a user's) outputs.
prepare_workdir() {
    local target="$1"
    if [[ -z "${target}" ]]; then
        return 0
    fi
    "${python_cmd}" - "${target}" <<'PY'
import os
from pathlib import Path
import stat
import sys

target = Path(sys.argv[1])
for parent in list(target.absolute().parents)[::-1]:
    if parent.exists() and (parent.is_symlink() or not parent.is_dir()):
        raise SystemExit(f"stage workdir parent is not a directory: {parent}")
if target.exists() or target.is_symlink():
    raise SystemExit(f"stage workdir already exists; refusing reuse: {target}")
target.mkdir(parents=True)
mode = target.lstat().st_mode
if not stat.S_ISDIR(mode):
    raise SystemExit(f"stage workdir is not a directory: {target}")
PY
}

# List fixture/worker build outputs that exist, without following symlinks.
existing_build_outputs() {
    "${python_cmd}" - "${fixture_project_root}" "${worker_project}" "${1:-}" <<'PY'
from pathlib import Path
import stat
import sys

fixture_root = Path(sys.argv[1])
worker_project = Path(sys.argv[2])
scope = sys.argv[3]
found: list[str] = []
if scope in {"", "fixtures", "all"}:
    for entry in sorted(fixture_root.rglob("target"), key=lambda item: item.relative_to(fixture_root).as_posix()):
        if entry.is_symlink() or (entry.exists() and stat.S_ISDIR(entry.lstat().st_mode)):
            found.append(entry.relative_to(fixture_root.parent.parent).as_posix())
    # A regular file or special node named `target` is also a refusal: deleting it
    # could destroy user data that merely looks like a build directory.
    for entry in sorted(fixture_root.rglob("target")):
        if not entry.is_symlink() and entry.exists() and not stat.S_ISDIR(entry.lstat().st_mode):
            found.append(entry.relative_to(fixture_root.parent.parent).as_posix())
if scope in {"", "worker", "all"}:
    candidate = worker_project / "target"
    if candidate.is_symlink() or candidate.exists():
        found.append(candidate.relative_to(worker_project.parent.parent).as_posix())
print("\n".join(sorted(set(found))))
PY
}

# Delete only the build outputs owned by this stage, after lstat validation.
remove_owned_outputs() {
    "${python_cmd}" - "$@" <<'PY'
import shutil
from pathlib import Path
import stat
import sys

for value in sys.argv[1:]:
    if not value:
        continue
    target = Path(value)
    mode = target.lstat().st_mode if target.is_symlink() or target.exists() else None
    if target.is_symlink():
        target.unlink()
    elif mode is not None and stat.S_ISDIR(mode):
        shutil.rmtree(target)
    elif mode is not None:
        raise SystemExit(f"owned build output is not a directory: {target}")
PY
}

refuse_existing_outputs() {
    local scope="$1"
    local existing
    existing="$(existing_build_outputs "${scope}")"
    if [[ -n "${existing}" ]]; then
        printf '%s\n' "build output already exists; refusing destructive cleanup:" >&2
        printf '%s\n' "${existing}" >&2
        exit 1
    fi
}

stage_preflight() {
    cd "${repo}"
    "${python_cmd}" scripts/verify_repository_inputs.py --repo "${repo}" --require-tracked
    "${python_cmd}" -m unittest scripts.test_install_cangjie_sdk scripts.test_with_stdx
}

stage_build() {
    cd "${repo}"
    "${python_cmd}" "${repo}/scripts/safe_output_root.py" --repo "${repo}" \
        --directory "${repo}/target" --create >/dev/null
    if [[ -n "${main_binary_out}" ]]; then
        "${python_cmd}" "${repo}/scripts/safe_output_root.py" --repo "${repo}" \
            --directory "$(dirname "${main_binary_out}")" --allow-missing >/dev/null
    fi
    # An ignored-but-present worker build tree makes the repository-input gate
    # fail closed, and deleting a pre-existing one could destroy user data, so
    # refuse first and clean only what this stage creates.
    refuse_existing_outputs worker
    # Keep project compilation single-job; STS 1.2.0's bundled llc has crashed under concurrent CI jobs.
    cjpm build --jobs 1
    local binary="${repo}/target/release/bin/main"
    if [[ -x "${binary}" || ( -f "${binary}" && ( "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ) ) ]]; then
        :
    elif [[ -f "${binary}.exe" ]]; then
        binary="${binary}.exe"
    else
        echo "cjdoc binary is missing or not executable: ${binary}" >&2
        exit 1
    fi
    "${python_cmd}" scripts/verify_repository_inputs.py --repo "${repo}" \
        --require-tracked --legacy-binary "${binary}"
    local worker="${worker_project}/target/release/bin/main"
    if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
        worker="${worker}.exe"
    fi
    (cd "${worker_project}" && cjpm build --jobs 1)
    if [[ ! -x "${worker}" && ! ( -f "${worker}" && ( "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ) ) ]]; then
        echo "CHIR worker executable was not produced at ${worker}" >&2
        exit 1
    fi
    # The build stage owns both executables and the worker build directory it just
    # created. It copies the worker binary into a stage-owned staging directory,
    # records both identities there, then removes only the worker build tree, so
    # a consumer receives ready binaries instead of rebuilding anything.
    "${python_cmd}" - "${repo}" "${binary}" "${worker}" "${manifest:-}" "${main_binary_out}" \
        "${worker_binary_out}" <<'PY'
from pathlib import Path
import json
import subprocess
import sys
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
from ci_stage import BUILD_MANIFEST_SCHEMA, runtime_platform, sha256_file, stage_environment

repo = Path(sys.argv[1]).resolve()
binary, worker = Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve()
manifest, main_out, worker_out = sys.argv[4], sys.argv[5], sys.argv[6]
canonical_worker = repo / "tools/chir-worker/target/release/bin/main"

def record(path: Path, *, with_version: bool) -> dict[str, object]:
    entry: dict[str, object] = {"path": path.relative_to(repo).as_posix(),
                                "sha256": sha256_file(path), "size": path.stat().st_size}
    if with_version:
        completed = subprocess.run([str(path), "--version"], capture_output=True, text=True)
        entry["versionOutput"] = completed.stdout.strip()
    return entry

environment = stage_environment(repo)
platform_id, os_name = runtime_platform()
document = {
    "schemaVersion": BUILD_MANIFEST_SCHEMA,
    "checkoutCommit": environment["checkoutCommit"],
    "checkoutTree": environment["checkoutTree"],
    "platform": platform_id,
    "os": os_name,
    "architecture": environment["architecture"],
    "toolchain": {
        "version": environment["sdkVersion"],
        "target": environment["toolchainTarget"],
        "stdxDigest": environment["stdxDigest"],
        "fingerprint": environment["toolchainFingerprint"],
    },
    "compileOptions": ["--jobs 1", "-O1"],
    "effectiveManifest": 'override-compile-option = "-O1"',
    "mainBinary": record(binary, with_version=True),
    "workerBinary": record(worker, with_version=False),
    "runId": environment["runId"],
    "runAttempt": environment["runAttempt"],
    "job": environment["job"],
}
if main_out and Path(main_out).resolve() != repo / "target/release/bin/main":
    raise SystemExit("--main-binary-out must be target/release/bin/main")
if worker_out:
    # The worker output path names the canonical location `--worker-binary`
    # expects, plus the copy the candidate artifact carries. Any other spelling
    # would make the two sides disagree, so only these are accepted.
    resolved_worker_out = Path(worker_out).resolve()
    if resolved_worker_out not in {canonical_worker, binary.parent / "chir-worker-main"}:
        raise SystemExit(
            "--worker-binary-out must be tools/chir-worker/target/release/bin/main "
            "or the sibling target/release/bin/chir-worker-main")
    if resolved_worker_out != worker:
        resolved_worker_out.parent.mkdir(parents=True, exist_ok=True)
        resolved_worker_out.write_bytes(worker.read_bytes())
        resolved_worker_out.chmod(worker.stat().st_mode & 0o777)
        document["workerBinary"] = record(resolved_worker_out, with_version=False)
if manifest:
    manifest_path = Path(manifest)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                             encoding="utf-8", newline="\n")
    print(f"build manifest written: {manifest_path}")
PY
}

stage_native() {
    cd "${repo}"
    require_identity
    refuse_existing_outputs fixtures
    local created="${fixture_project_root}"
    local cleaned=0
    cleanup_native() {
        if [[ "${cleaned}" == "1" ]]; then
            return 0
        fi
        cleaned=1
        while IFS= read -r relative; do
            [[ -z "${relative}" ]] && continue
            remove_owned_outputs "${repo_root}/${relative}"
        done < <(existing_build_outputs fixtures)
    }
    trap cleanup_native EXIT
    export CJDOC_CHIR_WORKER="${worker_binary:-${worker_project}/target/release/bin/main}"
    cjpm test --jobs 1
    cleanup_native
    trap - EXIT
}

stage_python_tools() {
    cd "${repo}"
    require_identity
    # `unittest discover` has no exclusion switch, so the module list is built
    # explicitly: every scripts/test_*.py except the two modules the preflight
    # stage already ran. This keeps the covered set identical to the previous
    # full discover while never executing a preflight test twice. Discover used
    # to add `scripts/` to sys.path for sibling imports such as
    # `test_validate_html_site`, so PYTHONPATH preserves that behaviour.
    local modules
    modules="$("${python_cmd}" - "${repo}" <<'PY'
from pathlib import Path
import sys

repo = Path(sys.argv[1])
excluded = {"test_install_cangjie_sdk.py", "test_with_stdx.py"}
names = sorted(path.stem for path in (repo / "scripts").glob("test_*.py")
               if path.name not in excluded)
if not names:
    raise SystemExit("no script test modules found")
print(" ".join(f"scripts.{name}" for name in names))
PY
)"
    # shellcheck disable=SC2086 - the module list is deliberately word-split.
    PYTHONPATH="${repo}/scripts${PYTHONPATH:+:${PYTHONPATH}}" \
        "${python_cmd}" -m unittest ${modules}
}

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
    local cleaned=0
    cleanup_cli() {
        if [[ "${cleaned}" == "1" ]]; then
            return 0
        fi
        cleaned=1
        while IFS= read -r relative; do
            [[ -z "${relative}" ]] && continue
            remove_owned_outputs "${repo_root}/${relative}"
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
        worker_binary="${worker_project}/target/release/bin/main"
        if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
            worker_binary="${worker_binary}.exe"
        fi
    fi
    export CJDOC_CHIR_WORKER="${worker_binary}"
    local binary="${main_binary}"

    run_golden() {
        local name="$1"
        local project="$2"
        local expected="$3"
        shift 3
        "${binary}" generate --project "${project}" --format json \
            --output "${check_dir}/${name}/first" --cache-dir "${check_dir}/cache/${name}" "$@" >/dev/null
        "${binary}" generate --project "${project}" --format json \
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

    "${binary}" generate --project tests/fixtures/projects/basic --semantic chir \
        --format json --stdout >"${check_dir}/chir-unconfigured-cli.json" \
        2>"${check_dir}/chir-unconfigured-cli.stderr"
    "${python_cmd}" -c 'import json,sys; document=json.load(open(sys.argv[1], encoding="utf-8")); assert len(document["declarations"])==25 and any(item["code"]=="CJDOC2101" and "worker executable is not configured" in item["message"] for item in document["diagnostics"])' \
        "${check_dir}/chir-unconfigured-cli.json"

    for schema_name in doc-ir doc-ir-v6 doc-ir-v7 doc-ir-v8 doc-ir-v9 doc-ir-v10 doc-ir-v11 diagnostics cfg-matrix search-index symbol-index navigation-index api-surface api-surface-v1 api-diff documentation-coverage-v1 documentation-coverage documentation-quality doctest-results versions; do
        "${binary}" schema "${schema_name}" | tr -d '\r' \
            >"${check_dir}/schemas/${schema_name}.schema.json"
    done
    cmp docs/schema/doc-ir.schema.json "${check_dir}/schemas/doc-ir.schema.json"
    cmp docs/schema/doc-ir-v6.schema.json "${check_dir}/schemas/doc-ir-v6.schema.json"
    cmp docs/schema/doc-ir-v7.schema.json "${check_dir}/schemas/doc-ir-v7.schema.json"
    cmp docs/schema/doc-ir-v8.schema.json "${check_dir}/schemas/doc-ir-v8.schema.json"
    cmp docs/schema/doc-ir-v9.schema.json "${check_dir}/schemas/doc-ir-v9.schema.json"
    cmp docs/schema/doc-ir-v10.schema.json "${check_dir}/schemas/doc-ir-v10.schema.json"
    cmp docs/schema/doc-ir-v11.schema.json "${check_dir}/schemas/doc-ir-v11.schema.json"
    cmp docs/schema/diagnostics.schema.json "${check_dir}/schemas/diagnostics.schema.json"
    cmp docs/schema/cfg-matrix.schema.json "${check_dir}/schemas/cfg-matrix.schema.json"
    cmp docs/schema/search-index.schema.json "${check_dir}/schemas/search-index.schema.json"
    cmp docs/schema/symbol-index.schema.json "${check_dir}/schemas/symbol-index.schema.json"
    cmp docs/schema/navigation-index.schema.json "${check_dir}/schemas/navigation-index.schema.json"
    cmp docs/schema/api-surface.schema.json "${check_dir}/schemas/api-surface.schema.json"
    cmp docs/schema/api-surface-v1.schema.json "${check_dir}/schemas/api-surface-v1.schema.json"
    cmp docs/schema/api-diff.schema.json "${check_dir}/schemas/api-diff.schema.json"
    cmp docs/schema/documentation-coverage-v1.schema.json "${check_dir}/schemas/documentation-coverage-v1.schema.json"
    cmp docs/schema/documentation-coverage.schema.json "${check_dir}/schemas/documentation-coverage.schema.json"
    cmp docs/schema/documentation-quality.schema.json "${check_dir}/schemas/documentation-quality.schema.json"
    cmp docs/schema/doctest-results.schema.json "${check_dir}/schemas/doctest-results.schema.json"
    cmp docs/schema/versions.schema.json "${check_dir}/schemas/versions.schema.json"

    run_golden basic tests/fixtures/projects/basic tests/fixtures/golden-v11/basic.docs.json
    run_golden functions tests/fixtures/projects/functions tests/fixtures/golden-v11/functions.docs.json
    run_golden types tests/fixtures/projects/types tests/fixtures/golden-v11/types.docs.json
    run_golden extend tests/fixtures/projects/extend_visibility tests/fixtures/golden-v11/extend.docs.json
    run_golden source-edges "${source_edges_project}" tests/fixtures/golden-v11/source-edges.docs.json
    run_golden unsupported tests/fixtures/projects/unsupported tests/fixtures/golden-v11/unsupported.docs.json
    run_golden workspace tests/fixtures/projects/workspace tests/fixtures/golden-v11/workspace.docs.json
    run_golden conditional-linux tests/fixtures/projects/conditional \
        tests/fixtures/golden-v11/conditional-linux.docs.json --cfg os=Linux
    run_golden path-dependencies tests/fixtures/projects/path_dependencies \
        tests/fixtures/golden-v11/path-dependencies.docs.json --include-path-dependencies

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
    rm -rf "${check_dir}/agent" "${check_dir}/agent-second" "${check_dir}/versions" "${check_dir}/versions-second"
    "${binary}" generate --project tests/fixtures/projects/basic --format html --format api-surface --agent-full --doc-version 1.3.0 --output "${check_dir}/agent" --cache-dir "${check_dir}/cache/agent" >/dev/null
    "${binary}" generate --project tests/fixtures/projects/basic --format html --format api-surface --agent-full --doc-version 1.3.0 --output "${check_dir}/agent-second" --cache-dir "${check_dir}/cache/agent" >/dev/null
    diff -qr "${check_dir}/agent/html" "${check_dir}/agent-second/html"
    test -f "${check_dir}/agent/html/navigation-index.json"
    test -f "${check_dir}/agent/html/llms.txt"
    test -f "${check_dir}/agent/html/llms-full.txt"
    "${python_cmd}" scripts/validate_html_site.py "${check_dir}/agent/html"
    "${python_cmd}" -c 'import json,sys; root=sys.argv[1]; nav=json.load(open(root+"/navigation-index.json", encoding="utf-8")); assert nav["schemaVersion"]=="cjdoc.navigation-index/1" and nav["project"]["version"]=="1.3.0" and any(page["kind"]=="symbol" for page in nav["pages"]); assert "1.3.0" in open(root+"/llms.txt", encoding="utf-8").read() and len(open(root+"/llms-full.txt", encoding="utf-8").read().encode()) <= 16*1024*1024' "${check_dir}/agent/html"
    "${binary}" diff --baseline "${check_dir}/agent/api-surface/api-surface.json" --current "${check_dir}/agent-second/api-surface/api-surface.json" --format json >"${check_dir}/agent/api-diff.json"
    "${binary}" versions compose --version 1.2.0="${check_dir}/all/first/html" --version 1.3.0="${check_dir}/agent/html" --diff 1.3.0="${check_dir}/agent/api-diff.json" --latest 1.3.0 --output "${check_dir}/versions" >/dev/null
    "${binary}" versions compose --version 1.2.0="${check_dir}/all/first/html" --version 1.3.0="${check_dir}/agent/html" --diff 1.3.0="${check_dir}/agent/api-diff.json" --latest 1.3.0 --output "${check_dir}/versions-second" >/dev/null
    diff -qr "${check_dir}/versions" "${check_dir}/versions-second"
    "${python_cmd}" -c 'import json,sys; root=sys.argv[1]; value=json.load(open(root+"/versions.json", encoding="utf-8")); assert value["schemaVersion"]=="cjdoc.versions/1" and value["latest"]=="1.3.0" and value["versions"][1]["apiDiff"]=="1.3.0/api-diff.json"; assert json.load(open(root+"/1.3.0/navigation-index.json", encoding="utf-8"))["schemaVersion"]=="cjdoc.navigation-index/1"; assert json.load(open(root+"/1.3.0/api-diff.json", encoding="utf-8"))["schemaVersion"]=="cjdoc.api-diff/1"' "${check_dir}/versions"
    set +e
    "${binary}" versions compose --version ../bad="${check_dir}/all/first/html" --output "${check_dir}/versions-bad" >/dev/null 2>"${check_dir}/versions-bad.stderr"
    version_traversal_code=$?
    set -e
    test "${version_traversal_code}" -eq 2
    test -s "${check_dir}/versions-bad.stderr"
    "${binary}" generate --project tests/fixtures/projects/basic --format json --stdout \
        --cache-dir "${check_dir}/cache/stdout" >"${check_dir}/stdout.json"
    "${python_cmd}" -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); assert value["schemaVersion"] == "cjdoc.doc-ir/11" and len(value["declarations"]) == 25' \
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

    "${python_cmd}" -m unittest scripts.test_fixture_contracts
    cleanup_cli
    trap - EXIT
}

stage_provider() {
    cd "${repo}"
    require_identity
    local provider_project="${repo}/tests/fixtures/projects/provider_plugin"
    local provider_build_cache="${provider_project}/build-script-cache"
    local provider_target="${provider_project}/target"
    "${python_cmd}" - "${provider_build_cache}" "${provider_target}" <<'PY'
from pathlib import Path
import stat
import sys

for value in sys.argv[1:]:
    path = Path(value)
    if path.is_symlink() or path.exists():
        mode = path.lstat().st_mode
        kind = "symlink" if path.is_symlink() else ("directory" if stat.S_ISDIR(mode) else "non-directory")
        raise SystemExit(f"provider output already exists ({kind}); refusing destructive cleanup: {path}")
PY
    cleanup_provider() {
        remove_owned_outputs "${provider_build_cache}" "${provider_target}"
    }
    trap cleanup_provider EXIT
    (cd "${provider_project}" && cjpm run --build-args "--jobs 1")
    cleanup_provider
    trap - EXIT
}

stage_smoke() {
    cd "${repo}"
    require_identity
    local smoke_evidence="${output_root:-${repo}/target/ci-evidence}/real-repository.json"
    "${python_cmd}" - "${smoke_evidence}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if path.exists() or path.is_symlink():
    raise SystemExit(f"smoke evidence must be a new file: {path}")
path.parent.mkdir(parents=True, exist_ok=True)
PY
    # Callers export an authenticated stdx environment, which always includes a
    # CJDOC_STDX_DIGEST (see with_stdx.py --print-env). Re-resolving here would be
    # redundant and would fail on an SDK layout the caller already resolved, so
    # only wrap when nothing was authenticated.
    if [[ -n "${CJDOC_STDX_DIGEST:-}" && -n "${CJDOC_STDX_PATH:-}" ]]; then
        "${python_cmd}" scripts/real_repository_smoke.py \
            --project "${repo}" --binary "${main_binary:-${repo}/target/release/bin/main}" \
            --evidence "${smoke_evidence}"
    else
        "${python_cmd}" scripts/with_stdx.py --variant static -- \
            "${python_cmd}" scripts/real_repository_smoke.py \
            --project "${repo}" --binary "${main_binary:-${repo}/target/release/bin/main}" \
            --evidence "${smoke_evidence}"
    fi
}

cd "${repo}"

# Inner invocation: this process is the timed child of ci_stage.py, so it runs
# the stage body directly instead of wrapping itself again.
if [[ -n "${inner}" ]]; then
    dispatch_stage "${inner}"
    echo "cjdoc acceptance gate passed (${inner})"
    exit 0
fi

stage="${stage_id}"
if [[ -z "${stage}" ]]; then
    for stage in preflight build native python-tools cli provider; do
        run_stage "${stage}" "$(stage_kind "${stage}")"
    done
    # The zero-argument gate owns everything it built, so it leaves the worktree
    # clean. Single-stage callers (CI and Pages) instead receive the worker binary
    # through the candidate artifact and clean it when they package.
    remove_owned_outputs "${worker_project}/target"
else
    run_stage "${stage}" "$(stage_kind "${stage}")"
fi

echo "cjdoc acceptance gate passed (${stage_id:-full})"
