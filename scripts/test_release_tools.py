from __future__ import annotations

import json
import os
from pathlib import Path
import py_compile
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

from scripts import package_release
from scripts import perf_gate
from scripts import real_repository_smoke
from scripts import safe_output_root
from scripts import source_identity
from scripts import strict_json
from scripts import verify_release
from scripts import verify_release_package
from scripts import verify_remote_tag
from scripts import verify_repository_inputs
from scripts import worktree_identity
from scripts.verify_repository_inputs import GOLDEN_NAMES, SCHEMA_NAMES


PROJECT_ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_COMMIT = "db4f9527944b589db8436669f1d255192388cee2"
YJSON_COMMIT = "bf65cbecd99ac25e7485f8db60990e94a04e57bc"
SDK_SHA256 = "1" * 64


class ReleaseToolsTest(unittest.TestCase):
    def git(self, repo: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
             "-c", "core.autocrlf=false",
             "-C", str(repo), *args], text=True, capture_output=True, check=True
        )
        return result.stdout.strip()

    def make_release_repo(self, root: Path, *, initialize_git: bool = True) -> tuple[Path, str | None]:
        (root / "docs/schema").mkdir(parents=True)
        (root / "tests/perf").mkdir(parents=True)
        (root / "tests/fixtures").mkdir(parents=True)
        (root / "third_party/licenses").mkdir(parents=True)
        (root / "vendor/yjson_algorithms/src").mkdir(parents=True)
        (root / "README.md").write_text("# fixture\n", encoding="utf-8")
        (root / "LICENSE").write_text("fixture project license\n", encoding="utf-8")
        for relative in (
            "THIRD_PARTY_NOTICES.md",
            "third_party/licenses/markdown-LICENSE",
            "vendor/yjson_algorithms/LICENSE",
            "vendor/yjson_algorithms/UPSTREAM.md",
            "vendor/yjson_algorithms/cjpm.toml",
            "vendor/yjson_algorithms/vendor-manifest.toml",
        ):
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT_ROOT / relative, destination)
        for source in (PROJECT_ROOT / "vendor/yjson_algorithms/src").glob("*.cj"):
            shutil.copyfile(source, root / "vendor/yjson_algorithms/src" / source.name)
        shutil.copyfile(
            PROJECT_ROOT / "tests/fixtures/legacy-migration-v8.json",
            root / "tests/fixtures/legacy-migration-v8.json",
        )

        (root / "cjpm.toml").write_text(
            "[package]\nname=\"cjdoc\"\nversion=\"0.7.0\"\n"
            "[dependencies]\n"
            f"markdown={{git=\"https://github.com/lIlIIlIll/markdown.git\",commitId=\"{MARKDOWN_COMMIT}\",output-type=\"static\"}}\n"
            f"yjson={{git=\"https://github.com/lIlIIlIll/yjson.git\",commitId=\"{YJSON_COMMIT}\",output-type=\"static\"}}\n"
            "yjson_algorithms={path=\"vendor/yjson_algorithms\",output-type=\"static\"}\n",
            encoding="utf-8",
        )
        (root / "cjpm.lock").write_text(
            "version=0\n[requires]\n"
            f"markdown={{git=\"https://github.com/lIlIIlIll/markdown.git\",commitId=\"{MARKDOWN_COMMIT}\",output-type=\"static\"}}\n"
            f"yjson={{git=\"https://github.com/lIlIIlIll/yjson.git\",commitId=\"{YJSON_COMMIT}\",output-type=\"static\"}}\n",
            encoding="utf-8",
        )
        for name in SCHEMA_NAMES:
            shutil.copyfile(
                PROJECT_ROOT / "docs/schema" / f"{name}.schema.json",
                root / "docs/schema" / f"{name}.schema.json",
            )
        for version in (6, 7, 8):
            directory = root / f"tests/fixtures/golden-v{version}"
            directory.mkdir(parents=True)
            for name in GOLDEN_NAMES:
                shutil.copyfile(
                    PROJECT_ROOT / f"tests/fixtures/golden-v{version}/{name}.docs.json",
                    directory / f"{name}.docs.json",
                )
        (root / "tests/perf/baseline.json").write_text(json.dumps({
            "schemaVersion": "cjdoc.perf-baseline/1",
            "state": "frozen",
            "purpose": "hard-ceiling",
        }), encoding="utf-8")

        if not initialize_git:
            return root, None
        self.git(root, "init", "-q")
        self.git(root, "config", "user.name", "Fixture")
        self.git(root, "config", "user.email", "fixture@example.invalid")
        self.git(root, "config", "commit.gpgSign", "false")
        self.git(root, "config", "tag.gpgSign", "false")
        self.git(root, "add", "-f", ".")
        self.git(root, "commit", "-q", "-m", "fixture")
        self.git(root, "tag", "v0.7.0")
        return root, self.git(root, "rev-parse", "HEAD")

    @staticmethod
    def make_fake_sdk(root: Path) -> Path:
        tools = root / "tools/bin"
        tools.mkdir(parents=True)
        for name in ("cjc", "cjpm"):
            tool = tools / name
            tool.write_text("#!/usr/bin/env sh\nexit 0\n", encoding="utf-8")
            tool.chmod(0o755)
        envsetup = root / "envsetup.sh"
        envsetup.write_text(
            "#!/usr/bin/env bash\n"
            "_cjdoc_sdk_root=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n"
            "export CANGJIE_HOME=\"${_cjdoc_sdk_root}\"\n"
            "export PATH=\"${_cjdoc_sdk_root}/tools/bin:${PATH}\"\n",
            encoding="utf-8",
        )
        return root

    def test_release_metadata_binds_tag_commit_tree_and_clean_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, commit = self.make_release_repo(Path(temporary))
            evidence = verify_release.verify_repository(repo, "v0.7.0", commit)
            self.assertEqual(evidence["version"], "0.7.0")
            self.assertEqual(evidence["commit"], commit)
            self.assertEqual(evidence["tagCommit"], commit)
            self.assertFalse(evidence["dirty"])
            self.assertEqual(evidence["docIrSchemaVersion"], "cjdoc.doc-ir/8")
            self.assertEqual(evidence["performanceGateKind"], "hard-ceiling")
            self.assertIn(
                "vendor/yjson_algorithms/src/work_limits.cj", evidence["inputSha256"]
            )

            (repo / "README.md").write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                verify_release.verify_repository(repo, "v0.7.0", commit)

    def test_release_metadata_rejects_wrong_tag_and_gitless_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, commit = self.make_release_repo(Path(temporary) / "tagged")
            with self.assertRaisesRegex(ValueError, "does not match"):
                verify_release.verify_repository(repo, "v0.7.1", commit)
            self.git(repo, "tag", "-d", "v0.7.0")
            with self.assertRaisesRegex(ValueError, "rev-parse"):
                verify_release.verify_repository(repo, "v0.7.0", commit)

            gitless, _ = self.make_release_repo(Path(temporary) / "gitless", initialize_git=False)
            with self.assertRaisesRegex(ValueError, "Git top-level"):
                verify_release.verify_repository(gitless, "v0.7.0")

    def test_repository_inputs_require_every_generated_file_to_be_tracked(self) -> None:
        for version in (6, 7, 8):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                repo, _ = self.make_release_repo(Path(temporary))
                missing = f"tests/fixtures/golden-v{version}/basic.docs.json"
                self.git(repo, "rm", "-q", "--cached", "--", missing)
                with self.assertRaisesRegex(ValueError, "not tracked"):
                    verify_repository_inputs.verify_repository_inputs(
                        repo, require_tracked=True
                    )

    def test_repository_inputs_reject_missing_extra_and_modified_vendor_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            missing = repo / "tests/fixtures/golden-v8/basic.docs.json"
            missing.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                verify_repository_inputs.verify_repository_inputs(repo)
            missing.write_text('{"schemaVersion":"cjdoc.doc-ir/8"}\n', encoding="utf-8")

            extra = repo / "tests/fixtures/golden-v7/not-a-fixture.docs.json"
            extra.write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unexpected"):
                verify_repository_inputs.verify_repository_inputs(repo)
            extra.unlink()

            vendor = repo / "vendor/yjson_algorithms/src/work_limits.cj"
            vendor.write_text(vendor.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_repository_inputs_reject_legacy_schema_drift_and_vendor_extras(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema = repo / "docs/schema/doc-ir-v7.schema.json"
            schema.write_bytes(schema.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "byte-frozen"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            (repo / "vendor/yjson_algorithms/native.o").write_bytes(b"native")
            with self.assertRaisesRegex(ValueError, "inventory mismatch"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            manifest = repo / "vendor/yjson_algorithms/cjpm.toml"
            manifest.write_text(
                manifest.read_text(encoding="utf-8") + "\n[script-dependencies]\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "audited manifest"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_repository_inputs_validate_every_schema_identity_and_root_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema_path = repo / "docs/schema/search-index.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["$id"] = "https://example.invalid/forged.schema.json"
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "draft/id contract"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema_path = repo / "docs/schema/diagnostics.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["required"] = ["schemaVersion"]
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "required/property contract"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema_path = repo / "docs/schema/doc-ir-v8.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["$defs"] = {}
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "critical definitions"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_repository_schema_gate_rejects_duplicate_and_non_finite_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            path = repo / "docs/schema/search-index.schema.json"
            text = path.read_text(encoding="utf-8")
            path.write_text(
                text.replace("{", '{"$schema":"duplicate",', 1),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            path = repo / "docs/schema/search-index.schema.json"
            text = path.read_text(encoding="utf-8")
            path.write_text(text.replace('"minLength": 1', '"minLength": NaN', 1),
                            encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "non-finite JSON number"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_repository_inputs_freeze_legacy_sources_and_receipt_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            legacy = repo / "tests/fixtures/golden-v6/basic.docs.json"
            legacy.write_bytes(legacy.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "legacy input is not byte-frozen"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            receipt = repo / "tests/fixtures/legacy-migration-v8.json"
            receipt.write_bytes(receipt.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "receipt manifest is not byte-frozen"):
                verify_repository_inputs.verify_repository_inputs(repo)

    @unittest.skipIf(os.name == "nt", "fixture executable uses a POSIX shebang")
    def test_same_output_for_every_legacy_golden_does_not_satisfy_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, _ = self.make_release_repo(root / "repo")
            binary = root / "fake-cjdoc"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import json,sys\n"
                "p=sys.argv[sys.argv.index('--input')+1]\n"
                "v=json.load(open(p,encoding='utf-8'))\n"
                "if v.get('corrupt'): raise SystemExit(2)\n"
                "print(json.dumps({'schemaVersion':'cjdoc.doc-ir/8'}))\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            with self.assertRaisesRegex(ValueError, "semantic receipt"):
                verify_repository_inputs.verify_legacy_migrations(repo, binary)

    def test_release_archive_is_reproducible_manifested_and_smokeable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, commit = self.make_release_repo(root / "repo")
            binary = root / "main"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "if sys.argv[1:] == ['--version']:\n"
                "    print('cjdoc 0.7.0')\n"
                "elif sys.argv[1:] == ['schema', 'list']:\n"
                "    print('doc-ir\\ndoc-ir-v7\\ndoc-ir-v8')\n"
                "else:\n"
                "    raise SystemExit(2)\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            output = repo / "target/release-package"
            options = {
                "source_commit": commit,
                "sdk_version": "1.1.3",
                "sdk_sha256": SDK_SHA256,
            }
            asset = package_release.build_archive(
                repo, binary, "linux-x64", output, **options
            )
            first = asset.read_bytes()
            second = package_release.build_archive(
                repo, binary, "linux-x64", output, **options
            ).read_bytes()
            self.assertEqual(first, second)
            self.assertTrue((output / "cjdoc-0.7.0-linux-x64.tar.gz.sha256").is_file())
            sdk_root = self.make_fake_sdk(root / "sdk")
            evidence = verify_release_package.verify_archive(
                asset, "linux-x64", "0.7.0", "1.1.3", SDK_SHA256, commit,
                smoke=os.name != "nt", repository=repo, sdk_root=sdk_root,
                sdk_marker_verified=True,
            )
            files = evidence["manifest"]["files"]
            self.assertIn("THIRD_PARTY_NOTICES.md", files)
            self.assertIn("licenses/markdown-MIT.txt", files)
            self.assertIn("licenses/yjson-Apache-2.0.txt", files)
            if os.name != "nt":
                self.assertEqual(evidence["smoke"]["version"], "cjdoc 0.7.0")
                self.assertEqual(
                    evidence["sdkEnvironment"],
                    {"cjc": "tools/bin/cjc", "cjpm": "tools/bin/cjpm"},
                )
            _, members, _ = verify_release_package.inspect_archive(
                asset, "linux-x64", "0.7.0", "1.1.3", SDK_SHA256, commit
            )
            self.assertIsNone(members["README.md"].content)
            self.assertIsNotNone(members["release-manifest.json"].content)
            tampered = dict(members)
            original_member = tampered["README.md"]
            tampered_readme = b"not the tagged README\n"
            tampered["README.md"] = verify_release_package.ArchiveMember(
                "README.md", len(tampered_readme),
                verify_release_package.sha256_bytes(tampered_readme),
                original_member.mode,
            )
            with self.assertRaisesRegex(ValueError, "does not match source commit"):
                verify_release_package.verify_repository_payload(tampered, repo, commit)

            with self.assertRaisesRegex(ValueError, "does not match"):
                package_release.build_archive(
                    repo, binary, "linux-x64", output,
                    source_commit="f" * 40,
                    sdk_version="1.1.3",
                    sdk_sha256=SDK_SHA256,
                )

            readme = repo / "README.md"
            original_readme = readme.read_bytes()
            readme.write_text("dirty README\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                package_release.build_archive(repo, binary, "linux-x64", output, **options)
            readme.write_bytes(original_readme)
            schema = repo / "docs/schema/doc-ir-v8.schema.json"
            original_schema = schema.read_bytes()
            schema.write_bytes(original_schema + b"\n")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                package_release.build_archive(repo, binary, "linux-x64", output, **options)

    def test_release_archive_rejects_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "bad.zip"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("../escape", "bad")
            with self.assertRaisesRegex(ValueError, "unsafe archive member"):
                verify_release_package.read_archive(archive)

    def test_release_archive_rejects_a_symlinked_archive_path(self) -> None:
        if not hasattr(os, "symlink"):
            self.skipTest("symlink creation is unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "payload.zip"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("root/member", "payload")
            alias = root / "alias.zip"
            try:
                alias.symlink_to(archive)
            except OSError as error:
                self.skipTest(f"symlink creation is unavailable: {error}")
            with self.assertRaisesRegex(ValueError, "not a regular file"):
                verify_release_package.read_archive(alias)

    def test_release_archive_binds_platform_magic_and_exact_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, commit = self.make_release_repo(root / "repo")
            binary = root / "main"
            binary.write_bytes(b"binary")
            payload = package_release.collect_payload(
                repo, binary, False, "0.7.0", "linux-x64", commit,
                "1.1.3", SDK_SHA256,
            )
            output = repo / "target/release-package"
            output.mkdir(parents=True)
            asset = output / "cjdoc-0.7.0-linux-x64.tar.gz"

            with zipfile.ZipFile(asset, "w") as package:
                package.writestr("cjdoc-0.7.0/cjdoc", b"binary")
            with self.assertRaisesRegex(ValueError, "format mismatch"):
                verify_release_package.inspect_archive(
                    asset, "linux-x64", "0.7.0", "1.1.3", SDK_SHA256, commit
                )

            for name, mode in (("cjdoc", 0o644), ("README.md", 0o4755)):
                with self.subTest(name=name, mode=oct(mode)):
                    modified = dict(payload)
                    content, _ = modified[name]
                    modified[name] = (content, mode)
                    package_release.write_tar_gz(asset, "cjdoc-0.7.0", modified)
                    with self.assertRaisesRegex(ValueError, "member mode mismatch"):
                        verify_release_package.inspect_archive(
                            asset, "linux-x64", "0.7.0", "1.1.3", SDK_SHA256,
                            commit,
                        )

            windows_payload = package_release.collect_payload(
                repo, binary, True, "0.7.0", "windows-x64", commit,
                "1.1.3", SDK_SHA256,
            )
            windows_asset = output / "cjdoc-0.7.0-windows-x64.zip"
            package_release.write_zip(windows_asset, "cjdoc-0.7.0", windows_payload)
            verify_release_package.inspect_archive(
                windows_asset, "windows-x64", "0.7.0", "1.1.3", SDK_SHA256,
                commit,
            )
            content, _ = windows_payload["cjdoc.exe"]
            windows_payload["cjdoc.exe"] = (content, 0o644)
            package_release.write_zip(windows_asset, "cjdoc-0.7.0", windows_payload)
            with self.assertRaisesRegex(ValueError, "member mode mismatch"):
                verify_release_package.inspect_archive(
                    windows_asset, "windows-x64", "0.7.0", "1.1.3",
                    SDK_SHA256, commit,
                )

    def test_release_tar_rejects_pax_extensions_before_tarfile(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "cjdoc-0.7.0-linux-x64.tar.gz"
            with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as package:
                member = tarfile.TarInfo("cjdoc-0.7.0/" + ("x" * 120))
                member.size = 0
                package.addfile(member)
            with self.assertRaisesRegex(ValueError, "extension headers"):
                verify_release_package.read_archive(
                    archive, expected_format="gzip-tar"
                )

    @unittest.skipIf(os.name == "nt", "fixture environment uses a POSIX shell")
    def test_package_smoke_rejects_tools_resolved_outside_declared_sdk(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "sdk"
            root.mkdir()
            (root / "envsetup.sh").write_text(
                "#!/usr/bin/env bash\n"
                "export CANGJIE_HOME=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "outside the SDK root|cannot resolve"):
                verify_release_package.declared_sdk_environment(root)

    @unittest.skipIf(os.name == "nt", "fixture environment uses a POSIX shell")
    def test_package_smoke_sources_sdk_setup_without_nounset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_fake_sdk(Path(temporary) / "sdk")
            setup = root / "envsetup.sh"
            original = setup.read_text(encoding="utf-8")
            setup.write_text(
                'export DYLD_FALLBACK_LIBRARY_PATH="${DYLD_FALLBACK_LIBRARY_PATH}:sdk"\n'
                + original,
                encoding="utf-8",
            )
            environment, tools = verify_release_package.declared_sdk_environment(root)
            self.assertEqual(environment["CANGJIE_HOME"], str(root.resolve()))
            self.assertEqual(tools, {"cjc": "tools/bin/cjc", "cjpm": "tools/bin/cjpm"})

    def test_windows_sdk_setup_uses_environment_path_not_command_arguments(self) -> None:
        setup = Path("sdk root") / "envsetup.ps1"
        command, environment = (
            verify_release_package.powershell_sdk_environment_invocation(setup)
        )
        script = command[command.index("-Command") + 1]
        self.assertIn(". $env:CJDOC_SDK_SETUP", script)
        self.assertNotIn("$args", script)
        self.assertEqual(environment["CJDOC_SDK_SETUP"], str(setup))

    def test_packaging_rechecks_cleanliness_after_payload_collection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, commit = self.make_release_repo(root / "repo")
            binary = root / "main"
            binary.write_bytes(b"binary")
            original_collect = package_release.collect_payload

            def collect_then_dirty(*args, **kwargs):
                payload = original_collect(*args, **kwargs)
                (repo / "README.md").write_text("changed during packaging\n", encoding="utf-8")
                return payload

            with mock.patch.object(
                package_release, "collect_payload", side_effect=collect_then_dirty
            ):
                with self.assertRaisesRegex(ValueError, "bytes differ"):
                    package_release.build_archive(
                    repo, binary, "linux-x64", repo / "target/release-package",
                        source_commit=commit, sdk_version="1.1.3", sdk_sha256=SDK_SHA256,
                    )
            self.assertFalse(
                (repo / "target/release-package/cjdoc-0.7.0-linux-x64.tar.gz").exists()
            )

    def test_packaging_rechecks_source_after_archive_write_before_publish(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, commit = self.make_release_repo(root / "repo")
            binary = root / "main"
            binary.write_bytes(b"binary")
            output = repo / "target/release-package"
            output.mkdir(parents=True)
            asset = output / "cjdoc-0.7.0-linux-x64.tar.gz"
            checksum = output / "cjdoc-0.7.0-linux-x64.tar.gz.sha256"
            asset.write_bytes(b"stale package")
            checksum.write_text("stale checksum\n", encoding="ascii")
            original_write = package_release.write_tar_gz

            def write_then_dirty(*args, **kwargs):
                original_write(*args, **kwargs)
                (repo / "README.md").write_text(
                    "changed during archive write\n", encoding="utf-8"
                )

            with mock.patch.object(
                package_release, "write_tar_gz", side_effect=write_then_dirty
            ):
                with self.assertRaisesRegex(ValueError, "bytes differ"):
                    package_release.build_archive(
                        repo, binary, "linux-x64", output,
                        source_commit=commit, sdk_version="1.1.3",
                        sdk_sha256=SDK_SHA256,
                    )
            self.assertFalse((output / "cjdoc-0.7.0-linux-x64.tar.gz").exists())
            self.assertFalse((output / "cjdoc-0.7.0-linux-x64.tar.gz.sha256").exists())

    def test_safe_output_root_rejects_symlink_special_and_outside_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            target = safe_output_root.safe_target_root(repo)
            outside = root / "outside"
            outside.mkdir()
            linked = target / "linked"
            linked.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "contains a symlink"):
                safe_output_root.safe_output_directory(repo, linked)
            linked.unlink()
            special = target / "special"
            special.write_text("not a directory", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "special/non-directory"):
                safe_output_root.safe_output_directory(repo, special)
            with self.assertRaisesRegex(ValueError, "inside the canonical"):
                safe_output_root.safe_output_directory(repo, outside)

            regular = target / "regular-binary"
            regular.write_bytes(b"binary")
            self.assertEqual(safe_output_root.safe_regular_file(regular), regular)
            alias = target / "binary-alias"
            alias.symlink_to(regular)
            with self.assertRaisesRegex(ValueError, "canonical regular non-symlink"):
                safe_output_root.safe_regular_file(alias, description="cjdoc binary")

            evidence = target / "evidence.json"
            evidence.symlink_to(regular)
            with self.assertRaisesRegex(ValueError, "regular non-symlink"):
                safe_output_root.safe_output_file(evidence, description="evidence")

    def test_safe_output_root_normalizes_only_verified_darwin_system_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            canonical = root / "private-var"
            canonical.mkdir()
            alias = root / "var"
            alias.symlink_to(canonical, target_is_directory=True)
            nested = canonical / "nested"
            nested.mkdir()
            outside = root / "outside"
            outside.mkdir()
            (nested / "user-link").symlink_to(outside, target_is_directory=True)
            with mock.patch.object(safe_output_root.sys, "platform", "darwin"), \
                    mock.patch.object(
                        safe_output_root, "_DARWIN_SYSTEM_ALIASES", {alias: canonical}
                    ):
                self.assertEqual(
                    safe_output_root.lexical_absolute(alias / "nested"), nested
                )
                with self.assertRaisesRegex(ValueError, "contains a symlink"):
                    safe_output_root.verify_directory_chain(alias / "nested" / "user-link")

    def test_release_archive_rejects_oversized_file_and_too_many_tar_headers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            oversized = root / "oversized.bin"
            oversized.write_bytes(b"123456789")
            with mock.patch.object(verify_release_package, "MAX_ARCHIVE_SIZE", 8):
                with self.assertRaisesRegex(ValueError, "archive size"):
                    verify_release_package.read_archive(oversized)

            large_member = root / "large-member.zip"
            with zipfile.ZipFile(large_member, "w") as package:
                package.writestr("root/large", b"x")
            with mock.patch.object(verify_release_package, "MAX_MEMBER_SIZE", 0):
                with self.assertRaisesRegex(ValueError, "member is too large"):
                    verify_release_package.read_archive(large_member)

            many_zip = root / "many.zip"
            with zipfile.ZipFile(many_zip, "w") as package:
                for index in range(verify_release_package.MAX_MEMBERS + 1):
                    package.writestr(f"root/member-{index:03d}", b"")
            with self.assertRaisesRegex(ValueError, "too many (members|headers)"):
                verify_release_package.read_archive(many_zip)

            archive = root / "many.tar"
            with tarfile.open(archive, "w") as package:
                for index in range(verify_release_package.MAX_MEMBERS + 1):
                    info = tarfile.TarInfo(f"root/member-{index:03d}")
                    info.size = 0
                    package.addfile(info)
            with self.assertRaisesRegex(ValueError, "too many (members|headers)"):
                verify_release_package.read_archive(archive)

    def test_release_workflow_separates_read_only_builds_from_single_publisher(self) -> None:
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        daily = workflow.split("\n  daily-acceptance:\n", 1)[1].split(
            "\n  package:\n", 1
        )[0]
        package = workflow.split("\n  package:\n", 1)[1].split("\n  publish:\n", 1)[0]
        publish = workflow.split("\n  publish:\n", 1)[1]
        self.assertIn(
            "if: ${{ vars.CANGJIE_DAILY_LINUX_X64_URL != '' && "
            "vars.CANGJIE_DAILY_LINUX_X64_SHA256 != '' }}",
            daily,
        )
        self.assertIn("needs.daily-acceptance.result == 'success'", package)
        self.assertIn("needs.daily-acceptance.result == 'skipped'", package)
        self.assertIn("needs.release-gate.result == 'success'", package)
        self.assertIn("needs.platform-acceptance.result == 'success'", package)
        self.assertIn("contents: read", package)
        self.assertIn("persist-credentials: false", package)
        self.assertIn(
            "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
            package,
        )
        self.assertNotIn("GH_TOKEN", package)
        self.assertNotIn("gh release", package)
        self.assertEqual(package.count("python scripts/verify_release.py"), 2)
        build_offset = package.index("cjpm build")
        self.assertLess(package.index("python scripts/verify_release.py"), build_offset)
        self.assertGreater(package.rindex("python scripts/verify_release.py"), build_offset)
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertIn("persist-credentials: false", publish)
        self.assertIn(
            "actions/download-artifact@70fc10c6e5e1ce46ad2ea6f2b72d43f7d47b13c3",
            publish,
        )
        self.assertNotIn("skip-decompress", publish)
        self.assertNotIn("cjpm build", publish)
        self.assertNotIn("package_release.py", publish)
        self.assertLess(
            publish.index("Verify exact tag and all package artifacts"),
            publish.index("Upload to draft and publish"),
        )
        self.assertGreaterEqual(publish.count("require_draft"), 4)
        self.assertIn(
            "verify_remote_tag\n          require_draft\n          gh release upload", publish
        )
        self.assertIn(
            "verify_remote_tag\n          require_draft\n          gh release edit", publish
        )
        self.assertGreaterEqual(publish.count("verify_remote_tag"), 4)

    def test_remote_release_tag_is_recursively_peeled_to_the_workflow_commit(self) -> None:
        first = "1" * 40
        second = "2" * 40
        commit = "3" * 40
        responses = {
            "repos/owner/repo/git/ref/tags/v0.7.0": {
                "object": {"type": "tag", "sha": first}
            },
            f"repos/owner/repo/git/tags/{first}": {
                "object": {"type": "tag", "sha": second}
            },
            f"repos/owner/repo/git/tags/{second}": {
                "object": {"type": "commit", "sha": commit}
            },
        }
        calls: list[str] = []

        def request(endpoint: str) -> dict[str, object]:
            calls.append(endpoint)
            return responses[endpoint]

        self.assertEqual(
            verify_remote_tag.verify_remote_tag(
                "owner/repo", "v0.7.0", commit, request=request
            ),
            commit,
        )
        self.assertEqual(calls, list(responses))
        with self.assertRaisesRegex(ValueError, "remote release tag moved"):
            verify_remote_tag.verify_remote_tag(
                "owner/repo", "v0.7.0", "4" * 40, request=request
            )

    def test_performance_limits_fail_closed(self) -> None:
        baseline = {"profiles": [{
            "name": "basic",
            "referenceDocsSha256": "a" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
                "warm": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
            },
        }]}
        result = [{
            "name": "basic",
            "docsSha256": "a" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 11, "maxPeakRssKiB": 20},
                "warm": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
            },
        }]
        with self.assertRaisesRegex(ValueError, "elapsed"):
            perf_gate.verify_hard_ceiling(baseline, result)

    def test_performance_limits_reject_stale_doc_ir_baseline(self) -> None:
        baseline = {"profiles": [{
            "name": "basic",
            "referenceDocsSha256": "a" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
                "warm": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
            },
        }]}
        result = [{
            "name": "basic",
            "docsSha256": "b" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
                "warm": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
            },
        }]
        with self.assertRaisesRegex(ValueError, "Doc IR checksum"):
            perf_gate.verify_hard_ceiling(baseline, result)

    def test_recorded_performance_baseline_is_explicitly_a_hard_ceiling(self) -> None:
        results = [{
            "name": "basic", "project": ".", "minDeclarations": 1,
            "docsSha256": "a" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 10, "medianElapsedMs": 9,
                         "maxPeakRssKiB": 20, "medianPeakRssKiB": 19},
                "warm": {"maxElapsedMs": 8, "medianElapsedMs": 7,
                         "maxPeakRssKiB": 18, "medianPeakRssKiB": 17},
            },
        }]
        baseline = perf_gate.baseline_from_results(results, 1, 0)
        self.assertEqual(baseline["purpose"], "hard-ceiling")
        self.assertEqual(baseline["state"], "candidate")

    def test_performance_receipt_is_published_only_after_ceiling_passes(self) -> None:
        baseline = {"profiles": [{
            "name": "basic", "referenceDocsSha256": "a" * 64,
            "variants": {"cold": {"maxElapsedMs": 10, "maxPeakRssKiB": None}},
        }]}
        evidence = {"schemaVersion": "cjdoc.perf-evidence/2", "kind": "hard-ceiling"}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "performance.json"
            failing = [{
                "name": "basic", "docsSha256": "a" * 64,
                "variants": {"cold": {"maxElapsedMs": 11, "maxPeakRssKiB": None}},
            }]
            with self.assertRaisesRegex(ValueError, "hard ceiling failed"):
                perf_gate.publish_check_evidence(path, evidence, baseline, failing)
            self.assertFalse(path.exists())
            passing = [{
                "name": "basic", "docsSha256": "a" * 64,
                "variants": {"cold": {"maxElapsedMs": 10, "maxPeakRssKiB": None}},
            }]
            receipt = perf_gate.publish_check_evidence(path, evidence, baseline, passing)
            self.assertEqual(receipt["verdict"], "passed")
            self.assertEqual(json.loads(path.read_text())["verdict"], "passed")

    def test_tree_digest_detects_byte_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "docs.json"
            path.write_bytes(b"one")
            first = real_repository_smoke.tree_digests(root)
            path.write_bytes(b"two")
            second = real_repository_smoke.tree_digests(root)
            self.assertNotEqual(first, second)

    def test_real_repository_subprocesses_do_not_create_bytecode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "helper.py").write_text("VALUE = 'ok'\n", encoding="utf-8")
            probe = root / "probe.py"
            probe.write_text("import helper\nprint(helper.VALUE)\n", encoding="utf-8")

            result = real_repository_smoke.run([sys.executable, str(probe)], root)

            self.assertEqual(result.stdout.strip(), "ok")
            self.assertFalse((root / "__pycache__").exists())

    def test_evidence_sources_reject_dirty_as_trusted_or_record_untrusted_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "cjpm.toml").write_text("[package]\nname='fixture'\n", encoding="utf-8")
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            self.git(repo, "add", "cjpm.toml")
            self.git(repo, "commit", "-q", "-m", "fixture")
            clean = source_identity.source_identity(repo)
            self.assertTrue(clean["trustedCommit"])
            self.assertFalse(clean["dirty"])

            (repo / "cjpm.toml").write_text("[package]\nname='dirty'\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                source_identity.source_identity(repo)
            self.assertIsNone(real_repository_smoke.source_commit(repo, allow_dirty=True))
            self.assertIsNone(perf_gate.source_commit(repo, allow_dirty=True))
            dirty = source_identity.source_identity(repo, allow_dirty=True)
            self.assertFalse(dirty["trustedCommit"])
            self.assertTrue(dirty["dirty"])
            self.assertRegex(str(dirty["workingTreeSha256"]), r"^[0-9a-f]{64}$")

    def test_evidence_source_identity_rejects_ignored_uncommitted_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / ".gitignore").write_text("/ignored/\n", encoding="utf-8")
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            self.git(repo, "add", ".gitignore")
            self.git(repo, "commit", "-q", "-m", "fixture")
            project = repo / "ignored"
            project.mkdir()
            (project / "cjpm.toml").write_text(
                "[package]\nname='ignored'\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "not represented in HEAD"):
                source_identity.source_identity(project)
            identity = source_identity.source_identity(project, allow_dirty=True)
            self.assertFalse(identity["trustedCommit"])
            self.assertIsNone(identity["pathTree"])
            self.assertEqual(identity["pathRelative"], "ignored")

    def test_strict_json_rejects_duplicate_keys_and_non_finite_numbers(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
            strict_json.strict_loads('{"outer":{"same":1,"same":2}}')
        for token in ("NaN", "Infinity", "-Infinity", "1e9999", "-1e9999"):
            with self.subTest(token=token), self.assertRaisesRegex(
                ValueError, "non-finite JSON number"
            ):
                strict_json.strict_loads(f'{{"value":{token}}}')
        value = strict_json.strict_loads('{"value":1.25}')
        self.assertIsInstance(value["value"], float)
        self.assertEqual(value["value"], 1.25)

    def test_exact_worktree_identity_rejects_hidden_and_untracked_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / ".gitignore").write_text("ignored.cj\n", encoding="utf-8")
            (repo / "input.cj").write_text("package fixture\n", encoding="utf-8")
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            self.git(repo, "add", ".gitignore", "input.cj")
            self.git(repo, "commit", "-q", "-m", "fixture")
            self.assertTrue(worktree_identity.exact_worktree_identity(repo)["trustedCommit"])

            self.git(repo, "update-index", "--assume-unchanged", "input.cj")
            with self.assertRaisesRegex(ValueError, "hidden state"):
                worktree_identity.exact_worktree_identity(repo)
            self.git(repo, "update-index", "--no-assume-unchanged", "input.cj")

            self.git(repo, "update-index", "--skip-worktree", "input.cj")
            with self.assertRaisesRegex(ValueError, "hidden state"):
                worktree_identity.exact_worktree_identity(repo)
            self.git(repo, "update-index", "--no-skip-worktree", "input.cj")

            (repo / "untracked.cj").write_text("package unexpected\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "untracked worktree input"):
                worktree_identity.exact_worktree_identity(repo)
            (repo / "untracked.cj").unlink()
            (repo / "ignored.cj").write_text("package ignored\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "ignored/untracked worktree input"):
                worktree_identity.exact_worktree_identity(repo)
            (repo / "ignored.cj").unlink()
            (repo / "target/generated.bin").parent.mkdir()
            (repo / "target/generated.bin").write_bytes(b"generated")
            worktree_identity.exact_worktree_identity(repo)

    def test_exact_worktree_identity_uses_raw_bytes_not_eol_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            (repo / ".gitattributes").write_text("*.cj -text\n", encoding="utf-8")
            source = repo / "fixture.cj"
            source.write_bytes(b"package fixture\r\n")
            self.git(repo, "add", ".gitattributes", "fixture.cj")
            self.git(repo, "commit", "-q", "-m", "raw CRLF")
            (repo / ".gitattributes").write_text(
                "*.cj text eol=crlf\n", encoding="utf-8"
            )
            self.git(repo, "add", ".gitattributes")
            self.git(repo, "commit", "-q", "-m", "declare CRLF checkout")
            status = self.git(repo, "status", "--porcelain=v1", "--", "fixture.cj")
            # Git's EOL status classification depends on platform checkout
            # configuration and its cached stat data. The release identity must
            # accept the file in either case because its raw bytes still match
            # the committed blob exactly.
            self.assertIn(status, ("", "M fixture.cj"))
            self.assertEqual(
                subprocess.run(
                    ["git", "-C", str(repo), "show", "HEAD:fixture.cj"],
                    capture_output=True, check=True,
                ).stdout,
                source.read_bytes(),
            )
            worktree_identity.exact_worktree_identity(repo)

    def test_exact_worktree_identity_rejects_executable_unchecked_hash_pyc(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            module = repo / "release_helper.py"
            module.write_text("VALUE = 'trusted-head'\n", encoding="utf-8")
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            self.git(repo, "add", "release_helper.py")
            self.git(repo, "commit", "-q", "-m", "fixture")

            py_compile.compile(
                str(module), doraise=True,
                invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH,
            )
            module.write_text("VALUE = 'dirty-source'\n", encoding="utf-8")
            loaded = subprocess.run(
                [sys.executable, "-c", "import release_helper; print(release_helper.VALUE)"],
                cwd=repo, text=True, capture_output=True, check=True,
            )
            self.assertEqual(loaded.stdout.strip(), "trusted-head")
            with self.assertRaisesRegex(ValueError, "ignored/untracked worktree input"):
                worktree_identity.exact_worktree_identity(repo)

    def test_repository_verifier_direct_execution_does_not_create_bytecode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary) / "repo")
            scripts = repo / "scripts"
            scripts.mkdir()
            for name in (
                "safe_output_root.py",
                "strict_json.py",
                "verify_repository_inputs.py",
                "worktree_identity.py",
            ):
                shutil.copyfile(PROJECT_ROOT / "scripts" / name, scripts / name)
            self.git(repo, "add", "scripts")
            self.git(repo, "commit", "-q", "-m", "add verifier")

            result = subprocess.run(
                [sys.executable, "scripts/verify_repository_inputs.py", "--require-tracked"],
                cwd=repo, text=True, capture_output=True, check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            self.assertFalse((scripts / "__pycache__").exists())

    @unittest.skipIf(os.name == "nt", "fake validator uses a POSIX shebang")
    def test_real_binary_path_round_trips_all_v8_goldens_and_rejects_corruption(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, _ = self.make_release_repo(root / "repo")
            binary = root / "fake-cjdoc"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import json,sys\n"
                "p=sys.argv[sys.argv.index('--input')+1]\n"
                "raw=open(p,'rb').read(); value=json.loads(raw)\n"
                "if 'generator' not in value: raise SystemExit(2)\n"
                "sys.stdout.buffer.write(raw)\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            verified = verify_repository_inputs.verify_current_goldens(repo, binary)
            self.assertEqual(len(verified), len(GOLDEN_NAMES))


if __name__ == "__main__":
    unittest.main()
