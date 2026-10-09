#!/usr/bin/env bash
# Install a `cjpm` wrapper that lowers the optimization level for build, test and
# run, then export it on PATH for the rest of the step.
#
# The pinned Cangjie 1.2.0 STS toolchain's bundled `llc` crashes at -O2 while
# compiling the markdown and yjson dependencies. The wrapper keeps the committed
# defaults untouched: it copies the affected `cjpm.toml` files aside, rewrites
# `override-compile-option` to "-O1" for the duration of one cjpm invocation, and
# restores the originals from a trap. Commands other than build/test/run, and
# invocations outside the workspace, pass straight through to the real cjpm.
#
# Callers must set GITHUB_WORKSPACE and RUNNER_TEMP first and then execute their
# acceptance command(s) in this same shell. CJDOC_STDX_PATH is exported when the
# caller authenticated a sidecar; release.yml relies on with_stdx.py discovery
# instead, so an unset value is not an error here.
set -euo pipefail

if [ -n "${CJDOC_STDX_PATH:-}" ]; then
  export CANGJIE_STDX_PATH="${CJDOC_STDX_PATH}"
fi
cjc -v
cjpm -v

runner_temp="${RUNNER_TEMP}"
real_cjpm="$(command -v cjpm)"
if command -v cygpath >/dev/null 2>&1; then
  runner_temp="$(cygpath -u "${runner_temp}")"
  real_cjpm="$(cygpath -u "${real_cjpm}")"
fi
wrapper_dir="${runner_temp}/cjpm-sts-optimization"
mkdir -p "${wrapper_dir}"
cat >"${wrapper_dir}/cjpm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  build|test|run) ;;
  *) exec "${CJDOC_REAL_CJPM}" "$@" ;;
esac
workspace="${GITHUB_WORKSPACE}"
runner_temp="${RUNNER_TEMP}"
current_directory="$PWD"
if command -v cygpath >/dev/null 2>&1; then
  workspace="$(cygpath -u "${workspace}")"
  runner_temp="$(cygpath -u "${runner_temp}")"
  current_directory="$(cygpath -u "${current_directory}")"
fi
# The provider fixture is nested but compiles this repository as a path dependency.
case "$current_directory" in
  "${workspace}"|"${workspace}"/*) ;;
  *) exec "${CJDOC_REAL_CJPM}" "$@" ;;
esac
manifest="${workspace}/cjpm.toml"
backup_dir="$(mktemp -d "${runner_temp}/cjpm-manifests.XXXXXX")"
restore_manifests() {
  local index=0 manifest
  if [[ -f "${backup_dir}/manifest-paths" ]]; then
    while IFS= read -r -d '' manifest; do
      cp -p "${backup_dir}/${index}.toml" "${manifest}"
      index=$((index + 1))
    done < "${backup_dir}/manifest-paths"
  fi
  rm -rf "${backup_dir}"
}
trap restore_manifests EXIT
patch_fixture_entry=0
provider_fixture="${workspace}/tests/fixtures/projects/provider_plugin"
if [[ "$current_directory" == "${provider_fixture}" ]]; then
  patch_fixture_entry=1
fi
python - "${manifest}" "${backup_dir}" "${patch_fixture_entry}" <<'PY'
from pathlib import Path
import shutil
import sys
import tomllib

root_manifest = Path(sys.argv[1])
backup_dir = Path(sys.argv[2])
patch_fixture_entry = sys.argv[3] == "1"
manifests = [(root_manifest, "cjdoc")]
if patch_fixture_entry:
    manifests.append((Path.cwd() / "cjpm.toml", "provider_plugin_fixture"))

needle = 'override-compile-option = ""'
updates = []
for manifest, expected_name in manifests:
    contents = manifest.read_text(encoding="utf-8")
    package = tomllib.loads(contents).get("package")
    if not isinstance(package, dict) or package.get("name") != expected_name:
        raise SystemExit(f"unexpected package manifest for {expected_name}")
    override = package.get("override-compile-option")
    if override == "-O1":
        updated = contents
    elif override == "":
        if contents.count(needle) != 1:
            raise SystemExit(f"expected one default override-compile-option in {manifest}")
        updated = contents.replace(needle, 'override-compile-option = "-O1"', 1)
    elif override is None:
        package_header = "[package]\n"
        if contents.count(package_header) != 1:
            raise SystemExit(f"expected one package table in {manifest}")
        updated = contents.replace(
            package_header,
            package_header + '  override-compile-option = "-O1"\n',
            1,
        )
    else:
        raise SystemExit(f"unexpected compile override for {expected_name}")
    updates.append((manifest, updated))

backup_dir.mkdir(parents=True, exist_ok=True)
paths_file = backup_dir / "manifest-paths"
for index, (manifest, _) in enumerate(updates):
    shutil.copy2(manifest, backup_dir / f"{index}.toml")
    with paths_file.open("ab") as stream:
        stream.write(str(manifest).encode("utf-8") + b"\0")
for manifest, contents in updates:
    manifest.write_text(contents, encoding="utf-8")
PY
set +e
"${CJDOC_REAL_CJPM}" "$@"
status=$?
set -e
exit "${status}"
SH
chmod +x "${wrapper_dir}/cjpm"
export CJDOC_REAL_CJPM="${real_cjpm}"
export PATH="${wrapper_dir}:${PATH}"
