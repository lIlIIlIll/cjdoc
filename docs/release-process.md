# Release process

This document separates development evidence from release evidence. A lower gate passing never implies that a higher gate ran.

## Gate levels

| Level | Entry point | Evidence | What it does not prove |
|---|---|---|---|
| Build | `cjpm build` | local compiler exit status | tests, generated output, other SDKs or runners |
| Unit and contract | `cjpm test` | the current Cangjie unit and public-contract suite | golden/schema sync, CLI transactions or hosted CI |
| Local acceptance | `scripts/check.sh` | repository-input preflight, build, tests, v8 goldens, v6/v7 read-only migration, deterministic render, fixture contracts and security/resource/output/provider checks | real-repository scale, performance budgets, another OS/SDK or a release |
| Real repository | `python scripts/real_repository_smoke.py --project .` | two complete JSON+HTML trees, per-file SHA-256 equality, whole-site validation, binary identity and clean Git project identities in a JSON receipt | performance or hosted runners |
| Performance hard ceiling | `python scripts/perf_gate.py check` | fixed-CPU cold/warm mirrored samples, output SHA-256, binary identity, clean Git project identities, wall time and best-effort peak RSS across two profiles | a regression comparison, or behavior on another CPU, SDK or operating system |
| Release | `CJDOC_RELEASE_TAG=vX.Y.Z scripts/release_check.sh` | all preceding local evidence plus exact tag/HEAD/commit/tree/dirty, dependency/vendor, schema and baseline receipts in one transactionally promoted `target/release-evidence/` | GitHub-hosted matrix success until that workflow actually runs |

`scripts/release_check.sh` does not create a tag, push, open a pull request or publish a release.

## Performance baseline

[`tests/perf/baseline.json`](../tests/perf/baseline.json) contains two profiles:

- `basic`: a small synthetic fixture that catches fixed startup and validation regressions;
- `self`: the cjdoc repository itself, which catches realistic declaration-count and renderer costs.

Each profile is prewarmed, then measured in mirrored `cold, warm, warm, cold` order on one selected CPU. Every sample uses a fresh output directory, and all `docs.json` files must have the same SHA-256. `measure_command.py` records monotonic wall time and best-effort child peak RSS.

The baseline has `purpose: hard-ceiling`. The gate rejects output-identity drift and values above absolute wall-time/RSS ceilings; it intentionally records `regressionEvidence: false`. It is not an A/B regression claim because it does not compare old and new binaries with alternating order on the same host. `referenceEnvironmentComparable` only reports exact environment-metadata equality and does not upgrade the evidence class. A record run writes `verdict: candidate`; a check writes `verdict: passed` only after all ceilings pass, and a failed check removes its destination rather than retaining a stale receipt.

A prerelease or partially validated implementation must remain `state: candidate`. To propose a new baseline, build the intended binary and write a candidate outside the source tree:

```bash
python scripts/perf_gate.py record \
  --profile basic=tests/fixtures/projects/basic \
  --profile self=. \
  --output /tmp/cjdoc-perf-baseline.json
```

Review the raw evidence, limits, SDK identity and source changes. Only after local acceptance, real-repository smoke and an independent diff review pass may the reviewed values replace the checked-in file and change to `state: frozen`. `verify_release.py` and the release gate reject any other state.
`perf_gate.py check --allow-candidate` is available only for calibration; `release_check.sh` never uses that override and accepts only a frozen baseline plus a newly produced `verdict: passed` receipt.

The checked-in measurements describe their recorded environment. They are not claims about GitHub runners or other machines. A hosted-runner ceiling should be refreshed from repeated evidence on that runner when the project is ready to tighten the current conservative budgets. A performance-regression claim requires separate fixed-CPU alternating/reversed A/B evidence for both commits and must not be inferred from this ceiling gate.

Real-repository and performance evidence rejects dirty or unversioned inputs by default. `--allow-dirty` is only a diagnostic/calibration escape hatch: the receipt then sets `trustedCommit: false`, omits `sourceCommit`, and records the project working-tree digest. Such a receipt cannot satisfy `release_check.sh`, which requires the clean release commit.

