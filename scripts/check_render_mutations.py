#!/usr/bin/env python3
"""Require four real renderer test failures after isolated source mutations."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass

from apply_sts_override import patch


@dataclass(frozen=True)
class Mutation:
    name: str
    case: str
    path: str
    before: str
    after: str


_RENDER_LOCALE = '        let locale = documentation.readingLanguage.getOrDefault({ => "en" })'
_RENDER_FAILURE = '''        for (declaration in documentation.declarations) {
            if (let Some(typeRef) <- declaration.returnType) {
                if (let Some(navigation) <- typeRef.navigation) {
                    if (navigation.url.startsWith("javascript:")) {
                        throw IllegalArgumentException("unexpected renderer failure")
                    }
                }
            }
        }
'''
_MUTATIONS = (
    Mutation("unexpected renderer exception", "unsafeNavigationNeverProducesClickableDestinations",
             "src/render/renderers_output.cj", _RENDER_LOCALE, _RENDER_FAILURE + _RENDER_LOCALE),
    Mutation("changed anchor hash input order", "subjectOnlyDefaultReferenceKeepsFallbackProvenanceAndResolvedLink",
             "src/render/html/html_language.cj", '"doc-field-" + contractFingerprint(fieldId)',
             '"doc-field-" + contractFingerprint(fieldId[1..] + fieldId[..1])'),
    Mutation("admitted legacy API surface", "rejectsLegacyApiSurfaceVersions",
             "src/render/api_contract_codec.cj", 'if (version != API_SURFACE_SCHEMA_VERSION) {',
             'if (version != API_SURFACE_SCHEMA_VERSION && version != "cjdoc.api-surface/1") {'),
    Mutation("removed group decoder limit", "rejectsOneGroupBeyondTheWireLimit",
             "src/render/codec/doc_ir_metadata_codec.cj",
             '    if (groupNodes.size() > 2048) { fail("${path}.groups", "metadata definition limit exceeded") }\n',
             ''),
)


def run(repo: Path, target: Path, work: Path, cases: list[str]) -> subprocess.CompletedProcess[str]:
    command = [os.environ.get("CJDOC_REAL_CJPM", "cjpm"), "test", "--incremental", "--jobs", "1",
               "--parallel", "1", "--no-progress", "--no-color", "--target-dir", str(target),
               "--filter", ",".join(f"*{case}" for case in cases), "src/render"]
    environment = dict(os.environ, CJDOC_TEST_ROOT=str(repo), TMPDIR=str(work), TMP=str(work), TEMP=str(work))
    return subprocess.run([sys.executable, str(repo / "scripts/run_with_timeout.py"), "1800", "--", *command],
                          cwd=repo, env=environment, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)


def case_result(result: subprocess.CompletedProcess[str], case: str, disposition: str) -> bool:
    return re.search(rf"\[\s*{disposition}\s*\] CASE: {re.escape(case)}\b", result.stdout) is not None


def require(condition: bool, message: str, result: subprocess.CompletedProcess[str], work: Path) -> None:
    if condition:
        return
    print(result.stdout[-8000:].replace(str(work), "<mutation-work>"), end="", file=sys.stderr)
    raise ValueError(f"{message} (exit {result.returncode})")


def apply_mutation(source: Path, mutation: Mutation) -> bytes:
    original = source.read_bytes()
    before = mutation.before.encode("utf-8")
    if original.count(before) != 1:
        raise ValueError(f"{mutation.name}: expected one exact mutation anchor in {mutation.path}")
    source.write_bytes(original.replace(before, mutation.after.encode("utf-8"), 1))
    return original


def prove(repo: Path, work: Path) -> None:
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    archive = work / "source.tar"
    subprocess.run(["git", "archive", "--output", str(archive), revision], cwd=repo, check=True)
    source = work / "source"
    source.mkdir()
    with tarfile.open(archive) as bundle:
        bundle.extractall(source, filter="data")
    backup = work / "manifests"
    backup.mkdir()
    patch([source / "cjpm.toml"], backup, command="test")
    target = work / "target"
    print(f"Mutation source: {revision}", flush=True)
    cases = [row.case for row in _MUTATIONS]
    baseline = run(source, target, work, cases)
    require(baseline.returncode == 0 and all(case_result(baseline, name, "PASSED") for name in cases),
            "baseline did not pass every selected test", baseline, work)
    print(f"Baseline: {len(cases)} selected assertions passed", flush=True)
    for mutation in _MUTATIONS:
        path = source / mutation.path
        original = apply_mutation(path, mutation)
        try:
            result = run(source, target, work, [mutation.case])
            require(result.returncode not in (0, 124, 137) and case_result(result, mutation.case, "FAILED"),
                    f"{mutation.name}: no assertion failure in {mutation.case}", result, work)
            print(f"Killed: {mutation.name} — {mutation.case}", flush=True)
        finally:
            path.write_bytes(original)
    print(f"Render mutations: {len(_MUTATIONS)} assertion failures observed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    temp = os.environ.get("RUNNER_TEMP")
    if not temp:
        parser.error("prepare the STS shell and its disk-backed RUNNER_TEMP first")
    try:
        with tempfile.TemporaryDirectory(prefix="cjdoc-render-mutations-", dir=temp) as work:
            prove(args.repo.resolve(strict=True), Path(work).resolve())
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"render mutations: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
