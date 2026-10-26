"""Exercise release shell steps with a build-owning gate and real Git identity."""
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from scripts.release_build_parameters import usable_shell

ROOT = Path(__file__).resolve().parent.parent
SHELL = usable_shell()
SOURCE_EDGE = "tests/fixtures/projects/source_edges/src/fixture.cj"
PRISTINE = b"package source_edges_fixture\r\n"
STEPS = (
    "Snapshot pristine source-edge fixture",
    "Run the platform acceptance gates",
    "Restore pristine source-edge fixture",
    "Write the release candidate receipt",
)


def release_commands() -> dict[str, str]:
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    candidate = workflow.split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
    result = {}
    for step in candidate.split("      - name: ")[1:]:
        name = step.splitlines()[0]
        if name in STEPS:
            header, body = step.split("        run: |\n", 1)
            if name == STEPS[2]:
                assert "if: always() && matrix.platform == 'macos-arm64'" in header
                assert "steps.source-edge-snapshot.outcome == 'success'" in header
            elif name == STEPS[0]:
                assert "if: matrix.platform == 'macos-arm64'" in header
            else:
                assert "\n        if:" not in header
            result[name] = "\n".join(line[10:] for line in body.splitlines()) + "\n"
    assert tuple(result) == STEPS
    return result


def write_probe_scripts(repo: Path) -> None:
    scripts = repo / "scripts"
    scripts.mkdir()
    (scripts / "with_sts_cjpm.sh").write_text(
        "cjpm() {\n"
        "  printf '%s\\n' \"build:$*\" >> \"$PROBE_TRACE\"\n"
        "  if [[ \"${PROBE_REJECT_REPEAT:-0}\" == 1 && -f target/release/bin/main ]]; then return 17; fi\n"
        "  mkdir -p target/release/bin\n"
        "  printf accepted > target/release/bin/main\n"
        "  cp target/release/bin/main target/release/bin/main.exe\n"
        "}\nexport -f cjpm\n", encoding="utf-8")
    (scripts / "check.sh").write_text(
        "set -euo pipefail\n"
        "printf '%s\\n' acceptance >> \"$PROBE_TRACE\"\n"
        "cjpm build --jobs 1\n"
        "case \"$PROBE_FAULT\" in\n"
        f"  renormalize) printf 'package source_edges_fixture\\n' > {SOURCE_EDGE} ;;\n"
        "  dirty-source) printf '// changed\\n' >> other.cj ;;\n"
        "  remove-snapshot) rm \"$RUNNER_TEMP/source-edge-fixture.cj\" ;;\n"
        "esac\n"
        "if [[ \"$PROBE_GATE_EXIT\" != 0 ]]; then exit \"$PROBE_GATE_EXIT\"; fi\n"
        "printf '%s\\n' accepted >> \"$PROBE_TRACE\"\n", encoding="utf-8")
    (scripts / "release_check.sh").write_text("exec bash scripts/check.sh\n", encoding="utf-8")
    observer = (
        "import os,sys\nfrom pathlib import Path\n"
        "name=Path(__file__).name\n"
        "with Path(os.environ['PROBE_TRACE']).open('a') as log:\n"
        " log.write(name+'\\n')\n"
        " if name=='verify_repository_inputs.py':\n"
        "  from scripts.worktree_identity import exact_worktree_identity\n"
        "  exact_worktree_identity(Path.cwd())\n"
        " if name=='verify_release.py' and os.environ['PROBE_FAULT']=='post-release' "
        "and Path('target/release/bin/main').exists():\n"
        "  raise SystemExit(23)\n"
        " if '--binary' in sys.argv:\n"
        "  binary=Path(sys.argv[sys.argv.index('--binary')+1])\n"
        "  assert binary.read_bytes()==b'accepted'\n"
        "  log.write('verified-binary\\n')\n")
    for name in ("verify_release.py", "release_build_parameters.py", "verify_repository_inputs.py",
                 "release_candidate_receipt.py"):
        (scripts / name).write_text(observer, encoding="utf-8")
    fixture = repo / SOURCE_EDGE
    fixture.parent.mkdir(parents=True)
    fixture.write_bytes(PRISTINE)
    (repo / "other.cj").write_text("package other\n", encoding="utf-8")


def commit_probe(repo: Path) -> None:
    # Test-only repository: preserve raw CRLF and avoid detached maintenance races.
    for arguments in (("init", "-q"), ("add", "."), ("commit", "-q", "-m", "fixture")):
        subprocess.run([
            "git", "-c", "maintenance.auto=false", "-c", "gc.auto=0",
            "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
            "-c", "core.autocrlf=false", "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid", *arguments,
        ], cwd=repo, capture_output=True, check=True)