`scripts/update_goldens.sh` archives the committed fixture tree into an immutable snapshot, generates only from that snapshot, and verifies its digest and Git identity again before publishing the complete v8 set. It refuses dirty/mixed fixture inputs and preserves frozen v6/v7 goldens. A clean alternate `source_edges` checkout is supported only with all three variables below; the expected commit and subtree tree must match its Git worktree before and after generation:

```bash
CJDOC_SOURCE_EDGES_PROJECT=/clean/checkout/tests/fixtures/projects/source_edges \
CJDOC_SOURCE_EDGES_COMMIT=<40-hex-commit> \
CJDOC_SOURCE_EDGES_TREE=<40-hex-subtree> \
bash scripts/update_goldens.sh
```

`scripts/update_schemas.sh` likewise stages the complete published set, strictly parses all nine schemas (duplicate keys and non-finite numbers are rejected), verifies their draft, `$id`, version and repository-specific root contract, byte-compares embedded v6/v7 schemas with their frozen files, and updates only the v8/current and shared schemas. These Python shape checks are not represented as a complete official Draft 2020-12 meta-schema implementation. The built yjson-backed decoder separately performs real schema validation while strict-round-tripping every v8 golden and migrating every frozen v6/v7 input. Neither tool should be used to hand-normalize a failing expected artifact. The repository-input gate also byte-freezes all 18 legacy inputs and their per-fixture v8 semantic migration receipts, so a decoder that maps distinct inputs to one generic v8 document cannot pass.

## CI and SDK matrix

[`ci.yml`](../.github/workflows/ci.yml) runs the checksum-pinned Cangjie 1.1.3 SDK on:

- Linux x64 (`ubuntu-22.04`);
- Windows x64 (`windows-2025`);
- macOS ARM64 (`macos-15`).

Linux also runs the real-repository smoke. These jobs are pull-request/push evidence only after GitHub reports them for the exact commit.

Platform acceptance does not imply identical local-asset capabilities. POSIX builds embed a local asset only after opening every path component with `openat` + `O_NOFOLLOW` and validating the opened regular file. The current Windows SDK lacks a public API with equivalent safe no-follow/openat semantics, so Windows intentionally does not embed local assets: it omits the asset, emits `CJDOC4026`, and marks the document `partial`. A successful Windows acceptance/package job verifies that fail-closed contract; it must not be reported as Windows asset-embedding support.

The workflow triggers for both `main` and `dev`. Before SDK setup it verifies that the complete v8 golden set, both complete frozen v6/v7 migration sets, published schemas, notices, licenses and vendor provenance files are tracked. Restored SDK caches retain the checksum-pinned archive as well as the extracted tree. Every hit rechecks the archive's raw-size bound and SHA-256, re-runs bounded archive preflight, re-extracts into a temporary directory, and compares that authenticated extraction with the marker and cached tree. A missing archive, a forged self-consistent marker/tree, or a directory-shaped hit without authenticated metadata fails closed. Checkout credentials are not persisted in the worktree.

[`daily.yml`](../.github/workflows/daily.yml) runs a Linux x64 daily SDK on a schedule and by manual dispatch. Scheduled runs fail closed unless these repository variables contain a matching archive URL and lowercase SHA-256:

- `CANGJIE_DAILY_LINUX_X64_URL`
- `CANGJIE_DAILY_LINUX_X64_SHA256`

Manual runs may supply the same two values as workflow inputs. Updating the URL without its checksum, or leaving either value empty, is not a valid daily result.

## Tag release workflow

[`release.yml`](../.github/workflows/release.yml) is the only automated publisher. A `v*` tag starts, in order:

1. the full Linux release gate on stable Cangjie 1.1.3;
2. stable Windows x64 and macOS ARM64 acceptance;
3. configured daily Linux acceptance and real-repository smoke;
4. deterministic packages for Linux x64, Windows x64 and macOS ARM64 in `contents: read` jobs, each with a SHA-256 sidecar and uploaded only as a digest-checked Actions artifact;
5. one `contents: write` publisher downloads those artifacts, re-verifies the exact tag checkout, exact asset set, every SHA-256 sidecar, every internal package manifest and every repository-derived payload byte;
6. only after verification, that publisher creates or confirms a draft, confirms it is still draft immediately before upload and again immediately before changing it to a public release.

