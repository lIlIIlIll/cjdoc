#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_runner="${CJDOC_CANGJIE_RUNNER:-${repo_root}/scripts/cangjie_env_runner.sh}"
work_dir="${repo_root}/target/perf-gate"
project_dir="${work_dir}/project"
binary="${repo_root}/target/release/bin/main"
if [[ ! -x "${binary}" && -x "${binary}.exe" ]]; then
    binary="${binary}.exe"
fi
symbol_count="${CJDOC_PERF_SYMBOLS:-2000}"
max_millis="${CJDOC_PERF_MAX_MILLIS:-15000}"
hot_max_millis="${CJDOC_PERF_HOT_MAX_MILLIS:-7000}"
max_peak_kib="${CJDOC_PERF_MAX_PEAK_KIB:-524288}"
file_count="${CJDOC_PERF_FILES:-40}"
enforce_thresholds="${CJDOC_PERF_ENFORCE_THRESHOLDS:-1}"

if [[ -n "${CJDOC_PYTHON:-}" ]]; then
    python_cmd="${CJDOC_PYTHON}"
elif command -v python3.12 >/dev/null 2>&1; then
    python_cmd=python3.12
elif command -v python3 >/dev/null 2>&1; then
    python_cmd=python3
elif command -v python >/dev/null 2>&1; then
    python_cmd=python
else
    echo "error: Python 3 is required" >&2
    exit 2
fi

run_cangjie() {
    local cwd="$1"
    shift
    if [[ -x "${env_runner}" ]]; then
        "${env_runner}" --cwd "${cwd}" "$@"
    else
        (cd "${cwd}" && "$@")
    fi
}

rm -rf "${work_dir}"
mkdir -p "${project_dir}/src"

{
    printf '[package]\n'
    printf 'cjc-version = "1.1.0"\n'
    printf 'name = "cjdoc_perf_fixture"\n'
    printf 'version = "0.0.0"\n'
    printf 'output-type = "static"\n'
    printf '\n[dependencies]\n'
} >"${project_dir}/cjpm.toml"

for ((file_index = 0; file_index < file_count; file_index++)); do
    source_file="${project_dir}/src/generated_${file_index}.cj"
    printf 'package cjdoc_perf_fixture\n\n' >"${source_file}"
    for ((index = file_index; index < symbol_count; index += file_count)); do
        printf 'public func symbol%s(): Int64 { %s }\n' "${index}" "${index}" >>"${source_file}"
    done
done

start_ns="$("${python_cmd}" "${repo_root}/scripts/portable_probe.py" monotonic-ns)"
if [[ -x "${env_runner}" ]]; then
    "${python_cmd}" "${repo_root}/scripts/run_with_peak_memory.py" --output "${work_dir}/cold-peak-kib.txt" -- \
        "${env_runner}" --cwd "${repo_root}" "${binary}" \
        --project "${project_dir}" --format json --jobs auto --output "${work_dir}/first.json"
else
    "${python_cmd}" "${repo_root}/scripts/run_with_peak_memory.py" --output "${work_dir}/cold-peak-kib.txt" -- \
        "${binary}" --project "${project_dir}" --format json --jobs auto \
        --output "${work_dir}/first.json"
fi
end_ns="$("${python_cmd}" "${repo_root}/scripts/portable_probe.py" monotonic-ns)"
cold_elapsed_ms="$(((end_ns - start_ns) / 1000000))"

start_ns="$("${python_cmd}" "${repo_root}/scripts/portable_probe.py" monotonic-ns)"
run_cangjie "${repo_root}" "${binary}" \
    --project "${project_dir}" --format json --jobs auto --output "${work_dir}/second.json"
end_ns="$("${python_cmd}" "${repo_root}/scripts/portable_probe.py" monotonic-ns)"
hot_elapsed_ms="$(((end_ns - start_ns) / 1000000))"
cmp "${work_dir}/first.json" "${work_dir}/second.json"
test "$(find "${project_dir}/target/cjdoc/cache/source-v2" -type f -name '*.cache' | wc -l)" -eq "${file_count}"
jq -e --argjson expected "${symbol_count}" '.symbols | length == $expected' \
    "${work_dir}/first.json" >/dev/null

if [[ "${enforce_thresholds}" == "1" ]] && ((cold_elapsed_ms > max_millis)); then
    echo "performance gate failed: cold ${cold_elapsed_ms} ms > ${max_millis} ms for ${symbol_count} symbols" >&2
    exit 1
fi
if [[ "${enforce_thresholds}" == "1" ]] && ((hot_elapsed_ms > hot_max_millis)); then
    echo "performance gate failed: hot ${hot_elapsed_ms} ms > ${hot_max_millis} ms for ${symbol_count} symbols" >&2
    exit 1
fi
peak_kib="$(cat "${work_dir}/cold-peak-kib.txt")"
if [[ "${enforce_thresholds}" == "1" ]] && ((peak_kib >= 0 && peak_kib > max_peak_kib)); then
    echo "performance gate failed: peak ${peak_kib} KiB > ${max_peak_kib} KiB" >&2
    exit 1
fi

if [[ "${enforce_thresholds}" != "1" ]]; then
    echo "performance gate passed: cold ${cold_elapsed_ms} ms, hot ${hot_elapsed_ms} ms, peak ${peak_kib} KiB, thresholds recorded but not enforced on this host, ${symbol_count} symbols across ${file_count} files"
elif ((peak_kib < 0)); then
    echo "performance gate passed: cold ${cold_elapsed_ms} ms, hot ${hot_elapsed_ms} ms, peak RSS unsupported on this host, ${symbol_count} symbols across ${file_count} files"
else
    echo "performance gate passed: cold ${cold_elapsed_ms} ms, hot ${hot_elapsed_ms} ms, peak ${peak_kib} KiB, ${symbol_count} symbols across ${file_count} files"
fi
