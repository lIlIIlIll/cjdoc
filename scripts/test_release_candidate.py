"""Release candidate receipt, package v4 binding and publish-side rejection tests."""

from __future__ import annotations

import json
from pathlib import Path, PurePosixPath
import platform
import subprocess
import sys
import tarfile
import tempfile
import unittest

from scripts import package_release
from scripts import release_candidate_receipt
from scripts import verify_release_package
from scripts.release_tools_test_support import PROJECT_ROOT, SDK_SHA256, ReleaseToolsTestSupport

STDX_SHA256 = "2" * 64
PLATFORM = "linux-x64"


class ReleaseCandidateTests(ReleaseToolsTestSupport, unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo, self.commit = self.make_release_repo(self.root / "repo")
        # The receipt hashes the -O1 wrapper, which the release repo fixture does
        # not otherwise need.
        wrapper = self.repo / "scripts/with_sts_o1_cjpm.sh"
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        wrapper.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        self.git(self.repo, "add", "-A")
        self.git(self.repo, "-c", "user.name=t", "-c", "user.email=t@example.test",
                 "commit", "-q", "-m", "add wrapper")
        self.commit = self.git(self.repo, "rev-parse", "HEAD")
        self.binary = self.repo / "target/release/bin/main"
        self.binary.parent.mkdir(parents=True, exist_ok=True)
        self.binary.write_text("#!/bin/sh\necho 'cjdoc 0.7.0'\n", encoding="utf-8")
        self.binary.chmod(0o755)

    def receipt(self, **overrides) -> dict:
        document = {
            "schemaVersion": "cjdoc.release-candidate/1",
            "source": {"tag": "v0.7.0", "releaseVersion": "0.7.0", "commit": self.commit,
                       "tree": self.git(self.repo, "rev-parse", "HEAD^{tree}"),
                       "dirty": False, "worktreeSha256": "a" * 64},
            "platform": {"id": PLATFORM, "os": "Linux", "architecture": "x86_64",
                         "compilerTarget": "x86_64-unknown-linux-gnu"},
            "toolchain": {"sdkVersion": "1.2.0", "sdkArchiveSha256": SDK_SHA256,
                          "stdxVersion": "1.2.0", "stdxArchiveSha256": STDX_SHA256,
                          "compilerVersion": "Cangjie Compiler: 1.2.0", "cjpmVersion": "1.2.0",
                          "stdxDigest": "b" * 64, "toolchainFingerprint": "c" * 64},
            "build": {"command": ["cjpm", "build", "--jobs", "1"],
                      "effectiveCompileOptions": ["-O1"],
                      "buildConfigurationSha256": "d" * 64},
            "binary": {"path": "target/release/bin/main",
                       "sha256": verify_release_package.sha256_file(self.binary),
                       "size": self.binary.stat().st_size,
                       "versionOutput": "cjdoc 0.7.0"},
            "execution": {"runId": "1", "runAttempt": 1, "job": "release-candidate (linux-x64)"},
            "gates": {"release-gate": "e" * 64},
        }
        document.update(overrides)
        return document

    def build(self, receipt: dict | None, *, stdx_sha256: str | None = STDX_SHA256) -> Path:
        return package_release.build_archive(
            self.repo, self.binary, PLATFORM, self.repo / "target/release-package",
            source_commit=self.commit, sdk_version="1.2.0", sdk_sha256=SDK_SHA256,
            release_version="0.7.0", stdx_version="1.2.0" if stdx_sha256 else None,
            stdx_sha256=stdx_sha256, candidate_receipt=receipt,
        )

    def manifest(self, asset: Path) -> dict:
        manifest, _, _ = verify_release_package.inspect_archive(
            asset, PLATFORM, "0.7.0", "1.2.0", SDK_SHA256, self.commit,
            "1.2.0", STDX_SHA256)
        return manifest

    def test_v4_package_binds_the_accepted_receipt_and_binary(self):
        receipt = self.receipt()
        asset = self.build(receipt)
        manifest = self.manifest(asset)
        self.assertEqual(manifest["schemaVersion"], "cjdoc.release-package/4")
        self.assertEqual(manifest["releaseTag"], "v0.7.0")
        self.assertEqual(manifest["sourceTree"], self.git(self.repo, "rev-parse", "HEAD^{tree}"))
        self.assertIn("release-candidate.json", manifest["files"])
        with tarfile.open(asset, "r:gz") as archive:
            member = archive.extractfile("cjdoc-0.7.0/release-candidate.json")
            assert member is not None
            embedded = json.loads(member.read())
        self.assertEqual(embedded, receipt)
        self.assertEqual(verify_release_package.sha256_file(asset),
                         verify_release_package.sha256_file(asset))

    def test_package_rejects_a_receipt_for_another_commit_platform_or_binary(self):
        cases = (
            (self.receipt(source={**self.receipt()["source"], "commit": "f" * 40}),
             "different source commit"),
            (self.receipt(platform={"id": "windows-x64", "os": "Windows",
                                    "architecture": "x86_64", "compilerTarget": "x86_64-pc-windows"}),
             "different platform"),
            (self.receipt(binary={"path": "target/release/bin/main", "sha256": "0" * 64,
                                  "size": 1, "versionOutput": "cjdoc 0.7.0"}),
             "does not describe the packaged binary"),
            (self.receipt(toolchain={**self.receipt()["toolchain"],
                                     "sdkArchiveSha256": "9" * 64}),
             "different SDK archive"),
            (self.receipt(toolchain={**self.receipt()["toolchain"],
                                     "stdxArchiveSha256": "8" * 64}),
             "different stdx archive"),
        )
        for receipt, pattern in cases:
            with self.subTest(pattern=pattern), self.assertRaisesRegex(ValueError, pattern):
                self.build(receipt)

    def test_package_rejects_a_dirty_or_foreign_receipt_schema(self):
        with self.assertRaisesRegex(ValueError, "dirty worktree"):
            self.build(self.receipt(source={**self.receipt()["source"], "dirty": True}))
        with self.assertRaisesRegex(ValueError, "unexpected release candidate receipt schema"):
            self.build({"schemaVersion": "cjdoc.release-candidate/9"})

    def test_package_rejects_a_replaced_binary_after_acceptance(self):
        receipt = self.receipt()
        asset = self.build(receipt)
        self.assertTrue(asset.exists())
        self.binary.write_text("#!/bin/sh\necho 'cjdoc 0.7.0'\n# replaced\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "does not describe the packaged binary"):
            self.build(receipt)

    def test_v4_manifest_requires_its_new_fields_and_matching_member(self):
        receipt = self.receipt()
        asset = self.build(receipt)
        # Rebuild the archive through the production writer so the only change is
        # the tampered manifest field; an ad-hoc tar would introduce PAX headers.
        with tarfile.open(asset, "r:gz") as archive:
            payload = {
                PurePosixPath(member.name).relative_to("cjdoc-0.7.0").as_posix():
                    (archive.extractfile(member).read(), member.mode)
                for member in archive.getmembers()
            }
        original = payload["release-manifest.json"][0].decode("utf-8")
        for mutate, pattern in (
            (lambda document: document.pop("releaseTag"), "unknown release package manifest schema"),
            (lambda document: document.__setitem__("sourceTree", "not-a-tree"),
             "requires its source tree"),
            (lambda document: document.__setitem__("candidateReceiptSha256", "0" * 64),
             "receipt digest does not match"),
        ):
            document = json.loads(original)
            mutate(document)
            payload["release-manifest.json"] = (
                (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(),
                0o644,
            )
            rebuilt = self.repo / f"target/tampered-{abs(hash(pattern))}.tar.gz"
            rebuilt.parent.mkdir(parents=True, exist_ok=True)
            package_release.write_tar_gz(rebuilt, "cjdoc-0.7.0", payload)
            rebuilt_asset = rebuilt.with_name(f"cjdoc-0.7.0-{PLATFORM}.tar.gz")
            rebuilt.replace(rebuilt_asset)
            with self.subTest(pattern=pattern), self.assertRaisesRegex(ValueError, pattern):
                verify_release_package.inspect_archive(
                    rebuilt_asset, PLATFORM, "0.7.0", "1.2.0", SDK_SHA256, self.commit,
                    "1.2.0", STDX_SHA256)

    def test_receipt_script_writes_a_stable_receipt_from_the_worktree(self):
        output = self.repo / "target/release-candidate/cjdoc-release-candidate.json"
        # The receipt must name the host platform, whatever platform runs the suite.
        host_platform = {"Linux": "linux-x64", "Darwin": "macos-arm64",
                         "Windows": "windows-x64"}.get(platform.system(), PLATFORM)
        command = [
            sys.executable, str(PROJECT_ROOT / "scripts/release_candidate_receipt.py"),
            "--repo", str(self.repo), "--tag", "v0.7.0", "--platform", host_platform,
            "--binary", str(self.binary),
            "--sdk-archive-sha256", SDK_SHA256, "--stdx-archive-sha256", STDX_SHA256,
            "--sdk-version", "1.2.0", "--stdx-version", "1.2.0",
            "--output", str(output),
        ]
        completed = subprocess.run(command, text=True, capture_output=True)
        if completed.returncode != 0:
            # cjc/cjpm are unavailable outside the release toolchain image.
            self.assertIn("command failed", completed.stderr)
            return
        document = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(document["schemaVersion"], release_candidate_receipt.RECEIPT_SCHEMA)
        self.assertEqual(document["source"]["commit"], self.commit)
        self.assertEqual(document["binary"]["versionOutput"], "cjdoc 0.7.0")
        self.assertEqual(document["platform"]["id"], host_platform)


class ReleaseAssetLayoutTest(unittest.TestCase):
    """The candidate artifact root must be flat: `publish` reads a flat directory.

    `upload-artifact` preserves the structure below the least common ancestor of
    the given paths, so two sibling directories silently nest the payload and the
    publisher then finds no assets. These assertions pin both sides together.
    """

    def workflow(self) -> str:
        return (PROJECT_ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    def candidate_job(self) -> str:
        return self.workflow().split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]

    def block(self, job: str, step_name: str) -> str:
        """Return the text of one step, up to the next step at the same indent."""
        marker = f"      - name: {step_name}"
        self.assertIn(marker, job)
        body = job.split(marker, 1)[1]
        return body.split("\n      - name:", 1)[0]

    def test_candidate_upload_uses_one_flat_directory(self) -> None:
        # No PyYAML dependency: the CI runner does not install it.
        upload = self.block(self.candidate_job(), "Upload the verified candidate")
        self.assertIn("path: target/release-assets", upload)
        self.assertIn("if-no-files-found: error", upload)
        # Two sibling upload paths would silently make `target/` the ancestor and
        # nest the payload below `release-package/` and `release-candidate/`
        # (upload-artifact uses the least common ancestor of multiple paths).
        self.assertNotIn("release-package/*", upload)
        self.assertNotIn("release-candidate/", upload)

    def test_staging_copies_package_and_receipt_into_the_flat_root(self) -> None:
        candidate = self.candidate_job()
        staging = self.block(candidate, "Stage the release assets in one flat directory")
        self.assertIn("target/release-assets", staging)
        self.assertIn("cp -p target/release-package/* target/release-assets/", staging)
        self.assertIn("cjdoc-release-candidate-${{ matrix.platform }}.json", staging)
        # Staging must run after packaging so the files it copies exist.
        self.assertLess(
            candidate.index("name: Build the deterministic package"),
            candidate.index("name: Stage the release assets"))

    def test_the_publisher_only_reads_flat_asset_files(self) -> None:
        publish = self.workflow().split("\n  publish:\n", 1)[1]
        # A recursive search would hide a nested layout instead of failing loudly.
        self.assertIn("root.iterdir()", publish)
        self.assertIn('root.glob("*.sha256")', publish)
        self.assertNotIn("rglob", publish)


class ReleaseGateCleanlinessTest(unittest.TestCase):
    """The candidate receipt hashes the worktree, so the gates must leave it clean."""

    def test_the_full_gate_cleans_every_tree_it_builds(self) -> None:
        check = (PROJECT_ROOT / "scripts/check.sh").read_text(encoding="utf-8")
        # The CHIR worker compiles fixture projects, which creates `target/`
        # directories under the fixtures; a leftover one makes the receipt's
        # `exact_worktree_identity` fail with "unexpected ignored/untracked".
        gate = check.split('stage="${stage_id}"', 1)[1]
        self.assertIn("cleanup_full_gate()", gate)
        # `all` covers the worker tree as well as every fixture tree.
        self.assertIn("existing_build_outputs all", gate)
        # Cleanup must be trapped, not only run after success.
        # Compare on the single-quoted trap body without embedding its quotes.
        self.assertIn("cleanup_full_gate; exit", gate)
        self.assertIn("trap ", gate)


class PublishAssetSetTest(unittest.TestCase):
    """The publisher's flat asset set must include the three candidate receipts."""

    def publish(self) -> str:
        return (PROJECT_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8").split("\n  publish:\n", 1)[1]

    def test_expected_asset_set_accepts_every_candidate_receipt(self) -> None:
        publish = self.publish()
        verifier = publish.split("Verify exact tag, every receipt and all package artifacts", 1)[1]
        # The receipts are downloaded with the packages, so the first verifier's
        # `expected` set must contain them or it rejects them as "unexpected".
        for platform in ("linux-x64", "windows-x64", "macos-arm64"):
            with self.subTest(platform=platform):
                self.assertIn(f"cjdoc-release-candidate-{{platform}}.json", verifier)
        self.assertIn('for platform in ("linux-x64", "windows-x64", "macos-arm64"):', verifier)

    def test_receipts_are_verified_but_never_uploaded(self) -> None:
        publish = self.publish()
        # Verified: each platform receipt is cross-checked against the run.
        self.assertIn("receipt is from run", publish)
        # Not published: both the upload and the asset comparison exclude them.
        self.assertEqual(publish.count("! -name 'cjdoc-release-candidate*.json'"), 2)


class ReleaseArtifactScopeTest(unittest.TestCase):
    """A rerun keeps earlier attempts' artifacts; downloads must not mix them."""

    def release_workflow(self) -> str:
        return (PROJECT_ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    def test_candidate_artifacts_are_scoped_to_run_and_attempt(self) -> None:
        workflow = self.release_workflow()
        candidate = workflow.split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
        upload = candidate.split("name: Upload the verified candidate", 1)[1]
        self.assertIn(
            "cjdoc-release-${{ matrix.platform }}-${{ github.run_id }}-${{ github.run_attempt }}",
            upload)

    def test_publish_downloads_only_the_current_attempt(self) -> None:
        publish = self.release_workflow().split("\n  publish:\n", 1)[1]
        self.assertIn("pattern: cjdoc-release-*-${{ github.run_id }}-${{ github.run_attempt }}",
                      publish)
        self.assertNotIn("pattern: cjdoc-release-*\n", publish)


class GateAndTimingGuardTest(unittest.TestCase):
    """Dropped suites and conditional-cleanup regressions must stay visible."""

    def check(self) -> str:
        return (PROJECT_ROOT / "scripts/check.sh").read_text(encoding="utf-8")

    def test_the_gate_runs_the_showcase_contract_suite(self) -> None:
        gate = self.check()
        # The Pages refactor dropped this suite from pages.yml; the staged gate
        # must keep running it or those tests run nowhere.
        self.assertIn("discover -s tests/showcase_contract", gate)
        python_tools = gate.split("stage_python_tools()", 1)[1].split("\nstage_", 1)[0]
        self.assertIn("discover -s tests/showcase_contract", python_tools)

    def test_the_full_gate_protects_pre_existing_build_trees(self) -> None:
        gate = self.check()
        full_gate = gate.split('stage="${stage_id}"', 1)[1]
        self.assertIn("preexisting_outputs=", full_gate)
        # The guard must consult that snapshot before removing anything.
        self.assertIn("preexisting_outputs", full_gate)
        self.assertIn("grep -Fxq", full_gate)

    def test_every_stage_resolves_the_windows_worker_name(self) -> None:
        gate = self.check()
        self.assertIn("resolve_worker_binary()", gate)
        # The unsuffixed spelling must not be exported on its own anywhere.
        self.assertNotIn('CJDOC_CHIR_WORKER="${worker_binary:-${worker_project}/target/release/bin/main}"',
                         gate)

    def test_malformed_timing_evidence_never_aborts_a_build(self) -> None:
        timing = (PROJECT_ROOT / "scripts/showcase_build/stage_timing.py").read_text(encoding="utf-8")
        self.assertIn("except (OSError, ValueError):", timing)


class HardeningRegressionTest(unittest.TestCase):
    """Guards for the review findings that could silently weaken evidence."""

    def test_merge_requires_a_fresh_non_symlink_output(self) -> None:
        sharding = (PROJECT_ROOT / "scripts/showcase_contract/browser_sharding.py").read_text(
            encoding="utf-8")
        merge = sharding.split("def merge(", 1)[1]
        self.assertIn("symlink in merged browser evidence destination", merge)
        self.assertIn("must be a new directory", merge)
        self.assertIn("must be separate trees", merge)
        # `exist_ok=True` would adopt a stale directory instead of refusing it.
        self.assertNotIn("mkdir(parents=True, exist_ok=True)", merge)

    def test_diagnostics_reject_symlinked_candidates(self) -> None:
        diagnostics = (PROJECT_ROOT / "scripts/ci_diagnostics.py").read_text(encoding="utf-8")
        self.assertIn("def _acceptable_source(", diagnostics)
        self.assertIn("source.is_symlink()", diagnostics)
        # A resolved source must stay under a scanned root.
        self.assertIn("resolved.is_relative_to(root.resolve())", diagnostics)

    def test_stage_logs_are_bounded(self) -> None:
        stage = (PROJECT_ROOT / "scripts/ci_stage.py").read_text(encoding="utf-8")
        self.assertIn("class _BoundedLog", stage)
        self.assertIn("LOG_HEAD_BYTES", stage)
        self.assertIn("LOG_TAIL_BYTES", stage)
        # The console still receives everything; only the file is capped.
        self.assertIn("bytes omitted by the log bound", stage)

    def test_pages_selects_the_successful_attempt(self) -> None:
        pages = (PROJECT_ROOT / ".github/workflows/pages.yml").read_text(encoding="utf-8")
        resolver = pages.split("Decide the candidate source", 1)[1].split("- name:", 1)[0]
        # A rerun's success carries its own attempt number.
        self.assertIn("attempt", resolver)
        self.assertIn("databaseId,attempt", resolver)

    def test_the_standalone_build_cleans_up_after_failure(self) -> None:
        check = (PROJECT_ROOT / "scripts/check.sh").read_text(encoding="utf-8")
        build = check.split("stage_build()", 1)[1].split("\nstage_", 1)[0]
        self.assertIn("cleanup_build_worker", build)
        self.assertIn("trap cleanup_build_worker EXIT", build)


class RoutingAndSelectionTest(unittest.TestCase):
    """Guards for plan transport, LPT ordering and the bounded candidate wait."""

    def test_ci_passes_the_plan_through_the_environment(self) -> None:
        ci = (PROJECT_ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        required = ci.split("Enforce the planned job outcomes", 1)[1]
        # Shell interpolation would break on JSON containing quotes.
        self.assertNotIn("--plan '${{", required)
        self.assertIn("CJDOC_PLAN: ${{ needs.changes.outputs.plan }}", required)
        self.assertIn('--plan "${CJDOC_PLAN}"', required)

    def test_history_weighted_assignment_places_heaviest_first(self) -> None:
        sharding = (PROJECT_ROOT / "scripts/showcase_contract/browser_sharding.py").read_text(
            encoding="utf-8")
        weighted = sharding.split("history-weighted", 1)[0]
        # Longest-processing-time requires descending cost order.
        self.assertIn("by_cost", weighted)
        self.assertIn("sorted(ordered, key=lambda home: -sum(", weighted)

    def test_the_candidate_wait_fits_inside_its_job_timeout(self) -> None:
        pages = (PROJECT_ROOT / ".github/workflows/pages.yml").read_text(encoding="utf-8")
        resolve = pages.split("resolve-candidate:", 1)[1].split("\n  local-candidate:", 1)[0]
        timeout = int(resolve.split("timeout-minutes:", 1)[1].split("\n", 1)[0].strip())
        wait = int(pages.split("deadline=$(( $(date +%s) + ", 1)[1].split(" ))", 1)[0])
        self.assertGreater(timeout * 60, wait,
                           f"job timeout {timeout}m must exceed the {wait}s wait")


class PagesCandidatePolicyTest(unittest.TestCase):
    """The resolver's policy is security relevant, so pin each branch."""

    def resolver(self) -> str:
        pages = (PROJECT_ROOT / ".github/workflows/pages.yml").read_text(encoding="utf-8")
        return pages.split("Decide the candidate source", 1)[1].split("\n      - name:", 1)[0]

    def test_an_empty_dispatch_input_builds_locally(self) -> None:
        self.assertIn('workflow_dispatch without candidate_run_id builds locally', self.resolver())

    def test_explicit_runs_must_be_successful_ci_runs(self) -> None:
        resolver = self.resolver()
        # An explicit run id bypasses `--status success`, so it is validated here.
        self.assertIn("is not a CI workflow run", resolver)
        self.assertIn("not a successful CI attempt", resolver)
        self.assertIn('"${run_sha}" != "${GITHUB_SHA}"', resolver)

    def test_validation_reads_the_selected_attempt_not_the_latest(self) -> None:
        resolver = self.resolver()
        # The run-level API reports the newest attempt, so a run that only passed
        # on attempt 2 would validate attempt 1 and reuse its artifact.
        self.assertIn('gh run view "${run_id}" --attempt "${attempt}"', resolver)
        self.assertNotIn('actions/runs/${run_id}"', resolver)

    def test_the_automatic_path_waits_and_records_the_attempt(self) -> None:
        resolver = self.resolver()
        self.assertIn("deadline=$(( $(date +%s) + ", resolver)
        self.assertIn("databaseId,attempt", resolver)


class StagedGateAndReceiptTest(unittest.TestCase):
    """Every stage of the gate, and every branch, must actually be exercised."""

    def test_linux_gate_runs_preflight_before_python_tools(self) -> None:
        ci = (PROJECT_ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        linux = ci.split("Run the remaining acceptance stages", 1)[1].split("\n      - name:", 1)[0]
        # `python-tools` excludes the SDK-installer and stdx tests because
        # preflight owns them, so preflight must run in this job too.
        self.assertIn("check.sh preflight", linux)
        self.assertLess(linux.index("check.sh preflight"), linux.index("check.sh python-tools"))

    def test_branch_receipt_is_created_after_the_browser_merge(self) -> None:
        pages = (PROJECT_ROOT / ".github/workflows/pages.yml").read_text(encoding="utf-8")
        verify = pages.split("verify-site:", 1)[1]
        self.assertIn("showcase_branch_receipts.py", verify)
        receipt_step = verify.index("Bind every branch including the merged browser evidence")
        merge_step = verify.index("Merge shards and run the unmodified full evidence gate")
        self.assertLess(merge_step, receipt_step,
                        "the receipt cannot cover the browser branch before the merge runs")
        # And the browser branch must actually be named in it.
        self.assertIn("--branch \"browser=target/showcase-evidence/results.json\"",
                      verify[receipt_step:])


if __name__ == "__main__":
    unittest.main()
