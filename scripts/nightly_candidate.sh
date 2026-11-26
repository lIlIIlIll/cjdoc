#!/usr/bin/env bash
# Each attempt owns its checkout, SDK installation, wrapper log and build outputs.
set -euo pipefail

if [[ $# -eq 0 ]]; then
    if [[ -n "${NIGHTLY_UNAVAILABLE_REASON}" ]]; then
        printf '::error::%s: %s\n' "$NIGHTLY_PLATFORM" "$NIGHTLY_UNAVAILABLE_REASON"
        exit 1
    fi
    script="${BASH_SOURCE[0]}"
    assets="${RUNNER_TEMP}/nightly-assets"
    [[ ! -e "$assets" && ! -L "$assets" ]]
    status=1
    for attempt in 1 2 3 4; do
        attempt_root="$(mktemp -d "${RUNNER_TEMP}/n.XXXXXXXX")"
        printf '::group::%s candidate attempt %d/4\n' "$NIGHTLY_PLATFORM" "$attempt"
        if python scripts/run_with_timeout.py 4800 -- bash "$script" --attempt "$attempt_root"; then
            # Promote only after the timed process reports success.
            mv -- "${attempt_root}/upload" "$assets"
            status=0
        else
            status=$?
        fi
        printf '::endgroup::\n'
        rm -rf -- "$attempt_root"
        if (( status == 0 )); then
            exit 0
        fi
        printf '::warning::%s candidate attempt %d/4 failed (exit %d)\n' "$NIGHTLY_PLATFORM" "$attempt" "$status"
    done
    exit "$status"
fi

[[ $# -eq 2 && "$1" == --attempt ]]
attempt_root="$2"
git -c core.longpaths=true clone --quiet --shared --single-branch --no-tags --no-checkout \
    --config core.longpaths=true --config core.autocrlf=false \
    -- "$GITHUB_WORKSPACE" "${attempt_root}/src"
cd "${attempt_root}/src"
git -c advice.detachedHead=false checkout --quiet --detach "$GITHUB_SHA"

mkdir -- "${attempt_root}/tmp"
export RUNNER_TEMP="${attempt_root}/tmp"
if [[ "$RUNNER_OS" == Windows ]]; then
    export GITHUB_WORKSPACE="$(pwd -W)"
else
    export GITHUB_WORKSPACE="$(pwd -P)"
fi
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
export CJDOC_STS_INVOCATION_LOG="${RUNNER_TEMP}/cjdoc-sts-invocations.jsonl"

sdk_env="${RUNNER_TEMP}/installed-sdk.env"
python scripts/install_cangjie_sdk.py \
    --url "$NIGHTLY_SDK_URL" --sha256 "$NIGHTLY_SDK_SHA256" \
    --stdx-url "$NIGHTLY_STDX_URL" --stdx-sha256 "$NIGHTLY_STDX_SHA256" \
    --destination "${attempt_root}/sdk" --github-output "$sdk_env"
{
    IFS= read -r sdk_root
    IFS= read -r stdx_root
} < "$sdk_env"
[[ "$sdk_root" == root=* && "$stdx_root" == stdx_static=* ]]
export CANGJIE_SDK_ROOT="${sdk_root#root=}"
# SDK setup scripts are sourced before enabling nounset for their code.
set +u
source "${CANGJIE_SDK_ROOT}/envsetup.sh"
set -u
export CANGJIE_STDX_PATH="${stdx_root#stdx_static=}"

# Keep spaces in environment values such as compilerVersion; do not evaluate them.
python scripts/with_stdx.py --variant static --print-env -- > "${RUNNER_TEMP}/stdx.env"
while IFS= read -r setting; do
    export "${setting%$'\r'}"
done < "${RUNNER_TEMP}/stdx.env"
if [[ "$CJDOC_TOOLCHAIN_VERSION" != "$NIGHTLY_SDK_VERSION ("* ]]; then
    printf '::error::Installed compiler %s does not match SDK %s\n' \
        "$CJDOC_TOOLCHAIN_VERSION" "$NIGHTLY_SDK_VERSION"
    exit 1
fi

. scripts/with_sts_cjpm.sh
manifest=target/ci-build/build-manifest.json
binary=target/release/bin/main
worker=target/release/bin/chir-worker-main
if [[ "$RUNNER_OS" == Windows ]]; then
    binary+=.exe
    worker+=.exe
fi
bash scripts/check.sh --main-binary-out target/release/bin/main \
    --worker-binary-out "$worker" --manifest "$manifest"

# The existing macOS source-edge check uses a copy of this tracked CRLF fixture.
if [[ "$RUNNER_OS" == macOS ]]; then
    fixture=tests/fixtures/projects/source_edges/src/fixture.cj
    git cat-file blob "${GITHUB_SHA}:${fixture}" > "$fixture"
fi
gates=(--gate target/ci-evidence/stages.json)
if [[ "$RUNNER_OS" == Linux ]]; then
    bash scripts/check.sh smoke --identity "$manifest" --main-binary "$binary"
    gates+=(--gate target/ci-evidence/real-repository.json)
fi

receipt=target/release-candidate/nightly.json
python scripts/release_candidate_receipt.py \
    --tag "$NIGHTLY_TAG" \
    --platform "$NIGHTLY_PLATFORM" --binary "$binary" --worker-binary "$worker" \
    --build-manifest "$manifest" --sdk-version "$NIGHTLY_SDK_VERSION" \
    --sdk-archive-sha256 "$NIGHTLY_SDK_SHA256" --stdx-version "$NIGHTLY_STDX_VERSION" \
    --stdx-archive-sha256 "$NIGHTLY_STDX_SHA256" "${gates[@]}" --output "$receipt"
python scripts/package_release.py \
    --platform "$NIGHTLY_PLATFORM" --binary "$binary" --worker-binary "$worker" \
    --source-commit "$GITHUB_SHA" --release-tag "$NIGHTLY_TAG" \
    --sdk-version "$NIGHTLY_SDK_VERSION" --sdk-sha256 "$NIGHTLY_SDK_SHA256" \
    --stdx-version "$NIGHTLY_STDX_VERSION" --stdx-sha256 "$NIGHTLY_STDX_SHA256" \
    --candidate-receipt "$receipt"

# Carry the same directory layout through one or several artifact downloads.
artifact="nightly-${NIGHTLY_PLATFORM}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -- "${attempt_root}/upload"
mv -- target/release-package "${attempt_root}/upload/${artifact}"
