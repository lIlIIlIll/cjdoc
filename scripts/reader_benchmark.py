#!/usr/bin/env python3
"""Generate actual reader benchmark sites and keep native and browser costs separate."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
try:
    from .reader_process import measured_process
    from .strict_json import strict_dumps, strict_load
except ImportError:
    from reader_process import measured_process
    from strict_json import strict_dumps, strict_load

REPO = Path(__file__).resolve().parent.parent
LIMITS = {"docIrMiB": 64, "artifactMiB": 64, "artifactTotalMiB": 512,
          "outputEntries": 65536, "typeOccurrences": 32768}


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(strict_dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def scrub(value: str, paths: dict[Path, str]) -> str:
    for source, replacement in sorted(paths.items(), key=lambda item: len(str(item[0])), reverse=True):
        value = value.replace(str(source), replacement)
    value = re.sub(r"(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ \d+ ([A-Z]) ",
                   r"<runtime-time> <runtime-thread> \1 ", value)
    return value


def verify_corpus(project: Path, manifest: dict) -> None:
    if manifest.get("schemaVersion") != "cjdoc.reader-corpus/1":
        raise ValueError("unsupported reader corpus manifest")
    for source in manifest["sources"]:
        relative = Path(source["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("corpus source escapes the project")
        path = project / relative
        if path.is_symlink() or file_digest(path) != source["sha256"]:
            raise ValueError("corpus source changed: " + relative.as_posix())
    actual = {path.relative_to(project).as_posix() for path in project.rglob("*.cj")
              if not {"target", ".git", "build-script-cache"}.intersection(path.relative_to(project).parts)}
    expected = {item["path"] for item in manifest["sources"] if item["path"].endswith(".cj")}
    if actual != expected:
        raise ValueError("corpus Cangjie inventory does not match its fixed source manifest")


def resource_failure(text: str, diagnostics: list[dict], result: dict) -> str | None:
    if result["timedOut"]:
        return None
    if "CJDOC3027" in text or any(item.get("code") == "CJDOC3027" for item in diagnostics):
        return "native Doc IR resource budget rejected the corpus (CJDOC3027)"
    if "Out of Memory" in text or "Out of memory" in text:
        return "fixed Cangjie runtime heap exhausted"
    # Native transaction errors are classified only by explicit budget messages.
    phrases = ("exceeds per-artifact limit", "output artifacts exceed total limit",
               "render artifacts exceed", "exceeds transaction tree entry limit",
               "staged output tree exceeds entry limit")
    if any(phrase in text for phrase in phrases):
        return "native output or Doc IR resource budget rejected the corpus"
    return None


def capture(command: list[str], name: str, root: Path, timeout: float,
            paths: dict[Path, str]) -> dict:
    stdout, stderr = root / (name + ".stdout.log"), root / (name + ".stderr.log")
    result = measured_process(command, stdout, stderr, timeout)
    for path in (stdout, stderr):
        path.write_text(scrub(path.read_text(encoding="utf-8", errors="replace"), paths), encoding="utf-8")
    result["command"] = [scrub(argument, paths) for argument in command]
    result["stdout"] = stdout.name
    result["stderr"] = stderr.name
    return result


def artifact_inventory(root: Path) -> dict:
    files = []
    total = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("native output contains a symbolic link")
        if path.is_file():
            size = path.stat().st_size
            total += size
            files.append({"path": path.relative_to(root).as_posix(), "bytes": size, "sha256": file_digest(path)})
    return {"bytes": total, "files": files}


def browser_command(args: argparse.Namespace, site: Path, output: Path, locale: str) -> list[str]:
    command = ["node", str(REPO / "tests/browser/measure-reader-scale.mjs"),
               "--site", str(site), "--manifest", str(args.manifest),
               "--output", str(output), "--label", args.label,
               "--samples", str(args.samples), "--locale", locale,
               "--transports", args.transports]
    if args.screenshots:
        command.append("--screenshots")
    return command


def run(args: argparse.Namespace) -> int:
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        raise ValueError("--revision must identify the actual compiled source revision")
    project, binary = args.project.resolve(strict=True), args.binary.resolve(strict=True)
    args.manifest = args.manifest.resolve(strict=True)
    manifest = strict_load(args.manifest)
    verify_corpus(project, manifest)
    root = args.output.absolute()
    root.mkdir(parents=True, exist_ok=False)
    paths = {Path.home(): "$HOME", REPO: "<repo>", project: "<corpus>",
             root: "<evidence>", binary: "cjdoc", args.manifest: "<corpus>/reader-corpus.json"}
    for key in ("CANGJIE_HOME", "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH"):
        if os.environ.get(key):
            paths[Path(os.environ[key])] = "<" + key.lower() + ">"
    report = {"schemaVersion": "cjdoc.reader-generation/1", "label": args.label,
              "rendererRevision": args.revision, "binarySha256": file_digest(binary),
              "recipe": manifest["recipe"], "sourceSha256": manifest["sourceSha256"],
              "taskManifestSha256": file_digest(args.manifest), "sources": manifest["sources"],
              "provenance": manifest.get("provenance", {"kind": "generated-source", "recipe": manifest["recipe"]}),
              "configuration": {"audience": "external", "semantic": "source", "lintProfile": "off",
                                "sourceCache": "disabled", "nativeHeap": os.environ.get("cjHeapSize", "runtime-default"),
                                "limits": LIMITS, "locales": args.locales,
                                "osFileCache": "uncontrolled; no cold-OS-cache claim"},
              "toolchain": {key: os.environ.get(key) for key in
                            ("CJDOC_TOOLCHAIN_VERSION", "CJDOC_TOOLCHAIN_TARGET", "CJDOC_TOOLCHAIN_FINGERPRINT", "CJDOC_STDX_DIGEST")},
              "stages": [], "locales": [], "status": "running"}
    try:
        version = subprocess.run([str(binary), "--version"], capture_output=True, text=True, check=True, timeout=30)
        report["generatorVersion"] = version.stdout.strip()
        for name in ("cjc", "cjpm"):
            executable = shutil.which(name)
            if not executable:
                raise ValueError(f"{name} is unavailable in the selected SDK environment")
            identity = capture([executable, "-v"], name + "-version", root, 30, {**paths, Path(executable): name})
            if identity["exitCode"] or identity["timedOut"]:
                raise ValueError(f"{name} -v failed in the selected SDK environment")
            report["toolchain"][name] = {"sha256": file_digest(Path(executable)),
                                         "version": (root / identity["stdout"]).read_text(encoding="utf-8").strip(),
                                         "logs": identity}
        ir_root = root / "native-json"
        command = [str(binary), "generate", "--project", str(project), "--format", "json",
                   "--audience", "external", "--semantic", "source", "--lint-profile", "off",
                   "--no-cache", "--output", str(ir_root)]
        generated = capture(command, "generate", root, args.timeout, paths)
        report["stages"].append({"name": "source-to-doc-ir", **generated})
        document_path = ir_root / "docs.json"
        document = strict_load(document_path) if document_path.is_file() else {}
        diagnostics = document.get("diagnostics", [])
        report["nativeResult"] = {"declarations": len(document.get("declarations", [])),
                                  "status": document.get("status"),
                                  "diagnostics": diagnostics,
                                  "docIrSha256": file_digest(document_path) if document else None,
                                  "docIrBytes": document_path.stat().st_size if document else None}
        text = (root / generated["stderr"]).read_text(encoding="utf-8")
        limited = resource_failure(text, diagnostics, generated)
        if limited:
            report.update(status="resource-limited", reason=limited)
            return 1
        errors = [item for item in diagnostics if item.get("severity") == "error"]
        if generated["exitCode"] or generated["timedOut"] or errors or not document:
            report.update(status="failed", reason="native source generation exceeded the fixed observation timeout"
                          if generated["timedOut"] else "native source generation failed")
            return 1
        if len(document.get("declarations", [])) < manifest["targetDeclarations"]:
            report.update(status="failed", reason="native corpus contains fewer declarations than the fixed target")
            return 1
        for locale in args.locales:
            destination = root / ("locale-" + locale)
            rendered = capture([str(binary), "render", "--input", str(document_path), "--format", "html",
                                "--locale", locale, "--output", str(destination)], "render-" + locale,
                               root, args.timeout, paths)
            report["stages"].append({"name": "doc-ir-to-html", "locale": locale, **rendered})
            text = (root / rendered["stderr"]).read_text(encoding="utf-8")
            limited = resource_failure(text, [], rendered)
            if limited or rendered["exitCode"] or rendered["timedOut"]:
                report.update(status="resource-limited" if limited else "failed",
                              reason=limited or ("native HTML replay exceeded the fixed observation timeout"
                                                if rendered["timedOut"] else "native HTML replay failed"))
                return 1
            site = destination / "html"
            locale_report = {"locale": locale, "site": site.relative_to(root).as_posix(),
                             "artifacts": artifact_inventory(destination)}
            if not args.no_browser:
                measured = capture(browser_command(args, site, root / ("browser-" + locale), locale),
                                   "browser-" + locale, root, args.browser_timeout, paths)
                report["stages"].append({"name": "browser-reading", "locale": locale, **measured})
                locale_report["browserReport"] = f"browser-{locale}/reader-browser.json"
                if measured["exitCode"]:
                    report.update(status="failed", reason="browser benchmark could not complete; retain failure report")
                    report["locales"].append(locale_report)
                    return 1
            report["locales"].append(locale_report)
        verify_corpus(project, manifest)
        report["status"] = "measured"
        # Measured is not PASS: baseline reader-task failures remain in browser reports.
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report.update(status="failed", reason=scrub(str(error), paths))
        return 1
    finally:
        write_json(root / "reader-generation.json", report)
        print(strict_dumps({"label": args.label, "status": report["status"],
                            "declarations": report.get("nativeResult", {}).get("declarations"),
                            "reason": report.get("reason")}))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--label", choices=("baseline", "after"), required=True)
    parser.add_argument("--locales", nargs="+", choices=("en", "zh-CN"), default=["en", "zh-CN"])
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--transports", default="root,subpath,file")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--browser-timeout", type=float, default=1800)
    args = parser.parse_args()
    if not 2 <= args.samples <= 100 or args.timeout <= 0 or args.browser_timeout <= 0:
        parser.error("samples must be2..100 and timeouts positive")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
