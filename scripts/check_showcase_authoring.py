#!/usr/bin/env python3
"""Exercise the documented PocketKit serve/watch command with the native CLI.

The report describes a process-level authoring check, not per-example results.
Only an isolated copy is edited; the downloadable source remains unchanged.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def wait_status(opener, base: str, process: subprocess.Popen, minimum: int,
                timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"serve exited early: {process.returncode}")
        try:
            with opener.open(base + "/__cjdoc/status.json", timeout=2) as response:
                status = json.load(response)
            if status.get("schemaVersion") != "cjdoc.serve-status/1":
                raise RuntimeError("unexpected native serve-status schema")
            if status["builds"] >= minimum:
                if status["status"] != "ok" or status["successfulBuilds"] < minimum:
                    raise RuntimeError("native serve build failed: " + str(status))
                return status
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    raise TimeoutError(f"serve did not finish build {minimum} within {timeout}s")


def stop(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    if os.name == "posix":
        os.killpg(process.pid, signal.SIGTERM)
    else:
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait(timeout=10)


def check_served_artifact_limit(opener, base: str, site: Path) -> None:
    artifact = site / "serve-size-boundary.html"
    url = base + "/" + artifact.name
    mib = 1024 * 1024
    try:
        for size in (32 * mib + 1, 64 * mib):
            with artifact.open("wb") as stream:
                stream.truncate(size)
            request = urllib.request.Request(url, method="HEAD")
            with opener.open(request, timeout=30) as response:
                if response.status != 200 or int(response.headers["Content-Length"]) != size:
                    raise AssertionError("serve rejected an artifact within the renderer's size limit")
                if response.read():
                    raise AssertionError("HEAD returned an artifact body")
            if size == 32 * mib + 1:
                with opener.open(url, timeout=30) as response:
                    received = 0
                    while chunk := response.read(mib):
                        if chunk != bytes(len(chunk)):
                            raise AssertionError("served artifact bytes changed")
                        received += len(chunk)
                    if received != size:
                        raise AssertionError("serve truncated a large artifact")
        with artifact.open("ab") as stream:
            stream.write(b"x")
        try:
            with opener.open(urllib.request.Request(url, method="HEAD"), timeout=30):
                pass
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
        else:
            raise AssertionError("serve accepted an artifact over 64 MiB")
    finally:
        artifact.unlink(missing_ok=True)


def check(binary: Path, source: Path, output: Path, timeout: float = 180) -> dict:
    binary, source = binary.resolve(strict=True), source.resolve(strict=True)
    original = source / "demo-v2/src/catalog.cj"
    digest = hashlib.sha256(original.read_bytes()).hexdigest()
    marker = "showcase-authoring-rebuild-verified"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="cjdoc-authoring-") as temporary:
        root = Path(temporary)
        copy = root / "pocketkit"
        shutil.copytree(source, copy, ignore=shutil.ignore_patterns("target", "__pycache__"))
        project = copy / "demo-v2"
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        command = [str(binary), "serve", "--project", str(project), "--port", str(port),
                   "--output", str(root / "generated"), "--no-cache"]
        log = root / "serve.log"
        with log.open("wb") as stream:
            process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=os.name == "posix")
            try:
                base = f"http://127.0.0.1:{port}"
                before = wait_status(opener, base, process, 1, timeout)
                with opener.open(base + "/index.html", timeout=5) as response:
                    if b"pocketkit" not in response.read().lower():
                        raise RuntimeError("serve did not publish PocketKit")
                check_served_artifact_limit(opener, base, root / "generated/html")
                edited = project / "src/catalog.cj"
                text = edited.read_text(encoding="utf-8")
                summary = "保存按插入顺序排列的文本条目"
                if text.count(summary) != 1:
                    raise RuntimeError("authoring source marker is ambiguous")
                edited.write_text(text.replace(summary, summary + " " + marker), encoding="utf-8")
                after = wait_status(opener, base, process, before["builds"] + 1, timeout)
                # v2 continues through navigation-index-part-N.json; enumerate every
                # part so a target that lands in a later part still resolves.
                from showcase_contract.site import load_json, load_navigation_index
                generated_root = root / "generated/html"
                navigation = load_navigation_index(
                    lambda name: load_json(generated_root / name), "navigation-index.json")
                entries = [entry for entry in navigation["pages"]
                           if entry.get("kind") == "symbol" and
                           entry.get("title") == "pocketkit.TextCatalog"]
                if len(entries) != 1:
                    raise RuntimeError("authoring target must resolve to one native route")
                href = entries[0]["href"]
                with opener.open(base + "/" + href, timeout=5) as response:
                    if marker.encode() not in response.read():
                        raise RuntimeError("serve status advanced without publishing the edit")
            except Exception as error:
                stop(process)
                details = log.read_text(encoding="utf-8", errors="replace")[-12000:]
                raise RuntimeError(f"{error}\nNative serve output:\n{details}") from error
            finally:
                stop(process)
    if hashlib.sha256(original.read_bytes()).hexdigest() != digest:
        raise RuntimeError("authoring check modified the managed source")
    report = {"schemaVersion": "cjdoc.showcase-authoring/1", "status": "passed",
              "command": ["cjdoc", "serve", "--project", "demo-v2", "--port", "<loopback-port>",
                          "--output", "<isolated-output>", "--no-cache"],
              "input": {"path": "examples/pocketkit/demo-v2/src/catalog.cj", "sha256": digest},
              "before": before, "after": after, "publishedHref": href,
              "durationMs": round((time.monotonic() - started) * 1000),
              "assertions": ["initial native build and HTTP page succeeded",
                             "GET/HEAD serve artifacts through 64 MiB and reject larger files",
                             "source edit increased successfulBuilds",
                             "native route served changed content",
                             "managed source stayed unchanged and process was stopped"]}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    check(args.binary, args.source, args.output)


if __name__ == "__main__":
    main()
