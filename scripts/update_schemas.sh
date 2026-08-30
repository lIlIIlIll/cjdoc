#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${repo_root}/target/release/bin/main"
update_dir="${repo_root}/target/schema-update"
schema_dir="${repo_root}/docs/schema"

cd "${repo_root}"
if [[ ! -x "${binary}" && -x "${binary}.exe" ]]; then
    binary="${binary}.exe"
fi
test -x "${binary}"
rm -rf "${update_dir}"
mkdir -p "${update_dir}" "${schema_dir}"

for schema_name in doc-ir doc-ir-v6 doc-ir-v7 diagnostics cfg-matrix search-index; do
    "${binary}" schema "${schema_name}" | tr -d '\r' \
        >"${update_dir}/${schema_name}.schema.json"
    cp -f "${update_dir}/${schema_name}.schema.json" \
        "${schema_dir}/${schema_name}.schema.json"
done

echo "updated embedded schema copies"
