#!/usr/bin/env python3
"""Exercise explicit CLI scopes and the loopback listener using the built binary."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener


# Public command sets; affirmative cases use real inputs rather than testing
# a parse that can succeed while silently ignoring the option.
SCOPES = {
    "generate check serve": """--project --semantic --cjc --chir-worker --chir-import-path
        --highlight-adapter --highlight-node --audience --lint-profile --jobs --check-examples
        --deny-warnings --cfg --include-path-dependencies --no-include-path-dependencies
        --include-cached-dependencies --no-include-cached-dependencies --dependency-source --cjpm-cache
        --cache-dir --no-cache --cache --api-surface-baseline --min-symbol-coverage
        --min-parameter-coverage --require-language""",
    "generate check": "--build-context --doc-source --doc-inventory-pin --link-language --link-language-fallback --link-compatible",
    "generate render serve": "--output --force-owned --locale --agent-full --no-agent-full --html-font-sans --html-font-mono",
    "generate render": "--stdout --doc-version --all-languages --validation-report --api-diff-report",
    "generate serve": "--repository-url --repository-revision --repository-root",
    "generate": "--stdlib-doc-version --stdlib-doc-base-url",
    "render": "--input",
    "serve": "--port --open",
    "diff": "--baseline --current --deny-breaking-api --deny-potentially-breaking-api",
    "generate render serve diff": "--format",
    "generate check render serve": "--max-doc-ir-mib",
}


def invoke(command, *args):
    return subprocess.run([*command, *args], capture_output=True, text=True, timeout=35,
                          encoding="utf-8", errors="replace")


def expect_usage_error(result, detail):
    assert result.returncode == 2 and detail in result.stderr.split("\n")[0], result


def check_applicability(binary, root, project, common):
    for name in ("generate", "check", "render", "serve", "diff"):
        help_result = invoke([binary, name], "--help")
        assert help_result.returncode == 0, help_result
        listed = set(re.findall(r"^  (--[a-z-]+)\s", help_result.stdout, flags=re.M))
        expected = {flag for names, flags in SCOPES.items() if name in names.split() for flag in flags.split()}
        assert listed == expected, (name, listed - expected, expected - listed)
        for names, flags in SCOPES.items():
            if name not in names.split():
                for flag in flags.split():
                    expect_usage_error(invoke([binary, name], flag), f"{flag} is not valid for {name}")

    query = invoke([binary, "query"], "--port")
    assert query.returncode == 2 and "--port" in query.stdout, query
    for command in ([binary, "mcp"], [binary, "schema"], [binary, "versions", "compose"]):
        expect_usage_error(invoke(command, "--port"), "--port")
    for name in ("generate", "check", "serve"):
        for flag in ("--highlight-adapter", "--highlight-node"):
            expect_usage_error(invoke([binary, name, *common], flag, str(root / "missing")),
                               "--highlight-adapter and --highlight-node must be supplied together")
    for flag in ("--baseline", "--current"):
        expect_usage_error(invoke([binary, "diff"], flag, "missing.json"), "requires both baseline and current")

    generate = [binary, "generate", *common]
    docs = invoke(generate, "--stdout")
    assert docs.returncode == 0, docs
    assert json.loads(docs.stdout)["project"]["name"] == project.name
    path = root / "docs.json"
    path.write_text(docs.stdout, encoding="utf-8")
    rerendered = invoke([binary, "render"], "--input", str(path), "--stdout")
    assert rerendered.returncode == 0 and json.loads(rerendered.stdout) == json.loads(docs.stdout), rerendered
    api = invoke(generate, "--format", "api-surface", "--stdout")
    assert api.returncode == 0, api
    surface = root / "api-surface.json"
    surface.write_text(api.stdout, encoding="utf-8")
    for paths in ([str(surface), str(surface)], ["--baseline", str(surface), "--current", str(surface)]):
        diff = invoke([binary, "diff"], *paths, "--format", "json", "--deny-breaking-api",
                      "--deny-potentially-breaking-api")
        assert diff.returncode == 0 and not json.loads(diff.stdout)["changes"], diff
    checked = invoke([binary, "check", *common], "--api-surface-baseline", str(surface))
    assert checked.returncode == 0, checked


@contextmanager
def start_serve(command, work, env=None):
    with (work / "serve.stderr").open("wb") as log:
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log, env=env)
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def wait_for_listener(process, work):
    log = work / "serve.stderr"
    deadline = time.monotonic() + 35
    client = build_opener(ProxyHandler({}))
    while time.monotonic() < deadline:
        message = log.read_text(encoding="utf-8", errors="replace")
        if process.poll() is not None:
            return None, message
        match = re.search(r"^serve: (http://127\.0\.0\.1:([0-9]+)/)$", message, flags=re.M)
        if match:
            url, port = match.groups()
            assert 1 <= int(port) <= 65535, message
            try:
                with client.open(url + "__cjdoc/status.json", timeout=1) as stream:
                    status = json.load(stream)
                with client.open(url, timeout=1) as stream:
                    html = stream.read().decode("utf-8")
                assert status["port"] == int(port) and status["successfulBuilds"] == 1 and status["status"] == "ok", status
                assert "<!doctype html>" in html.lower(), html[:300]
                return url, message
            except (URLError, TimeoutError):
                pass
        time.sleep(0.08)
    raise AssertionError(log.read_text(encoding="utf-8", errors="replace"))


def check_ports(binary, root, common, highlight, browser_check):
    base = [binary, "serve", *common]
    for value in ("65536", "-1", "999999999999999999999999", "invalid"):
        expect_usage_error(invoke(base, "--port", value), "--port must be an integer in 0..65535")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as held:
        if sys.platform == "win32":
            held.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        held.bind(("127.0.0.1", 0))
        held.listen()
        port = held.getsockname()[1]
        expect_usage_error(invoke(base, "--port", str(port), "--output", str(root / "occupied")),
                           f"cannot listen on 127.0.0.1:{port}")
    for value in (0, 1, 65535):
        work = root / f"port-{value}"
        work.mkdir()
        command = [*base, "--port", str(value), "--output", str(work / "output")]
        env = None
        opened = work / "opened-url"
        if value == 0:
            command.extend(highlight)
            if sys.platform.startswith("linux"):
                opener = work / "xdg-open"
                opener.write_text('#!/bin/sh\nprintf "%s\\n" "$1" > "$CJDOC_OPENED_URL"\n'
                                  'if [ -n "$CJDOC_BROWSER_CHECK" ]; then\n'
                                  '  exec "$CJDOC_BROWSER_PYTHON" "$CJDOC_BROWSER_CHECK" "$1"\nfi\n',
                                  encoding="utf-8")
                opener.chmod(0o755)
                env = dict(os.environ, PATH=str(work) + os.pathsep + os.environ["PATH"],
                           CJDOC_OPENED_URL=str(opened), CJDOC_BROWSER_CHECK=browser_check or "",
                           CJDOC_BROWSER_PYTHON=sys.executable, CJDOC_BROWSER_RECEIPT=str(work / "browser-receipt"))
                command.append("--open")
        with start_serve(command, work, env) as process:
            url, diagnostic = wait_for_listener(process, work)
            if value != 0 and url is None:
                # Privileged or occupied boundary ports are OS-dependent; they
                # must reach bind, not overflow or fail argument validation.
                assert process.returncode == 2 and f"cannot listen on 127.0.0.1:{value}:" in diagnostic, diagnostic
                continue
            assert url is not None, diagnostic
            if value:
                assert url == f"http://127.0.0.1:{value}/", url
            if env:
                receipt = (work / "browser-receipt") if browser_check else opened
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline and not receipt.is_file():
                    time.sleep(0.05)
                assert receipt.read_text(encoding="utf-8").strip() == url, diagnostic
                assert opened.read_text(encoding="utf-8").strip() == url, diagnostic
            if value == 0 and highlight:
                docs = json.loads((work / "output" / "docs.json").read_text(encoding="utf-8"))
                def highlights(value):
                    if isinstance(value, dict):
                        if value.get("engineId") == "highlight.js":
                            yield value
                        for child in value.values():
                            yield from highlights(child)
                    if isinstance(value, list):
                        for child in value:
                            yield from highlights(child)
                assert any(item.get("state") == "complete" and item.get("spans") for item in highlights(docs))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--highlight-node", type=Path)
    parser.add_argument("--highlight-adapter", type=Path)
    parser.add_argument("--browser-check", help="Optional Linux opener verification executable (Python script)")
    args = parser.parse_args()
    if bool(args.highlight_node) != bool(args.highlight_adapter):
        parser.error("--highlight-node and --highlight-adapter must be supplied together")
    root = args.output.resolve()
    root.mkdir(parents=True)
    project = root / "option_contract"
    (project / "src").mkdir(parents=True)
    (project / "cjdoc.toml").write_text('[highlight]\nmode = "static"\nlanguages = ["python"]\n', encoding="utf-8")
    (project / "cjpm.toml").write_text('[package]\nname = "option_contract"\ncjc-version = "1.2.0"\n'
                                     'version = "1.0.0"\noutput-type = "static"\n', encoding="utf-8")
    (project / "src" / "api.cj").write_text('package option_contract\n/**\n * A value.\n *\n'
                                           ' * ```python\n * True\n * ```\n */\n'
                                           'public func value(): Int64 { 1 }\n', encoding="utf-8")
    binary = str(args.binary.resolve())
    common = ["--project", str(project), "--semantic", "source", "--no-cache", "--lint-profile", "off"]
    check_applicability(binary, root, project, common)
    highlight = (["--highlight-node", str(args.highlight_node.resolve()), "--highlight-adapter",
                  str(args.highlight_adapter.resolve())] if args.highlight_node else [])
    check_ports(binary, root, common, highlight, args.browser_check)
    print("verified CLI help and explicit option scopes, paired/valid invocations, and loopback port boundaries")


if __name__ == "__main__":
    main()
