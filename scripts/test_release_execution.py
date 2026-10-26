"""Exercise the release acceptance shell with a gate that owns its build."""
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


def acceptance_command() -> str:
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    candidate = workflow.split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
    step = candidate.split("      - name: Run the platform acceptance gates\n", 1)[1]
    body = step.split("\n      - name:", 1)[0].split("        run: |\n", 1)[1]
    return "\n".join(line[10:] for line in body.splitlines()) + "\n"


@unittest.skipUnless(SHELL, "no usable POSIX shell")
class ReleaseExecutionTest(unittest.TestCase):
    def invoke(self, platform: str, *, gate_exit: int = 0, reject_repeat: bool = False):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            scripts, sdk, runner = repo / "scripts", repo / "sdk", repo / "runner"
            for path in (scripts, sdk, runner):
                path.mkdir()
            (sdk / "envsetup.sh").write_text(":\n", encoding="utf-8")
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
                "if [[ \"$PROBE_GATE_EXIT\" != 0 ]]; then exit \"$PROBE_GATE_EXIT\"; fi\n"
                "printf '%s\\n' accepted >> \"$PROBE_TRACE\"\n", encoding="utf-8")
            (scripts / "release_check.sh").write_text("exec bash scripts/check.sh\n", encoding="utf-8")
            observer = (
                "import os,sys\nfrom pathlib import Path\n"
                "with Path(os.environ['PROBE_TRACE']).open('a') as log:\n"
                " log.write(Path(__file__).name+'\\n')\n"
                " if '--binary' in sys.argv:\n"
                "  binary=Path(sys.argv[sys.argv.index('--binary')+1])\n"
                "  assert binary.read_bytes()==b'accepted'\n"
                "  log.write('verified-binary\\n')\n")
            for name in ("verify_release.py", "release_build_parameters.py", "verify_repository_inputs.py"):
                (scripts / name).write_text(observer, encoding="utf-8")
            body = acceptance_command().replace("${{ matrix.platform }}", platform)
            prelude = 'python() { "$PROBE_PYTHON" "$@"; }; xattr() { :; }; export -f python\n'
            command = repo / "acceptance.sh"
            command.write_text(prelude + body, encoding="utf-8")
            environment = dict(os.environ, CANGJIE_SDK_ROOT=sdk.as_posix(), CJDOC_STDX_PATH="fixture-stdx",
                               RUNNER_TEMP=runner.as_posix(),
                               RUNNER_OS={"windows-x64": "Windows", "macos-arm64": "macOS", "linux-x64": "Linux"}[platform],
                               PROBE_PYTHON=Path(sys.executable).as_posix(), PROBE_TRACE=(repo / "trace.txt").as_posix(),
                               PROBE_GATE_EXIT=str(gate_exit), PROBE_REJECT_REPEAT="1" if reject_repeat else "0")
            result = subprocess.run([SHELL, command.as_posix()], cwd=repo, env=environment,
                                    capture_output=True, text=True)
            trace = (repo / "trace.txt").read_text().splitlines()
            return result, trace

    def test_each_platform_builds_only_inside_acceptance(self):
        for platform in ("linux-x64", "macos-arm64", "windows-x64"):
            with self.subTest(platform=platform):
                result, trace = self.invoke(platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(trace.count("build:build --jobs 1"), 1, trace)
                self.assertLess(trace.index("release_build_parameters.py"), trace.index("acceptance"))
                self.assertLess(trace.index("acceptance"), trace.index("build:build --jobs 1"))
                self.assertGreater(trace.index("verified-binary"), trace.index("accepted"))

    def test_a_second_build_is_not_required_to_accept_the_first(self):
        result, trace = self.invoke("windows-x64", reject_repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.count("build:build --jobs 1"), 1, trace)

    def test_acceptance_failure_keeps_its_exit_and_prevents_binary_verification(self):
        result, trace = self.invoke("linux-x64", gate_exit=9)
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertNotIn("verified-binary", trace)
        self.assertNotIn("accepted", trace)


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
