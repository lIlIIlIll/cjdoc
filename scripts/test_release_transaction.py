from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RELEASE_CHECK = Path(__file__).resolve().parent / "release_check.sh"


class ReleaseTransactionTest(unittest.TestCase):
    @staticmethod
    def bash_command(script: str) -> list[str]:
        if os.name != "nt":
            return ["bash", script]
        git = shutil.which("git")
        if git is None:
            raise AssertionError("Git for Windows is required by release tests")
        git_path = Path(git).resolve()
        anchors = list(git_path.parents[:6])
        exec_path = subprocess.run(
            [git, "--exec-path"], text=True, capture_output=True, check=False,
        )
        if exec_path.returncode == 0 and exec_path.stdout.strip():
            anchors.extend(Path(exec_path.stdout.strip()).resolve().parents[:6])
        candidates = []
        for anchor in anchors:
            candidates.extend((
                anchor / "bash.exe",
                anchor / "bin/bash.exe",
                anchor / "usr/bin/bash.exe",
            ))
        for candidate in candidates:
            if candidate.is_file():
                return [str(candidate), script]
        raise AssertionError("Git for Windows bash.exe was not found beside git.exe")

    def make_fake_repo(self, root: Path, *, fail_check: bool,
                       mismatch_commit: bool = False,
                       performance_verdict: str = "passed") -> None:
        scripts = root / "scripts"
        # This is a Git Bash shebang wrapper, not a Windows PE executable.
        binary = root / "target/release/bin/main"
        scripts.mkdir(parents=True)
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        binary.chmod(0o755)
        (scripts / "release_check.sh").write_bytes(RELEASE_CHECK.read_bytes())
        (scripts / "release_check.sh").chmod(0o755)
        (scripts / "safe_output_root.py").write_bytes(
            (Path(__file__).resolve().parent / "safe_output_root.py").read_bytes()
        )
        (scripts / "strict_json.py").write_bytes(
            (Path(__file__).resolve().parent / "strict_json.py").read_bytes()
        )
        (scripts / "check.sh").write_text(
            "#!/usr/bin/env bash\n" + ("exit 9\n" if fail_check else "exit 0\n"),
            encoding="utf-8",
        )
        (scripts / "check.sh").chmod(0o755)
        (scripts / "verify_release.py").write_text(
            "import json,sys\n"
            "if '--evidence' in sys.argv:\n"
            " p=sys.argv[sys.argv.index('--evidence')+1]\n"
            " open(p,'w',encoding='utf-8').write(json.dumps({"
            "'schemaVersion':'cjdoc.release-evidence/2','tag':'v0.7.0',"
            "'commit':'c'*40,'tree':'t'*40}))\n",
            encoding="utf-8",
        )
        (scripts / "real_repository_smoke.py").write_text(
            "import json,sys\n"
            "p=sys.argv[sys.argv.index('--evidence')+1]\n"
            "open(p,'w',encoding='utf-8').write(json.dumps({"
            "'schemaVersion':'cjdoc.real-repository-smoke/1',"
            "'sourceCommit':'c'*40,'binarySha256':'b'*64}))\n",
            encoding="utf-8",
        )
        (scripts / "perf_gate.py").write_text(
            "import json,sys\n"
            "p=sys.argv[sys.argv.index('--evidence')+1]\n"
            "open(p,'w',encoding='utf-8').write(json.dumps({"
            "'schemaVersion':'cjdoc.perf-evidence/2','kind':'hard-ceiling',"
            f"'verdict':'{performance_verdict}','regressionEvidence':False,"
            f"'sourceCommit':'{'d' if mismatch_commit else 'c'}'*40,"
            "'binarySha256':'b'*64}))\n",
            encoding="utf-8",
        )

    def run_gate(self, repo: Path) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            self.bash_command("scripts/release_check.sh"), cwd=repo, text=True,
            capture_output=True, check=False,
            env={
                **os.environ,
                "CJDOC_RELEASE_TAG": "v0.7.0",
                "CJDOC_PYTHON": os.environ.get("CJDOC_PYTHON", sys.executable),
            },
        )
        return result

    def test_failed_gate_removes_stale_final_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_fake_repo(repo, fail_check=True)
            stale = repo / "target/release-evidence"
            stale.mkdir()
            (stale / "gate.json").write_text("stale", encoding="utf-8")
            result = self.run_gate(repo)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(stale.exists())
            self.assertEqual(list((repo / "target").glob(".release-evidence.*")), [])

    def test_success_promotes_one_complete_evidence_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_fake_repo(repo, fail_check=False)
            result = self.run_gate(repo)
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            evidence = repo / "target/release-evidence"
            self.assertEqual(
                {path.name for path in evidence.iterdir()},
                {"metadata.json", "real-repository.json", "performance.json", "gate.json"},
            )
            self.assertEqual(list((repo / "target").glob(".release-evidence.*")), [])

    def test_mismatched_evidence_is_not_promoted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_fake_repo(repo, fail_check=False, mismatch_commit=True)
            result = self.run_gate(repo)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("source commits do not match", result.stderr)
            self.assertFalse((repo / "target/release-evidence").exists())
            self.assertEqual(list((repo / "target").glob(".release-evidence.*")), [])

    def test_candidate_performance_receipt_is_not_promoted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_fake_repo(
                repo, fail_check=False, performance_verdict="candidate"
            )
            result = self.run_gate(repo)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected performance evidence class", result.stderr)
            self.assertFalse((repo / "target/release-evidence").exists())

    def test_release_gate_rejects_a_symlinked_target_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            self.make_fake_repo(repo, fail_check=False)
            outside = root / "outside-target"
            (repo / "target").rename(outside)
            (repo / "target").symlink_to(outside, target_is_directory=True)
            result = self.run_gate(repo)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contains a symlink", result.stderr)


if __name__ == "__main__":
    unittest.main()
