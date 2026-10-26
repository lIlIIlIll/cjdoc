#!/usr/bin/env bash
# Pin product build/run to -O2 --fno-chir-function-inlining.
# Unit compilation uses the explicit -O1 compiler exception. Record the actual
# phase/option/exit status; only build
# records bind a product binary. Manifests and owned unit targets are restored
# by a trap; failures keep their original exit status and are never retried.
# Commands outside the workspace and commands other than build/test/run pass
# through to the selected SDK's cjpm.
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
export CJDOC_STS_INVOCATION_LOG="${CJDOC_STS_INVOCATION_LOG:-${RUNNER_TEMP}/cjdoc-sts-invocations.jsonl}"

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
unit_target=""
restore_manifests() {
  local index=0 manifest
  if [[ -f "${backup_dir}/manifest-paths" ]]; then
    while IFS= read -r -d '' manifest; do
      cp -p "${backup_dir}/${index}.toml" "${manifest}"
      index=$((index + 1))
    done < "${backup_dir}/manifest-paths"
  fi
  rm -rf "${backup_dir}"
  if [[ -n "${unit_target}" ]]; then
    rm -rf "${unit_target}"
  fi
}
trap restore_manifests EXIT
if [[ "$1" == "test" ]]; then
  for argument in "$@"; do
    case "${argument}" in
      --target-dir|--target-dir=*)
        echo "unit-test target is owned by the STS wrapper; omit --target-dir" >&2
        exit 2 ;;
    esac
  done
  # A fresh target holds every -O1 unit artifact, separately from the product's
  # target tree. Neither a successful nor a failing test can seed an -O2 build.
  unit_target="$(mktemp -d "${runner_temp}/cjdoc-unit-o1.XXXXXX")"
  set -- "$@" --target-dir "${unit_target}"
fi
patch_fixture_entry=0
provider_fixture="${workspace}/tests/fixtures/projects/provider_plugin"
if [[ "$current_directory" == "${provider_fixture}" ||
      "$current_directory" == "${workspace}/tests/fixtures/projects/highlight_host" ||
      "$current_directory" == "${workspace}/tools/chir-worker" ]]; then
  patch_fixture_entry=1
fi
# The rewrite lives in scripts/apply_sts_override.py so CI-08.3 can run this same
# call path rather than pattern-matching this file's text.
arguments=("${manifest}" "${backup_dir}" --command "$1")
if [[ "${patch_fixture_entry}" == "1" ]]; then
  arguments+=(--manifest-path "${current_directory}/cjpm.toml")
fi
"${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/apply_sts_override.py" "${arguments[@]}"
set +e
"${CJDOC_REAL_CJPM}" "$@"
status=$?
set -e
# Read the manifest actually consumed, including an unpatched auxiliary project.
effective="$("${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/sts_compile_override.py" \
  --declared "${current_directory}/cjpm.toml")"
log_arguments=(--log "${CJDOC_STS_INVOCATION_LOG}" --manifest "${current_directory}/cjpm.toml"
  --option="${effective}" --exit-code "${status}")
if [[ "$1" == "build" ]]; then
  cjdoc_binary="${current_directory}/target/release/bin/main"
  if [[ -f "${cjdoc_binary}.exe" ]]; then
    cjdoc_binary="${cjdoc_binary}.exe"
  fi
  log_arguments+=(--binary "${cjdoc_binary}")
fi
# A failed command remains failed even if logging also fails; a successful
# command without a complete invocation record must fail its evidence gate.
log_status=0
"${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/log_invocation.py" \
  "${log_arguments[@]}" -- "$@" || log_status=$?
if [[ "${status}" == "0" && "${log_status}" != "0" ]]; then
  exit "${log_status}"
fi
exit "${status}"
SH
chmod +x "${wrapper_dir}/cjpm"
export CJDOC_REAL_CJPM="${real_cjpm}"
export CJDOC_STS_WRAPPER_CJPM="${wrapper_dir}/cjpm"
export PATH="${wrapper_dir}:${PATH}"
