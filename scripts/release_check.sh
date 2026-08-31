#!/usr/bin/env bash
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_cmd="${CJDOC_PYTHON:-python3}"
binary="${repo_root}/target/release/bin/main"

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

scripts/check.sh

if [[ -x "${binary}" || ( -f "${binary}" && ( "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ) ) ]]; then
    :
elif [[ -f "${binary}.exe" ]]; then
    binary="${binary}.exe"
else
    echo "cjdoc binary is missing or not executable: ${binary}" >&2
    exit 1
fi

"${python_cmd}" scripts/real_repository_smoke.py \
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

"${python_cmd}" - "${staging_dir}" <<'PY'
import hashlib
from pathlib import Path
import sys
from scripts.strict_json import strict_dumps, strict_load

root = Path(sys.argv[1])
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
receipt = {
    "schemaVersion": "cjdoc.release-gate/2",
    "identity": {
        "tag": metadata.get("tag"),
        "commit": commit,
        "tree": metadata.get("tree"),
        "binarySha256": binary_sha256,
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
