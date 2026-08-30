#!/usr/bin/env bash
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${repo_root}/target/release/bin/main"
update_dir="${repo_root}/target/golden-update"
golden_dir="${repo_root}/tests/fixtures/golden-v8"
golden_parent="${repo_root}/tests/fixtures"
python_cmd="${CJDOC_PYTHON:-python3}"
source_edges_override="${CJDOC_SOURCE_EDGES_PROJECT:-}"
source_edges_commit="${CJDOC_SOURCE_EDGES_COMMIT:-}"
source_edges_tree="${CJDOC_SOURCE_EDGES_TREE:-}"
stage_dir=""
backup_dir=""

cleanup() {
    if [[ -n "${stage_dir}" && -e "${stage_dir}" ]]; then
        rm -rf "${stage_dir}"
    fi
    if [[ -n "${backup_dir}" && -e "${backup_dir}" && ! -e "${golden_dir}" ]]; then
        mv "${backup_dir}" "${golden_dir}"
    fi
}
trap cleanup EXIT

cd "${repo_root}"
if [[ -x "${binary}" || ( -f "${binary}" && ( "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ) ) ]]; then
    :
elif [[ -f "${binary}.exe" ]]; then
    binary="${binary}.exe"
else
    echo "cjdoc binary is missing or not executable: ${binary}" >&2
    exit 1
fi
"${python_cmd}" scripts/safe_output_root.py \
    --repo "${repo_root}" --directory "${repo_root}/target" --create >/dev/null
target_root="${repo_root}/target"
update_dir="${target_root}/golden-update"
"${python_cmd}" scripts/safe_output_root.py \
    --repo "${repo_root}" --directory "${update_dir}" --allow-missing >/dev/null
rm -rf "${update_dir}"
"${python_cmd}" scripts/safe_output_root.py \
    --repo "${repo_root}" --directory "${update_dir}" --create >/dev/null
mkdir -p "${golden_parent}"
stage_dir="$(mktemp -d "${golden_parent}/.golden-v8.XXXXXX")"
snapshot_dir="${update_dir}/fixture-snapshot"
snapshot_receipt="${update_dir}/fixture-snapshot.json"

snapshot_args=(
    prepare --repo "${repo_root}" --destination "${snapshot_dir}"
    --receipt "${snapshot_receipt}"
)
if [[ -n "${source_edges_override}" ]]; then
    snapshot_args+=(
        --source-edges-override "${source_edges_override}"
        --expected-commit "${source_edges_commit}"
        --expected-tree "${source_edges_tree}"
    )
elif [[ -n "${source_edges_commit}" || -n "${source_edges_tree}" ]]; then
    echo "source_edges commit/tree identity requires CJDOC_SOURCE_EDGES_PROJECT" >&2
    exit 1
fi
"${python_cmd}" scripts/fixture_snapshot.py "${snapshot_args[@]}"
fixture_root="${snapshot_dir}/tests/fixtures/projects"
source_edges_project="${fixture_root}/source_edges"

# Legacy v6/v7 inputs are migration fixtures, not update targets.
"${python_cmd}" -c 'from pathlib import Path; from scripts.verify_repository_inputs import verify_golden_set; [verify_golden_set(Path.cwd(), version) for version in (6, 7)]'
"${binary}" schema list | tr -d '\r' >"${update_dir}/schema-list.txt"
"${python_cmd}" -c 'import sys; names=set(open(sys.argv[1], encoding="utf-8").read().splitlines()); assert "doc-ir-v8" in names' \
    "${update_dir}/schema-list.txt"

update_golden() {
    local name="$1"
    local project="$2"
    shift 2
    "${binary}" generate --project "${project}" --format json \
        --output "${update_dir}/${name}" --no-cache "$@" >/dev/null
    cp -f "${update_dir}/${name}/docs.json" "${stage_dir}/${name}.docs.json"
}

update_golden basic "${fixture_root}/basic"
update_golden functions "${fixture_root}/functions"
update_golden types "${fixture_root}/types"
update_golden extend "${fixture_root}/extend_visibility"
update_golden source-edges "${source_edges_project}"
update_golden unsupported "${fixture_root}/unsupported"
update_golden workspace "${fixture_root}/workspace"
update_golden conditional-linux "${fixture_root}/conditional" --cfg os=Linux
update_golden path-dependencies "${fixture_root}/path_dependencies" --include-path-dependencies

"${python_cmd}" - "${stage_dir}" <<'PY'
from pathlib import Path
import sys
from scripts.strict_json import strict_load

root = Path(sys.argv[1])
expected = {
    "basic.docs.json", "functions.docs.json", "types.docs.json", "extend.docs.json",
    "source-edges.docs.json", "unsupported.docs.json", "workspace.docs.json",
    "conditional-linux.docs.json", "path-dependencies.docs.json",
}
actual = {path.name for path in root.glob("*.docs.json")}
if actual != expected:
    raise SystemExit(
        "v8 golden set mismatch: missing=" + ",".join(sorted(expected - actual)) +
        " unexpected=" + ",".join(sorted(actual - expected))
    )
for path in root.glob("*.docs.json"):
    value = strict_load(path, description=f"generated v8 golden {path.name}")
    if value.get("schemaVersion") != "cjdoc.doc-ir/8":
        raise SystemExit(f"non-v8 golden generated: {path.name}")
PY

"${python_cmd}" scripts/fixture_snapshot.py verify --receipt "${snapshot_receipt}"

if [[ -e "${golden_dir}" ]]; then
    backup_dir="${golden_parent}/.golden-v8.backup.$$"
    test ! -e "${backup_dir}"
    mv "${golden_dir}" "${backup_dir}"
fi
if mv "${stage_dir}" "${golden_dir}"; then
    stage_dir=""
    if [[ -n "${backup_dir}" ]]; then
        rm -rf "${backup_dir}"
        backup_dir=""
    fi
else
    if [[ -n "${backup_dir}" && -e "${backup_dir}" ]]; then
        mv "${backup_dir}" "${golden_dir}"
        backup_dir=""
    fi
    exit 1
fi

trap - EXIT

echo "updated Doc IR v8 goldens"