@unittest.skipUnless(SHELL, "no usable POSIX shell")
class ReleaseExecutionTest(unittest.TestCase):
    def invoke(self, platform: str, *, gate_exit: int = 0, reject_repeat: bool = False, fault: str = ""):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            repo, sdk, runner = base / "repo", base / "sdk", base / "runner"
            for path in (repo, sdk, runner):
                path.mkdir()
            (sdk / "envsetup.sh").write_text(":\n", encoding="utf-8")
            write_probe_scripts(repo)
            commit_probe(repo)
            trace_path = base / "trace.txt"
            environment = dict(
                os.environ, CANGJIE_SDK_ROOT=sdk.as_posix(), CJDOC_STDX_PATH="fixture-stdx",
                CJDOC_RELEASE_TAG="v0.7.6", CJDOC_RELEASE_COMMIT="1" * 40,
                RUNNER_TEMP=runner.as_posix(),
                RUNNER_OS={"windows-x64": "Windows", "macos-arm64": "macOS", "linux-x64": "Linux"}[platform],
                PROBE_PYTHON=Path(sys.executable).as_posix(), PROBE_TRACE=trace_path.as_posix(),
                PROBE_GATE_EXIT=str(gate_exit), PROBE_REJECT_REPEAT="1" if reject_repeat else "0",
                PROBE_FAULT=fault, PYTHONPATH=str(ROOT), PYTHONDONTWRITEBYTECODE="1")
            prelude = 'python() { "$PROBE_PYTHON" "$@"; }; xattr() { :; }; export -f python\n'
            result = subprocess.CompletedProcess([], 0, "", "")
            first_failure = None
            snapshot_ok = False
            for name, body in release_commands().items():
                mac_step = name in (STEPS[0], STEPS[2])
                if mac_step and platform != "macos-arm64":
                    continue
                if first_failure is not None and name != STEPS[2]:
                    continue
                if name == STEPS[2] and not snapshot_ok:
                    continue
                for expression, value in {
                    "matrix.platform": platform, "runner.os": environment["RUNNER_OS"],
                    "matrix.sdk_sha256": "1" * 64, "matrix.stdx_sha256": "2" * 64,
                }.items():
                    body = body.replace("${{ " + expression + " }}", value)
                with trace_path.open("a") as log:
                    log.write("step:" + name + "\n")
                result = subprocess.run([SHELL, "-c", prelude + body], cwd=repo, env=environment,
                                        capture_output=True, text=True)
                if name == STEPS[0]:
                    snapshot_ok = result.returncode == 0
                if result.returncode and first_failure is None:
                    first_failure = result
            trace = trace_path.read_text().splitlines()
            return first_failure or result, trace, (repo / SOURCE_EDGE).read_bytes()

    def test_each_platform_builds_only_inside_acceptance(self):
        for platform in ("linux-x64", "macos-arm64", "windows-x64"):
            with self.subTest(platform=platform):
                result, trace, _ = self.invoke(platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(trace.count("build:build --jobs 1"), 1, trace)
                self.assertLess(trace.index("release_build_parameters.py"), trace.index("acceptance"))
                self.assertLess(trace.index("acceptance"), trace.index("build:build --jobs 1"))
                self.assertGreater(trace.index("verified-binary"), trace.index("accepted"))

    def test_a_second_build_is_not_required_to_accept_the_first(self):
        result, trace, _ = self.invoke("windows-x64", reject_repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.count("build:build --jobs 1"), 1, trace)

    def test_acceptance_failure_keeps_its_exit_and_prevents_binary_verification(self):
        result, trace, _ = self.invoke("linux-x64", gate_exit=9)
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertNotIn("verified-binary", trace)
        self.assertNotIn("accepted", trace)

    def test_mac_restores_crlf_before_real_cleanliness_check_and_receipt(self):
        result, trace, fixture = self.invoke("macos-arm64", fault="renormalize")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixture, PRISTINE)
        self.assertGreater(trace.index("verify_repository_inputs.py"), trace.index("step:" + STEPS[2]))
        self.assertGreater(trace.index("release_candidate_receipt.py"), trace.index("verify_repository_inputs.py"))

    def test_restoration_does_not_hide_another_dirty_source(self):
        result, trace, _ = self.invoke("macos-arm64", fault="dirty-source")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tracked worktree bytes differ from HEAD: other.cj", result.stderr)
        self.assertNotIn("release_candidate_receipt.py", trace)

    def test_failed_mac_acceptance_still_restores_but_does_not_seal(self):
        result, trace, fixture = self.invoke("macos-arm64", gate_exit=9, fault="renormalize")
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(fixture, PRISTINE)
        self.assertNotIn("verified-binary", trace)
        self.assertNotIn("release_candidate_receipt.py", trace)

    def test_failed_restoration_prevents_receipt(self):
        result, trace, _ = self.invoke("macos-arm64", fault="remove-snapshot")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source-edge-fixture.cj", result.stderr)
        self.assertNotIn("release_candidate_receipt.py", trace)

    def test_post_acceptance_release_identity_failure_prevents_receipt(self):
        result, trace, _ = self.invoke("macos-arm64", fault="post-release")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertNotIn("release_candidate_receipt.py", trace)


class ReleaseRunnerTest(unittest.TestCase):
    def test_release_platform_runners_match_the_accepted_ci_matrix(self):
        def runners(filename):
            text = (ROOT / ".github/workflows" / filename).read_text(encoding="utf-8")
            return dict(re.findall(r"- platform: ([^\n]+)\n\s+runner: ([^\n]+)", text))
        ci, release = runners("ci.yml"), runners("release.yml")
        for platform in ("macos-arm64", "windows-x64"):
            with self.subTest(platform=platform):
                self.assertIn(platform, ci)
                self.assertEqual(release[platform], ci[platform])


if __name__ == "__main__":
    unittest.main()
