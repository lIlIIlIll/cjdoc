# Release process

This document separates development evidence from release evidence. A lower gate passing never implies that a higher gate ran.

## Gate levels

| Level | Entry point | Evidence | What it does not prove |
|---|---|---|---|
| Build | `cjpm build` | local compiler exit status | tests, generated output, other SDKs or runners |
| Unit and contract | `cjpm test` | 30 Cangjie tests | golden/schema sync, CLI transactions or hosted CI |
| Local acceptance | `scripts/check.sh` | build, tests, v7 goldens, v6 migration, deterministic render, security/resource/output/provider checks | real-repository scale, performance budgets, another OS/SDK or a release |
| Real repository | `python scripts/real_repository_smoke.py --project .` | two complete JSON+HTML trees, per-file SHA-256 equality, whole-site validation and a JSON receipt | performance or hosted runners |
| Performance | `python scripts/perf_gate.py check` | fixed-CPU cold/warm ABBA samples, output SHA-256, wall time and best-effort peak RSS across two profiles | another CPU, SDK or operating system |
| Release | `CJDOC_RELEASE_TAG=vX.Y.Z scripts/release_check.sh` | all preceding local evidence plus exact tag, version, dependency, schema and baseline receipts in `target/release-evidence/` | GitHub-hosted matrix success until that workflow actually runs |

`scripts/release_check.sh` does not create a tag, push, open a pull request or publish a release.

## Performance baseline

[`tests/perf/baseline.json`](../tests/perf/baseline.json) contains two profiles:

- `basic`: a small synthetic fixture that catches fixed startup and validation regressions;
- `self`: the cjdoc repository itself, which catches realistic declaration-count and renderer costs.

Each profile is prewarmed, then measured in `cold, warm, warm, cold` order on one selected CPU. Every sample uses a fresh output directory, and all `docs.json` files must have the same SHA-256. `measure_command.py` records monotonic wall time and best-effort child peak RSS.

A prerelease or partially validated implementation must remain `state: candidate`. To propose a new baseline, build the intended binary and write a candidate outside the source tree:

```bash
python scripts/perf_gate.py record \
  --profile basic=tests/fixtures/projects/basic \
  --profile self=. \
  --output /tmp/cjdoc-perf-baseline.json
```

Review the raw evidence, limits, SDK identity and source changes. Only after local acceptance, real-repository smoke and an independent diff review pass may the reviewed values replace the checked-in file and change to `state: frozen`. `verify_release.py` and the release gate reject any other state.

The checked-in measurements describe their recorded environment. They are not claims about GitHub runners or other machines. A hosted-runner baseline should be refreshed from repeated evidence on that runner when the project is ready to tighten the current conservative budgets.

## CI and SDK matrix

[`ci.yml`](../.github/workflows/ci.yml) runs the checksum-pinned Cangjie 1.1.3 SDK on:

- Linux x64 (`ubuntu-22.04`);
- Windows x64 (`windows-2025`);
- macOS ARM64 (`macos-15`).

Linux also runs the real-repository smoke. These jobs are pull-request/push evidence only after GitHub reports them for the exact commit.

[`daily.yml`](../.github/workflows/daily.yml) runs a Linux x64 daily SDK on a schedule and by manual dispatch. Scheduled runs fail closed unless these repository variables contain a matching archive URL and lowercase SHA-256:

- `CANGJIE_DAILY_LINUX_X64_URL`
- `CANGJIE_DAILY_LINUX_X64_SHA256`

Manual runs may supply the same two values as workflow inputs. Updating the URL without its checksum, or leaving either value empty, is not a valid daily result.

## Tag release workflow

[`release.yml`](../.github/workflows/release.yml) is the only automated publisher. A `v*` tag starts, in order:

1. the full Linux release gate on stable Cangjie 1.1.3;
2. stable Windows x64 and macOS ARM64 acceptance;
3. configured daily Linux acceptance and real-repository smoke;
4. creation or verification of a GitHub draft release;
5. deterministic packages for Linux x64, Windows x64 and macOS ARM64, each with a SHA-256 sidecar;
6. download verification of the exact asset set and every SHA-256 sidecar, followed by changing the draft to a public release.

The tag must equal `v` plus the stable `package.version`. Git dependencies must use a 40-hex `commitId`, the lock must match, the current schema alias must be v7, and the performance baseline must be frozen. Any failed gate leaves the release unpublished. A failed packaging job may leave a draft, which must stay draft until a clean rerun verifies all six assets.

`package_release.py` uses fixed archive timestamps, owners, ordering and permissions. Each archive contains the platform binary, README, license, all published schemas and an internal manifest of payload sizes and SHA-256 values.

## Release checklist

Before creating a tag:

1. Confirm `scripts/check.sh`, the real-repository smoke and `scripts/perf_gate.py check` passed on the intended source.
2. Run `CJDOC_RELEASE_TAG=vX.Y.Z scripts/release_check.sh` and retain `target/release-evidence/`.
3. Confirm the exact commit has successful required stable-platform CI and a successful configured daily run.
4. Review public Cangjie compatibility and Doc IR/schema changes separately.
5. Confirm the version and release notes describe breaking changes, migrations and known limitations.
6. Create and push the exact signed or otherwise project-approved tag through the normal repository process.
7. Watch `release.yml`; a pushed tag or draft is not a published release. Verify the public release and downloaded checksums only after the publish job succeeds.

At the time this document was written, the current workspace had not been pushed, so GitHub-hosted stable, daily and tag-release evidence for these changes was **NOT RUN**.