The tag must equal `v` plus the stable `package.version`, resolve to checked-out `HEAD`, and (in hosted CI) match `github.sha`; immediately before draft creation, asset upload and publication the publisher recursively peels the live GitHub tag ref through any annotated-tag chain and requires the final commit to remain `github.sha`. Before and after build/package gates, every HEAD/index/worktree entry is compared by Git mode and blob identity; `assume-unchanged`, `skip-worktree`, index drift, missing/modified tracked files, and ignored or untracked input paths are rejected. Only narrowly enumerated generated outputs below `target/`, build caches, Python bytecode caches and probe outputs are excluded. Git dependencies must use audited 40-hex `commitId` values, the lock and third-party notices/licenses must match, and the vendored yjson manifest must bind its license, upstream notice, adapted `cjpm.toml`, and an exact inventory with no extra native/script/build inputs. The current schema alias must be v8, byte-frozen v6/v7 schemas and all 18 migration inputs plus semantic receipts must remain tracked, and the performance baseline must be frozen with `purpose: hard-ceiling`. Any failed gate leaves the release unpublished; packaging failures occur before a draft is created.

`release_check.sh` first verifies that every path component of the repository's canonical `target/` is a real directory, never a symlink or special file. It then deletes stale final evidence, writes all receipts beneath a same-filesystem staging directory, rechecks Git identity/cleanliness after every gate, verifies that runtime receipts name the same source commit and binary hash, and promotes the complete directory with one rename. Update and acceptance tooling uses the same output-root initializer. Failure removes staging evidence rather than leaving a partial or stale receipt.

`package_release.py` first requires the active `CANGJIE_SDK_ROOT` to match its authenticated archive-SHA extraction, then uses fixed archive timestamps, owners, ordering and permissions beneath canonical `target/release-package`. The SDK installer enforces the compressed-size limit while streaming and preflights member count, individual/aggregate expanded size, path and entry type before extraction; ZIP EOCD/ZIP64 entry count and central-directory size are bounded before `ZipFile` materializes entries. TAR/GZIP input is scanned block-by-block before `tarfile`: checksum, header count, PAX/GNU extension count/bytes, declared member size, aggregate payload and total decompressed bytes are bounded. Repository payloads are read from Git blobs at `sourceCommit`, not mutable worktree bytes; source identity is checked before and after payload collection, and the publisher compares the archive bytes with the same tagged commit. Each archive contains the platform binary, README, project license, third-party notices/license texts, all published schemas and a `cjdoc.release-package/2` manifest binding platform, source commit, declared SDK version/archive SHA-256, payload sizes and payload hashes. Windows packages must be ZIP by both name and magic; Linux/macOS packages must be GZIP-compressed TAR. Verification rejects disguised formats, extension headers in release TARs, non-regular members, special permission bits, non-executable executables, executable data files, excessive raw/member/aggregate sizes and unsafe paths before extraction. Member sizes and SHA-256 values are checked in bounded streaming reads; only the separately capped release manifest is retained in memory. It streams verified regular files into a private temporary directory, rechecks their hashes during extraction, sources the exact declared SDK root, verifies that `CANGJIE_HOME`, `cjc` and `cjpm` all resolve inside it, then runs the extracted binary's `--version` and `schema list` in that environment. The smoke must expose `doc-ir-v8` before artifact upload.

## Release checklist

Before creating a tag:

1. Confirm `scripts/check.sh`, the real-repository smoke and `scripts/perf_gate.py check` passed on the intended source.
2. From a clean checkout at the exact tag, run `CJDOC_RELEASE_TAG=vX.Y.Z CJDOC_RELEASE_COMMIT=$(git rev-parse HEAD) scripts/release_check.sh` and retain the transactionally promoted `target/release-evidence/`.
3. Confirm the exact commit has successful required stable-platform CI and a successful configured daily run.
4. Review public Cangjie compatibility and Doc IR/schema changes separately.
5. Confirm the version and release notes describe breaking changes, migrations and known limitations.
6. Create and push the exact signed or otherwise project-approved tag through the normal repository process.
7. Watch `release.yml`; a pushed tag or draft is not a published release. Verify the public release and downloaded checksums only after the publish job succeeds.

Repository tag protection/rulesets and any protected release environment are GitHub settings outside this repository diff. Configure and verify them separately; the workflow permissions do not create those controls.

At the time this document was written, the current workspace had not been pushed, so GitHub-hosted stable, daily and tag-release evidence for these changes was **NOT RUN**.
