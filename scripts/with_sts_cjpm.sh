#!/usr/bin/env bash
# Pin product build/run to -O2 --fno-chir-function-inlining -Woff deprecated.
# Suppress only deprecation diagnostics; unit tests retain all warning groups.
# Unit compilation uses the explicit -O1 compiler exception. Record the actual
# phase/option/exit status; only build
# records bind a product binary. Manifests and owned unit targets are restored
# by a trap; failures keep their original exit status and are never retried.
# Commands outside the workspace and commands other than build/test/run pass
# through to the selected SDK's cjpm.
#
# CJDOC_STS_COMPILER_DIAGNOSTICS asks for compiler IR retention. It is honoured
# only for the provider fixture's product run, by appending -V --save-temps DIR
# to the same policy option; every other invocation records that the request was
# ignored and keeps the pinned option.
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
  if [[ -n "${unit_target}" && "${owns_target:-1}" == "1" ]]; then
    rm -rf "${unit_target}"
  fi
}
trap restore_manifests EXIT
# Test fixtures locate the checkout from the compiled binary, so no project path is
# injected here: a suite must pass from any working directory without one.
run_unit_tests=0
unit_progress_flag=--no-progress
unit_capture_flag=--no-capture-output
# Marker occurrences, not matching lines: a runner may re-emit captured case output
# behind its own package heading, which is exactly how a degradation line went
# unmatched on Windows. Counting the token itself cannot be reformatted away.
count_marker() {
  local count
  count="$(tr -d '\r' < "$2" 2>/dev/null | grep -o "$1" 2>/dev/null | wc -l | tr -d ' ' || true)"
  printf '%s' "${count:-0}"
}
if [[ "$1" == "test" ]]; then
  run_unit_tests=1
  reuse_target=""
  owns_target=1
  for argument in "$@"; do
    case "${argument}" in
      --target-dir|--target-dir=*)
        echo "unit-test target is owned by the STS wrapper; omit --target-dir" >&2
        exit 2 ;;
      --no-run|--dry-run) run_unit_tests=0 ;;
      --skip-build) reuse_target="${CJDOC_TEST_WRAPPER_UNIT_TARGET:-}" ;;
      --no-progress) unit_progress_flag="" ;;
      --no-capture-output) unit_capture_flag="" ;;
    esac
  done
  if [[ -n "${reuse_target}" ]]; then
    # The environment proof reruns one filtered case against the target the full
    # suite just built. Reusing it keeps the control cheap while still going through
    # this wrapper, so its degradation tally is what the control observes.
    unit_target="${reuse_target}"
    owns_target=0
  else
    if [[ "$*" == *"--skip-build"* ]]; then
      echo "--skip-build needs CJDOC_TEST_WRAPPER_UNIT_TARGET naming a unit target this wrapper built" >&2
      exit 2
    fi
    # A fresh target holds every -O1 unit artifact, separately from the product's
    # target tree. Neither a successful nor a failing test can seed an -O2 build.
    unit_target="$(mktemp -d "${runner_temp}/cjdoc-unit-o1.XXXXXX")"
  fi
  set -- "$@" --target-dir "${unit_target}"
fi
patch_fixture_entry=0
provider_fixture="${workspace}/tests/fixtures/projects/provider_plugin"
if [[ "$current_directory" == "${provider_fixture}" ||
      "$current_directory" == "${workspace}/tests/fixtures/projects/highlight_host" ||
      "$current_directory" == "${workspace}/tools/chir-worker" ]]; then
  patch_fixture_entry=1
fi
# Compiler diagnostics are requested for one provider-fixture product run by the
# native compiler capture. Any other invocation keeps the plain policy option, so
# an ambient variable can never add retention to an ordinary build and the unit
# phase never inherits a product's -V/--save-temps.
diagnostics_dir=""
if [[ -n "${CJDOC_STS_COMPILER_DIAGNOSTICS:-}" ]]; then
  if [[ "${current_directory}" == "${provider_fixture}" && "$1" == "run" ]]; then
    diagnostics_dir="${CJDOC_STS_COMPILER_DIAGNOSTICS}"
  else
    echo "cjpm: ignoring CJDOC_STS_COMPILER_DIAGNOSTICS for '$1' outside the provider fixture run; the pinned option is unchanged" >&2
  fi
fi
# The rewrite lives in scripts/apply_sts_override.py so CI-08.3 can run this same
# call path rather than pattern-matching this file's text.
arguments=("${manifest}" "${backup_dir}" --command "$1")
# Appended conditionally: expanding an empty array is an unbound variable in the
# bash 3.2 macOS still uses.
if [[ -n "${diagnostics_dir}" ]]; then
  arguments+=(--diagnostics-dir "${diagnostics_dir}")
fi
if [[ "${patch_fixture_entry}" == "1" ]]; then
  arguments+=(--manifest-path "${current_directory}/cjpm.toml")
