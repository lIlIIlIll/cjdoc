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
# When a log path is configured, the wrapper records every build/test/run it
# performs. CI-08.3 compares that record across platforms instead of parsing the
# workflow's text, so a build routed around `cjpm build` still shows up.
export CJDOC_STS_INVOCATION_LOG="${CJDOC_STS_INVOCATION_LOG:-${runner_temp:-/tmp}/cjdoc-sts-invocations.jsonl}"

runner_temp="${RUNNER_TEMP}"
real_cjpm="$(command -v cjpm)"
inherited_wrapper="${CJDOC_STS_WRAPPER_CJPM:-}"
if command -v cygpath >/dev/null 2>&1; then
  runner_temp="$(cygpath -u "${runner_temp}")"
  real_cjpm="$(cygpath -u "${real_cjpm}")"
  if [[ -n "${inherited_wrapper}" ]]; then
    inherited_wrapper="$(cygpath -u "${inherited_wrapper}")"
  fi
fi
# Unwrap only our inherited launcher; a newly selected SDK on PATH must win.
if [[ -n "${inherited_wrapper}" && "${real_cjpm}" == "${inherited_wrapper}" ]]; then
  real_cjpm="${CJDOC_REAL_CJPM:?STS wrapper has no underlying cjpm}"
  if command -v cygpath >/dev/null 2>&1; then
    real_cjpm="$(cygpath -u "${real_cjpm}")"
  fi
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
# The provider and cancellation fixtures compile this repository as a path dependency.
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
if [[ "$current_directory" == "${provider_fixture}" ||
      "$current_directory" == "${workspace}/tests/fixtures/projects/highlight_host" ]]; then
  patch_fixture_entry=1
fi
# The rewrite lives in scripts/apply_sts_override.py so CI-08.3 can run this same
# call path rather than pattern-matching this file's text.
arguments=("${manifest}" "${backup_dir}")
if [[ "${patch_fixture_entry}" == "1" ]]; then
  arguments+=(--manifest-path "${current_directory}/cjpm.toml")
fi
"${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/apply_sts_override.py" "${arguments[@]}"
# The option is read back from the manifest this invocation actually consumes, which
# is not the workspace root when cjpm runs inside an auxiliary project such as
# tools/chir-worker. Reporting the root's value here would record an -O1 build whose
# `cjpm` in fact read an unpatched manifest.
# The manifest of the package being built, patched by the step above when it is the
# workspace root. `--declared` reports what the manifest holds now, which is what this
# `cjpm` will read — an auxiliary project's manifest is not patched and reports none.
case "${1:-}" in
  build) record_invocation=1 ;;
  # `test` and `run` are not the release's build; recording them would also make a
  # failing logger able to break the suite, so only the build is recorded.
  *) record_invocation=0 ;;
esac
set +e
"${CJDOC_REAL_CJPM}" "$@"
status=$?
set -e
if [[ "${record_invocation}" == "1" ]]; then
  # The option is read back from the manifest this invocation actually consumes,
  # which is not the workspace root when cjpm runs inside an auxiliary project such
  # as tools/chir-worker. Reporting the root's value would record an -O1 build whose
  # `cjpm` in fact read an unpatched manifest.
  effective="$("${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/sts_compile_override.py" \
    --declared "${current_directory}/cjpm.toml")"
  # Recorded after the run: the digest is of the binary this invocation produced, so a
  # later build that replaced it changes what the release must match. Windows produces
  # `main.exe`, so the suffix is resolved now that the build has run, as the build gate
  # does — checking before the build would always miss it.
  cjdoc_binary="${workspace}/target/release/bin/main"
  if [[ -f "${cjdoc_binary}.exe" ]]; then
    cjdoc_binary="${cjdoc_binary}.exe"
  fi
  # Not best-effort: if the record is incomplete, the release evidence is incomplete,
  # and a later rebuild could then go unrecorded while its digest still matched.
  "${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/log_invocation.py" \
    --log "${CJDOC_STS_INVOCATION_LOG}" --manifest "${current_directory}/cjpm.toml" \
    --option="${effective}" --binary "${cjdoc_binary}" \
    -- "$@"
fi
exit "${status}"
SH
chmod +x "${wrapper_dir}/cjpm"
export CJDOC_REAL_CJPM="${real_cjpm}"
export CJDOC_STS_WRAPPER_CJPM="${wrapper_dir}/cjpm"
export PATH="${wrapper_dir}:${PATH}"
