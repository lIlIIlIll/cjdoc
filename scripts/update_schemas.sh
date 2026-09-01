#!/usr/bin/env bash
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${repo_root}/target/release/bin/main"
update_dir="${repo_root}/target/schema-update"
schema_dir="${repo_root}/docs/schema"
schema_parent="${repo_root}/docs"
python_cmd="${CJDOC_PYTHON:-python3}"
stage_dir=""
backup_dir=""

cleanup() {
    if [[ -n "${stage_dir}" && -e "${stage_dir}" ]]; then
        rm -rf "${stage_dir}"
    fi
    if [[ -n "${backup_dir}" && -e "${backup_dir}" && ! -e "${schema_dir}" ]]; then
        mv "${backup_dir}" "${schema_dir}"
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
"${python_cmd}" -c 'from pathlib import Path; from scripts.verify_repository_inputs import verify_schema_set; verify_schema_set(Path.cwd())'
"${python_cmd}" scripts/safe_output_root.py \
    --repo "${repo_root}" --directory "${repo_root}/target" --create >/dev/null
target_root="${repo_root}/target"
update_dir="${target_root}/schema-update"
"${python_cmd}" scripts/safe_output_root.py \
    --repo "${repo_root}" --directory "${update_dir}" --allow-missing >/dev/null
rm -rf "${update_dir}"
"${python_cmd}" scripts/safe_output_root.py \
    --repo "${repo_root}" --directory "${update_dir}" --create >/dev/null
test -d "${schema_dir}"
stage_dir="$(mktemp -d "${schema_parent}/.schema.XXXXXX")"

for schema_name in doc-ir-v6 doc-ir-v7; do
    "${binary}" schema "${schema_name}" | tr -d '\r' \
        >"${update_dir}/${schema_name}.schema.json"
    cmp "${schema_dir}/${schema_name}.schema.json" \
        "${update_dir}/${schema_name}.schema.json"
    cp -f "${schema_dir}/${schema_name}.schema.json" \
        "${stage_dir}/${schema_name}.schema.json"
done

for schema_name in doc-ir doc-ir-v8 diagnostics cfg-matrix search-index api-surface documentation-coverage; do
    "${binary}" schema "${schema_name}" | tr -d '\r' \
        >"${stage_dir}/${schema_name}.schema.json"
done

"${python_cmd}" - "${stage_dir}" <<'PY'
from pathlib import Path
import sys
from scripts.verify_repository_inputs import SCHEMA_NAMES, validate_schema_document
from scripts.strict_json import strict_load

root = Path(sys.argv[1])
expected = {f"{name}.schema.json" for name in SCHEMA_NAMES}
actual = {path.name for path in root.glob("*.schema.json")}
if actual != expected:
    raise SystemExit(
        "schema set mismatch: missing=" + ",".join(sorted(expected - actual)) +
        " unexpected=" + ",".join(sorted(actual - expected))
    )
for name in SCHEMA_NAMES:
    value = strict_load(root / f"{name}.schema.json", description=f"generated {name} schema")
    validate_schema_document(name, value)
PY

"${python_cmd}" -c 'from pathlib import Path; from scripts.verify_repository_inputs import verify_schema_set; verify_schema_set(Path.cwd())'
backup_dir="${schema_parent}/.schema.backup.$$"
test ! -e "${backup_dir}"
mv "${schema_dir}" "${backup_dir}"
if mv "${stage_dir}" "${schema_dir}"; then
    stage_dir=""
    rm -rf "${backup_dir}"
    backup_dir=""
else
    mv "${backup_dir}" "${schema_dir}"
    backup_dir=""
    exit 1
fi

trap - EXIT

echo "updated embedded schema copies"
