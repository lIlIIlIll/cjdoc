#!/usr/bin/env bash
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_cmd="${CJDOC_PYTHON:-python3}"
binary="${repo_root}/target/release/bin/main"
# The release ships the CLI together with the CHIR worker it discovers beside
# itself, so the gate must seal both artefacts here, not decide later that some
# worker on disk belongs to this build.
worker_binary="$("${python_cmd}" - "${repo_root}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
from release_package_contracts import worker_executable
print(Path(sys.argv[1]) / "target/release/bin" / worker_executable(
    sys.platform.startswith("win")))
PY
)"
manifest="${repo_root}/target/ci-build/build-manifest.json"

: "${CJDOC_RELEASE_TAG:?set CJDOC_RELEASE_TAG to the exact release tag, for example v0.7.0}"

cd "${repo_root}"
"${python_cmd}" scripts/safe_output_root.py \
    --repo "${repo_root}" --directory "${repo_root}/target" --create >/dev/null
target_root="${repo_root}/target"
evidence_dir="${target_root}/release-evidence"
"${python_cmd}" scripts/safe_output_root.py \
    --repo "${repo_root}" --directory "${evidence_dir}" --allow-missing >/dev/null
rm -rf "${evidence_dir}"
staging_dir="$(mktemp -d "${target_root}/.release-evidence.XXXXXX")"
cleanup() {
    rm -rf "${staging_dir}"
}
trap cleanup EXIT

"${python_cmd}" scripts/verify_release.py \
    --tag "${CJDOC_RELEASE_TAG}" >/dev/null

scripts/check.sh \
    --main-binary-out "${repo_root}/target/release/bin/main" \
    --worker-binary-out "${worker_binary}" \
    --manifest "${manifest}"

if [[ -x "${binary}" || ( -f "${binary}" && ( "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ) ) ]]; then
    :
elif [[ -f "${binary}.exe" ]]; then
    binary="${binary}.exe"
else
    echo "cjdoc binary is missing or not executable: ${binary}" >&2
    exit 1
fi

# This documents the whole repository, which exceeds the default heap; the same
# ceiling `check.sh`'s smoke stage uses (see CJDOC_SMOKE_HEAP there).
cjHeapSize="${CJDOC_SMOKE_HEAP:-2GB}" "${python_cmd}" scripts/real_repository_smoke.py \
    --binary "${binary}" \
    --project "${repo_root}" \
    --evidence "${staging_dir}/real-repository.json"

"${python_cmd}" scripts/perf_gate.py check \
    --binary "${binary}" \
    --baseline tests/perf/baseline.json \
    --evidence "${staging_dir}/performance.json"

# Re-check Git identity and cleanliness after all gates so the promoted receipt
# is bound to the source tree that actually produced the evidence.
"${python_cmd}" scripts/verify_release.py \
    --tag "${CJDOC_RELEASE_TAG}" \
    --evidence "${staging_dir}/metadata.json" >/dev/null

"${python_cmd}" - "${staging_dir}" "${worker_binary}" "${manifest}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys
from scripts.strict_json import strict_dumps, strict_load

root = Path(sys.argv[1])
worker = Path(sys.argv[2])
manifest_path = Path(sys.argv[3])
inputs = [root / name for name in ("metadata.json", "real-repository.json", "performance.json")]
metadata, real_repository, performance = (
    strict_load(path, description=f"release evidence {path.name}") for path in inputs
)
if metadata.get("schemaVersion") != "cjdoc.release-evidence/2":
    raise SystemExit("unexpected release metadata schema")
if real_repository.get("schemaVersion") != "cjdoc.real-repository-smoke/1":
    raise SystemExit("unexpected real-repository evidence schema")
if performance.get("schemaVersion") != "cjdoc.perf-evidence/2" or \
        performance.get("kind") != "hard-ceiling" or \
        performance.get("verdict") != "passed" or \
        performance.get("regressionEvidence") is not False:
    raise SystemExit("unexpected performance evidence class")
commit = metadata.get("commit")
if performance.get("sourceCommit") != commit or real_repository.get("sourceCommit") != commit:
    raise SystemExit("release evidence source commits do not match")
binary_sha256 = performance.get("binarySha256")
if real_repository.get("binarySha256") != binary_sha256:
    raise SystemExit("release evidence binary hashes do not match")
# The worker shipped beside the CLI must be the artefact the sealed build
# produced in this same job: fixing only the CLI would let a differently built
# (even same-version) worker be packaged as part of an accepted release.
manifest = strict_load(manifest_path, description="sealed build manifest")
if not worker.is_file():
    raise SystemExit(f"release CHIR worker is missing: {worker}")
worker_sha256 = hashlib.sha256(worker.read_bytes()).hexdigest()
sealed_worker = (manifest.get("workerBinary") or {})
if sealed_worker.get("sha256") != worker_sha256 or \
        sealed_worker.get("size") != worker.stat().st_size:
    raise SystemExit("release CHIR worker is not the artefact the sealed build produced")
receipt = {
    "schemaVersion": "cjdoc.release-gate/4",
    "identity": {
        "tag": metadata.get("tag"),
        "commit": commit,
        "tree": metadata.get("tree"),
        "binarySha256": binary_sha256,
        "workerSha256": worker_sha256,
        # The release candidate receipt re-checks these so a cached toolchain
        # cannot silently substitute a different SDK or stdx archive.
        "sdkVersion": os.environ.get("CJDOC_TOOLCHAIN_VERSION", ""),
        "stdxDigest": os.environ.get("CJDOC_STDX_DIGEST", ""),
        "toolchainFingerprint": os.environ.get("CJDOC_TOOLCHAIN_FINGERPRINT", ""),
    },
    "gates": {
        path.stem: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in inputs
    },
}
(root / "gate.json").write_text(
    strict_dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
    newline="\n",
)
PY

"${python_cmd}" - "${staging_dir}" "${evidence_dir}" <<'PY'
import os
from pathlib import Path
import sys

staging = Path(sys.argv[1])
destination = Path(sys.argv[2])
os.rename(staging, destination)
PY
trap - EXIT

echo "cjdoc release gate passed"
