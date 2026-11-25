set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    git --version
    cjc -v
    cjpm -v
    python3 -c 'import json; print("Python standard library: OK")'

build:
    cjpm build

test:
    cjpm test

schema:
    python3 scripts/check_schemas.py

golden:
    scripts/check.sh

check:
    scripts/check.sh

real-smoke:
    python3 scripts/real_repository_smoke.py --project .

perf:
    python3 scripts/perf_gate.py check

release-check:
    scripts/release_check.sh

smoke:
    target/release/bin/main generate --project tests/fixtures/projects/basic --format json --format markdown --format html --output target/smoke

provider-smoke:
    cd tests/fixtures/projects/provider_plugin && cjpm run
