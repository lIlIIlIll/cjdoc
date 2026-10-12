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

# The override rules live in scripts/sts_compile_override.py, shared with the
# CI-08.3 uniformity check so the two cannot drift apart.
cjdoc_scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CJDOC_STS_OVERRIDE_MODULE="${cjdoc_scripts_dir}"

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
# The rewrite lives in scripts/apply_sts_override.py so CI-08.3 can run this same
# call path rather than pattern-matching this file's text. The receipt records the
# option actually applied.
arguments=("${manifest}" "${backup_dir}" --receipt "${runner_temp}/cjdoc-sts-override-receipt.json")
if [[ "${patch_fixture_entry}" == "1" ]]; then
  arguments+=(--manifest-path "${current_directory}/cjpm.toml")
fi
"${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/apply_sts_override.py" "${arguments[@]}"
set +e
"${CJDOC_REAL_CJPM}" "$@"
status=$?
set -e
exit "${status}"
SH
chmod +x "${wrapper_dir}/cjpm"
export CJDOC_REAL_CJPM="${real_cjpm}"
export PATH="${wrapper_dir}:${PATH}"
