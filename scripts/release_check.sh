#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_cmd="${CJDOC_PYTHON:-python3}"
evidence_dir="${repo_root}/target/release-evidence"
binary="${repo_root}/target/release/bin/main"

: "${CJDOC_RELEASE_TAG:?set CJDOC_RELEASE_TAG to the exact release tag, for example v0.6.0}"

cd "${repo_root}"
mkdir -p "${evidence_dir}"

"${python_cmd}" scripts/verify_release.py \
    --tag "${CJDOC_RELEASE_TAG}" \
    --evidence "${evidence_dir}/metadata.json"

scripts/check.sh

if [[ ! -x "${binary}" && -x "${binary}.exe" ]]; then
    binary="${binary}.exe"
fi
test -x "${binary}"

"${python_cmd}" scripts/real_repository_smoke.py \
    --binary "${binary}" \
    --project "${repo_root}" \
    --evidence "${evidence_dir}/real-repository.json"

"${python_cmd}" scripts/perf_gate.py check \
    --binary "${binary}" \
    --baseline tests/perf/baseline.json \
    --evidence "${evidence_dir}/performance.json"

"${python_cmd}" - "${evidence_dir}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
inputs = [root / name for name in ("metadata.json", "real-repository.json", "performance.json")]
receipt = {
    "schemaVersion": "cjdoc.release-gate/1",
    "gates": {
        path.stem: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in inputs
    },
}
(root / "gate.json").write_text(
    json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
    newline="\n",
)
PY

echo "cjdoc release gate passed"