fi
"${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/apply_sts_override.py" "${arguments[@]}"
set +e
if [[ "${run_unit_tests}" == "1" ]]; then
  if [[ -n "${unit_progress_flag}" ]]; then set -- "$@" "${unit_progress_flag}"; fi
  if [[ -n "${unit_capture_flag}" ]]; then set -- "$@" "${unit_capture_flag}"; fi
  "${CJDOC_REAL_CJPM}" "$@" 2>&1 | tee "${backup_dir}/native-tests.log"
  outcomes=("${PIPESTATUS[@]}")
  status="${outcomes[0]}"
  if [[ "${status}" == "0" && "${outcomes[1]}" != "0" ]]; then status="${outcomes[1]}"; fi
  if [[ "${status}" == "0" ]]; then
    log="${backup_dir}/native-tests.log"
    degraded="$(count_marker 'CJDOC_TEST_DEGRADED ' "${log}")"
    refused="$(count_marker 'CJDOC_TEST_PLATFORM_REFUSAL ' "${log}")"
    printf 'Native test requirements — degraded: %s\n' "${degraded}"
    if [[ "${refused}" != "0" ]]; then
      printf 'Native platform refusals verified: %s\n' "${refused}"
    fi
    if [[ "${CJDOC_TEST_REQUIRE_VERIFIED:-0}" == "1" && "${degraded}" != "0" ]]; then
      echo "native suite left required behavior unverified: ${degraded} degradation record(s)" >&2
      tr -d '\r' < "${log}" | grep -o 'CJDOC_TEST_DEGRADED [^[:cntrl:]]*' | sort -u >&2 || true
      status=1
    fi
    # A platform refusal is a verified contract only where it is documented. On
    # hosts that must execute examples it means required behavior did not run.
    case "${CJDOC_TEST_PLATFORM_REFUSALS:-}" in
      forbidden)
        if [[ "${refused}" != "0" ]]; then
          echo "native suite reported platform refusals where execution is required: ${refused}" >&2
          tr -d '\r' < "${log}" | grep -o 'CJDOC_TEST_PLATFORM_REFUSAL [^[:cntrl:]]*' | sort -u >&2 || true
          status=1
        fi ;;
      required)
        if [[ "${refused}" == "0" ]]; then
          echo "native suite did not verify the documented platform refusal" >&2
          status=1
        fi ;;
    esac
    # Discriminating negative control: the built unit target is rerun through this
    # same wrapper with the CHIR worker unset and one selected fallback case. Its
    # tally must be non-zero and attributed to that case, and strict verification must
    # reject the run. A tally that cannot fire is caught here instead of in CI. The
    # guard variable stops the control from starting another control.
    if [[ "${status}" == "0" && "${CJDOC_TEST_PROVE_MISSING_WORKER:-0}" == "1" &&
          -z "${CJDOC_TEST_MISSING_WORKER_CONTROL:-}" ]]; then
      control_log="${backup_dir}/missing-worker-control.log"
      set +e
      env -u CJDOC_CHIR_WORKER CJDOC_TEST_MISSING_WORKER_CONTROL=1 \
        CJDOC_TEST_REQUIRE_VERIFIED=1 CJDOC_TEST_PLATFORM_REFUSALS= \
        CJDOC_TEST_WRAPPER_UNIT_TARGET="${unit_target}" \
        "${CJDOC_STS_WRAPPER_CJPM}" test --skip-build --jobs 1 --parallel 1 \
        --no-progress --no-capture-output \
        --filter="*.${CJDOC_TEST_MISSING_WORKER_CASE:-extensionTargetsKeepPackageIdentityWhenNamesCollide}" \
        >"${control_log}" 2>&1
      control_status=$?
      set -e
      control_total="$(tr -d '\r' < "${control_log}" \
        | sed -n 's/.*Native test requirements — degraded: \([0-9][0-9]*\).*/\1/p' | tail -n 1 || true)"
      control_case="${CJDOC_TEST_MISSING_WORKER_CASE:-extensionTargetsKeepPackageIdentityWhenNamesCollide}"
      control_records="$(count_marker "CJDOC_TEST_DEGRADED ${control_case}: " "${control_log}")"
      printf 'missing-worker control — degraded: %s (selected case: %s), exit %s\n' \
        "${control_total:-none}" "${control_records}" "${control_status}"
      if [[ "${control_status}" == "0" || "${control_total:-0}" -lt 1 ||
            "${control_records}" -lt 1 ]]; then
        echo "missing-worker control did not fail strict verification for the selected case" >&2
        tr -d '\r' < "${control_log}" | tail -n 40 >&2 || true
        status=1
      fi
    fi
  fi
else
  "${CJDOC_REAL_CJPM}" "$@"
  status=$?
  if [[ "${status}" == "0" && "$1" == "test" && "${CJDOC_TEST_PROVE_ENVIRONMENT:-0}" == "1" ]]; then
    "${CJDOC_PYTHON:-python}" "${workspace}/scripts/check_native_environment.py" \
      --repo "${workspace}" --unit-target "${unit_target}"
    status=$?
  fi
fi
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
