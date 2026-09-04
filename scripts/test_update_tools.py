from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from scripts import fixture_snapshot


PROJECT_ROOT = Path(__file__).resolve().parent.parent
GOLDEN_NAMES = (
    "basic",
    "functions",
    "types",
    "extend",
    "source-edges",
    "unsupported",
    "workspace",
    "conditional-linux",
    "path-dependencies",
)
SCHEMA_NAMES = (
    "doc-ir",
    "doc-ir-v6",
    "doc-ir-v7",
    "doc-ir-v8",
    "diagnostics",
    "cfg-matrix",
    "search-index",
    "api-surface",
    "documentation-coverage",
)


class UpdateToolsTest(unittest.TestCase):
    def git(self, repo: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
             "-c", "core.autocrlf=false",
             "-C", str(repo), *args],
            text=True, capture_output=True, check=True,
        )
        return result.stdout.strip()

    def make_repo(self, root: Path) -> None:
        scripts = root / "scripts"
        schemas = root / "docs/schema"
        legacy_v6 = root / "tests/fixtures/golden-v6"
        legacy_v7 = root / "tests/fixtures/golden-v7"
        fixture = root / "tests/fixtures/projects/basic/src"
        # This is a Git Bash shebang wrapper, not a Windows PE executable.
        binary = root / "target/release/bin/main"
        for directory in (scripts, schemas, legacy_v6, legacy_v7, fixture, binary.parent,
                          root / "fake-schemas"):
            directory.mkdir(parents=True, exist_ok=True)
        for name in (
            "fixture_snapshot.py", "update_goldens.sh", "update_schemas.sh",
            "verify_repository_inputs.py", "safe_output_root.py", "strict_json.py",
            "worktree_identity.py", "repository_input_contracts.py",
            "repository_input_files.py", "repository_input_migrations.py",
            "repository_input_vendor.py",
        ):
            shutil.copyfile(PROJECT_ROOT / "scripts" / name, scripts / name)
        for script in (scripts / "update_goldens.sh", scripts / "update_schemas.sh"):
            script.chmod(0o755)

        for name in SCHEMA_NAMES:
            if name in ("doc-ir-v6", "doc-ir-v7"):
                shutil.copyfile(
                    PROJECT_ROOT / "docs/schema" / f"{name}.schema.json",
                    schemas / f"{name}.schema.json",
                )
                shutil.copyfile(
                    PROJECT_ROOT / "docs/schema" / f"{name}.schema.json",
                    root / "fake-schemas" / f"{name}.schema.json",
                )
                continue
            value = json.loads(
                (PROJECT_ROOT / "docs/schema" / f"{name}.schema.json").read_text(
                    encoding="utf-8"
                )
            )
            value["generation"] = "old"
            text = json.dumps(value, sort_keys=True) + "\n"
            (schemas / f"{name}.schema.json").write_text(text, encoding="utf-8")
            generated = {**value, "generation": "new"}
            (root / "fake-schemas" / f"{name}.schema.json").write_text(
                json.dumps(generated, sort_keys=True) + "\n", encoding="utf-8"
            )
        for version, legacy in ((6, legacy_v6), (7, legacy_v7)):
            for name in GOLDEN_NAMES:
                (legacy / f"{name}.docs.json").write_text(
                    f'{{"schemaVersion":"cjdoc.doc-ir/{version}"}}\n', encoding="utf-8"
                )
        (fixture / "fixture.cj").write_text("package basic\n", encoding="utf-8")

        binary.write_text(
            "#!/usr/bin/env python\n"
            "import json,sys\n"
            "from pathlib import Path\n"
            "repo=Path(__file__).resolve().parents[3]\n"
            "args=sys.argv[1:]\n"
            "if args[:2] == ['schema','list']:\n"
            " print('doc-ir\\ndoc-ir-v6\\ndoc-ir-v7\\ndoc-ir-v8\\ndiagnostics\\ncfg-matrix\\nsearch-index\\napi-surface\\ndocumentation-coverage')\n"
            "elif args and args[0] == 'schema':\n"
            " print((repo/'fake-schemas'/f'{args[1]}.schema.json').read_text(encoding='utf-8'),end='')\n"
            "elif args and args[0] == 'generate':\n"
            " out=Path(args[args.index('--output')+1]); out.mkdir(parents=True,exist_ok=True)\n"
            " (out/'docs.json').write_text(json.dumps({'schemaVersion':'cjdoc.doc-ir/8'})+'\\n',encoding='utf-8')\n"
            "else:\n"
            " raise SystemExit(2)\n",
            encoding="utf-8",
        )
        binary.chmod(0o755)

        self.git(root, "init", "-q")
        self.git(root, "config", "user.name", "Fixture")
        self.git(root, "config", "user.email", "fixture@example.invalid")
        self.git(root, "add", "-f", ".")
        self.git(root, "commit", "-q", "-m", "fixture")

    @staticmethod
    def bash_command(script: str) -> list[str]:
        if os.name != "nt":
            return ["bash", script]
        git = shutil.which("git")
        if git is None:
            raise AssertionError("Git for Windows is required by update-tool tests")
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

    @staticmethod
    def run_script(repo: Path, script: str,
                   environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            UpdateToolsTest.bash_command(f"scripts/{script}"), cwd=repo,
            text=True, capture_output=True, check=False,
            env={**os.environ, **(environment or {})},
        )
        return result

    def test_schema_update_preserves_frozen_legacy_and_publishes_complete_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_repo(repo)
            v6 = (repo / "docs/schema/doc-ir-v6.schema.json").read_bytes()
            v7 = (repo / "docs/schema/doc-ir-v7.schema.json").read_bytes()
            result = self.run_script(repo, "update_schemas.sh")
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertEqual((repo / "docs/schema/doc-ir-v6.schema.json").read_bytes(), v6)
            self.assertEqual((repo / "docs/schema/doc-ir-v7.schema.json").read_bytes(), v7)
            self.assertEqual(
                {path.name for path in (repo / "docs/schema").iterdir()},
                {f"{name}.schema.json" for name in SCHEMA_NAMES},
            )
            current = json.loads((repo / "docs/schema/doc-ir-v8.schema.json").read_text())
            self.assertEqual(current["generation"], "new")
            self.assertEqual(list((repo / "docs").glob(".schema.*")), [])

    def test_schema_update_rejects_legacy_drift_without_partial_publish(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_repo(repo)
            before = {
                path.name: path.read_bytes() for path in (repo / "docs/schema").iterdir()
            }
            (repo / "fake-schemas/doc-ir-v7.schema.json").write_text(
                '{"properties":{"schemaVersion":{"const":"cjdoc.doc-ir/7"}},'
                '"drift":true}\n', encoding="utf-8"
            )
            result = self.run_script(repo, "update_schemas.sh")
            self.assertNotEqual(result.returncode, 0)
            after = {
                path.name: path.read_bytes() for path in (repo / "docs/schema").iterdir()
            }
            self.assertEqual(after, before)
            self.assertEqual(list((repo / "docs").glob(".schema.*")), [])

    def test_golden_update_rejects_dirty_fixture_inputs_before_publish(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_repo(repo)
            fixture = repo / "tests/fixtures/projects/basic/src/fixture.cj"
            fixture.write_text("package dirty\n", encoding="utf-8")
            result = self.run_script(repo, "update_goldens.sh")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("dirty repository fixture inputs", result.stderr)
            self.assertFalse((repo / "tests/fixtures/golden-v8").exists())
            self.assertEqual(list((repo / "tests/fixtures").glob(".golden-v8.*")), [])

    def test_golden_update_requires_complete_frozen_v6_and_v7_sets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_repo(repo)
            (repo / "tests/fixtures/golden-v6/functions.docs.json").unlink()
            result = self.run_script(repo, "update_goldens.sh")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("v6 golden set mismatch", result.stderr)
            self.assertFalse((repo / "tests/fixtures/golden-v8").exists())

    def test_golden_update_publishes_only_a_complete_v8_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_repo(repo)
            result = self.run_script(repo, "update_goldens.sh")
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            golden = repo / "tests/fixtures/golden-v8"
            self.assertEqual(
                {path.name for path in golden.iterdir()},
                {f"{name}.docs.json" for name in GOLDEN_NAMES},
            )
            for path in golden.iterdir():
                self.assertEqual(json.loads(path.read_text())["schemaVersion"], "cjdoc.doc-ir/8")
            self.assertEqual(list((repo / "tests/fixtures").glob(".golden-v8.*")), [])

    def test_update_tools_reject_a_symlinked_target_root(self) -> None:
        for script in ("update_goldens.sh", "update_schemas.sh"):
            with self.subTest(script=script), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                repo = root / "repo"
                self.make_repo(repo)
                outside = root / "outside-target"
                (repo / "target").rename(outside)
                (repo / "target").symlink_to(outside, target_is_directory=True)
                result = self.run_script(repo, script)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("contains a symlink", result.stderr)

    def test_schema_update_rejects_a_symlinked_docs_parent_without_writes(self) -> None:
        if not hasattr(os, "symlink"):
            self.skipTest("symlink creation is unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            self.make_repo(repo)
            outside = root / "outside-docs"
            (repo / "docs").rename(outside)
            (repo / "docs").symlink_to(outside, target_is_directory=True)
            before = {
                path.relative_to(outside).as_posix(): path.read_bytes()
                for path in outside.rglob("*") if path.is_file()
            }

            result = self.run_script(repo, "update_schemas.sh")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contains a symlink", result.stderr)
            after = {
                path.relative_to(outside).as_posix(): path.read_bytes()
                for path in outside.rglob("*") if path.is_file()
            }
            self.assertEqual(after, before)
            self.assertEqual(list(outside.glob(".schema.*")), [])

    def test_golden_update_requires_commit_and_tree_for_source_edges_override(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "repo"
            self.make_repo(repo)
            override = Path(temporary) / "override"
            self.make_repo(override)
            environment = os.environ.copy()
            environment["CJDOC_SOURCE_EDGES_PROJECT"] = str(
                override / "tests/fixtures/projects/basic"
            )
            result = self.run_script(repo, "update_goldens.sh", environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires expected commit and subtree tree ids", result.stderr)
            self.assertFalse((repo / "tests/fixtures/golden-v8").exists())

    def test_golden_update_accepts_clean_commit_bound_override(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "repo"
            self.make_repo(repo)
            override = Path(temporary) / "override"
            self.make_repo(override)
            user_fixture = repo / "tests/fixtures/projects/source_edges/src/fixture.cj"
            user_fixture.parent.mkdir(parents=True)
            user_fixture.write_text("package user_dirty\n", encoding="utf-8")
            project = override / "tests/fixtures/projects/basic"
            commit = self.git(override, "rev-parse", "HEAD")
            tree = self.git(
                override, "rev-parse", "HEAD:tests/fixtures/projects/basic"
            )
            environment = os.environ.copy()
            environment.update({
                "CJDOC_SOURCE_EDGES_PROJECT": str(project),
                "CJDOC_SOURCE_EDGES_COMMIT": commit,
                "CJDOC_SOURCE_EDGES_TREE": tree,
            })
            result = self.run_script(repo, "update_goldens.sh", environment)
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            receipt = json.loads(
                (repo / "target/golden-update/fixture-snapshot.json").read_text()
            )
            self.assertEqual(receipt["sourceEdgesOverride"]["commit"], commit)
            self.assertEqual(receipt["sourceEdgesOverride"]["tree"], tree)
            self.assertEqual(
                receipt["sourceEdgesOverride"]["workingTreeSha256Before"],
                receipt["verifiedAfter"]["sourceEdgesWorkingTreeSha256"],
            )
            self.assertEqual(user_fixture.read_text(encoding="utf-8"), "package user_dirty\n")

    def test_override_accepts_noncanonical_committed_crlf_despite_eol_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            self.make_repo(repo)
            override = root / "override"
            self.make_repo(override)
            project = override / "tests/fixtures/projects/basic"
            fixture = project / "src/fixture.cj"
            committed_bytes = b"package basic\r\n\r\npublic func rawCrlf(): Unit {}\r\n"
            fixture.write_bytes(committed_bytes)
            self.git(override, "add", "tests/fixtures/projects/basic/src/fixture.cj")
            self.git(override, "commit", "-q", "-m", "commit raw CRLF blob")
            (override / ".gitattributes").write_text("*.cj text eol=crlf\n", encoding="utf-8")
            self.git(override, "add", ".gitattributes")
            self.git(override, "commit", "-q", "-m", "declare CRLF checkout")

            committed = subprocess.run(
                ["git", "-C", str(override), "show",
                 "HEAD:tests/fixtures/projects/basic/src/fixture.cj"],
                capture_output=True, check=True,
            ).stdout
            self.assertEqual(fixture.read_bytes(), committed)
            self.assertEqual(committed, committed_bytes)
            eol_status = self.git(
                override, "status", "--porcelain=v1", "--",
                "tests/fixtures/projects/basic",
            )
            if eol_status:
                self.assertIn(
                    "M tests/fixtures/projects/basic/src/fixture.cj", eol_status
                )
            commit = self.git(override, "rev-parse", "HEAD")
            tree = self.git(
                override, "rev-parse", "HEAD:tests/fixtures/projects/basic"
            )
            identity = fixture_snapshot.override_identity(project, commit, tree)
            self.assertEqual(identity["commit"], commit)
            self.assertEqual(identity["tree"], tree)

    def test_override_exact_tree_check_rejects_all_worktree_inventory_drift(self) -> None:
        mutations = ("modified", "mode", "missing", "untracked", "symlink", "special")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                override = Path(temporary) / "override"
                self.make_repo(override)
                project = override / "tests/fixtures/projects/basic"
                fixture = project / "src/fixture.cj"
                commit = self.git(override, "rev-parse", "HEAD")
                tree = self.git(
                    override, "rev-parse", "HEAD:tests/fixtures/projects/basic"
                )
                if mutation == "modified":
                    fixture.write_text("package modified\n", encoding="utf-8")
                elif mutation == "mode":
                    if os.name == "nt":
                        continue
                    fixture.chmod(fixture.stat().st_mode | 0o111)
                elif mutation == "missing":
                    fixture.unlink()
                elif mutation == "untracked":
                    (project / "src/extra.cj").write_text(
                        "package basic\n", encoding="utf-8"
                    )
                elif mutation == "symlink":
                    fixture.unlink()
                    fixture.symlink_to("../cjpm.toml")
                else:
                    if not hasattr(os, "mkfifo"):
                        self.skipTest("special-file fixture requires mkfifo")
                    fixture.unlink()
                    os.mkfifo(fixture)
                with self.assertRaises(ValueError):
                    fixture_snapshot.override_identity(project, commit, tree)

    def test_override_rejects_a_symlinked_project_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            override = root / "override"
            self.make_repo(override)
            project = override / "tests/fixtures/projects/basic"
            commit = self.git(override, "rev-parse", "HEAD")
            tree = self.git(
                override, "rev-parse", "HEAD:tests/fixtures/projects/basic"
            )
            linked = root / "linked-project"
            linked.symlink_to(project, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "canonical regular directory"):
                fixture_snapshot.override_identity(linked, commit, tree)


if __name__ == "__main__":
    unittest.main()
