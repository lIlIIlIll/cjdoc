#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${repo_root}/target/release/bin/main"
update_dir="${repo_root}/target/golden-update"
golden_dir="${repo_root}/tests/fixtures/golden-v6"

cd "${repo_root}"
if [[ ! -x "${binary}" && -x "${binary}.exe" ]]; then
    binary="${binary}.exe"
fi
test -x "${binary}"
rm -rf "${update_dir}"
mkdir -p "${update_dir}" "${golden_dir}"

update_golden() {
    local name="$1"
    local project="$2"
    shift 2
    "${binary}" generate --project "${project}" --format json \
        --output "${update_dir}/${name}" --no-cache "$@" >/dev/null
    cp -f "${update_dir}/${name}/docs.json" "${golden_dir}/${name}.docs.json"
}

update_golden basic tests/fixtures/projects/basic
update_golden functions tests/fixtures/projects/functions
update_golden types tests/fixtures/projects/types
update_golden extend tests/fixtures/projects/extend_visibility
update_golden source-edges tests/fixtures/projects/source_edges
update_golden unsupported tests/fixtures/projects/unsupported
update_golden workspace tests/fixtures/projects/workspace
update_golden conditional-linux tests/fixtures/projects/conditional --cfg os=Linux
update_golden path-dependencies tests/fixtures/projects/path_dependencies --include-path-dependencies

echo "updated Doc IR v6 goldens"
