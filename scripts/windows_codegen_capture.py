#!/usr/bin/env python3
"""Capture one Windows code-generation observation; never qualify a product."""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib

SOURCE_COMMIT = "f8e5b8f0ac95ef5187b6c84d716dc9f3693fcdd1"
SOURCE_TREE = "640974578799f5b46fb2b70f3764c6a0e00fd22a"
MARKDOWN_COMMIT = "db4f9527944b589db8436669f1d255192388cee2"
FINGERPRINT = "5bbad497b41afb1dfd793023609c2ae71b883bca81f30f1bb0d83719d47245d0"
STDX_DIGEST = "24630a9317c38facebcdcd0772dde08d5cdb7e4eefdf95aee0fa30944b0c87f6"
PRODUCT_OPTIONS = "-O2 --fno-chir-function-inlining"
SCHEMA = "cjdoc.windows-codegen-capture/1"
LLVM_FILES = ("llc.exe", "libLLVM-15.dll", "libLLVM-Foundation-15.dll")
OPTIONAL_LLVM_FILES = ("opt.exe", "llvm-dis.exe")
MARKDOWN_COMMAND = re.compile(r"Compiling package [`'\"]markdown[`'\"]:")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
PRIVATE_CONTENT = re.compile(
    r"(?i)(?:[a-z]:[\\/]|(?<![a-z0-9_./:>])/[a-z0-9_.-]+(?:/[a-z0-9_.-]+)*|"
    r"gh[pousr]_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,}|"
    r"sk-[a-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|"
    r"\b(?:10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|"
    r"\b192\.168\.\d{1,3}\.\d{1,3}\b|"
    r"\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b)"
)


class CaptureError(ValueError):
    """A capture boundary was not established."""


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def regular(path: Path) -> bool:
    return path.is_file() and not path.is_symlink() and not (
        hasattr(path, "is_junction") and path.is_junction())


def inventory(root: Path, paths: list[str]) -> list[dict]:
    entries = []
    for name in sorted(paths):
        path = root / name
        if not regular(path) or not path.resolve().is_relative_to(root.resolve()):
            raise CaptureError("source inventory contains an external or non-regular file")
        entries.append({"path": name, "sha256": digest(path), "size": path.stat().st_size})
    return entries


def private_reasons(text: str, environment: dict[str, str]) -> list[str]:
    reasons = ["absolute path or credential pattern"] if PRIVATE_CONTENT.search(text) else []
    for key in ("USERNAME", "COMPUTERNAME", "HOSTNAME", "USERDNSDOMAIN"):
        value = environment.get(key, "")
        if len(value) >= 4 and value.casefold() in text.casefold():
            reasons.append("user or host identifier")
    return sorted(set(reasons))


def normalize(text: str, mappings: list[tuple[Path, str]]) -> str:
    result = ANSI.sub("", text)
    for path, label in sorted(mappings, key=lambda pair: len(str(pair[0])), reverse=True):
        for variant in sorted({str(path), path.as_posix(), str(path).replace("\\", "\\\\")},
                              key=len, reverse=True):
            result = re.sub(re.escape(variant), lambda _: label, result, flags=re.IGNORECASE)
    return result


def instrument_manifest(contents: str, ir: Path) -> str:
    package = tomllib.loads(contents)["package"]
    dependency = tomllib.loads(contents)["dependencies"]["markdown"]
    if package["name"] != "cjdoc" or dependency["commitId"] != MARKDOWN_COMMIT:
        raise CaptureError("source manifest does not pin the expected project and markdown")
    needle = 'override-compile-option = ""'
    if contents.count(needle) != 1:
        raise CaptureError("expected one empty source compile override")
    location = ir.as_posix()
    if any(character.isspace() for character in location) or '"' in location:
        raise CaptureError("save-temps path cannot be represented without shell quoting")
    option = f"{PRODUCT_OPTIONS} -V --save-temps {location}"
    return contents.replace(needle, f'override-compile-option = "{option}"', 1)


class Capture:
    def __init__(self, source: Path, out: Path, environment: dict[str, str],
                 runner=subprocess.run):
        self.source, self.out = source.resolve(), out.resolve()
        self.original_out = out
        self.environment, self.runner = dict(environment), runner
        self.record = {"schemaVersion": SCHEMA, "diagnosticOnly": True,
                       "acceptedBaseline": False, "qualification": False,
                       "buildInvocations": 0, "buildExitCode": None,
                       "captureIncomplete": True, "privacyBlocked": False, "issues": [],
                       "sourceCommit": SOURCE_COMMIT, "sourceTree": SOURCE_TREE,
                       "markdownCommit": MARKDOWN_COMMIT, "productOptions": PRODUCT_OPTIONS,
                       "observationOptions": ["-V", "--save-temps"],
                       "workflowCommit": environment.get("GITHUB_SHA", ""),
                       "runId": environment.get("GITHUB_RUN_ID", ""),
                       "runAttempt": environment.get("GITHUB_RUN_ATTEMPT", ""),
                       "runnerImage": [environment.get("ImageOS", ""),
                                       environment.get("ImageVersion", "")],
                       "controllerSha256": digest(Path(__file__))}
        self.mappings = [(self.out, "<diagnostic>"), (self.source, "<repo>"),
                         (Path.home(), "<home>")]
        for key, label in (("USERPROFILE", "<home>"), ("GITHUB_WORKSPACE", "<workspace>")):
            if environment.get(key):
                self.mappings.append((Path(environment[key]), label))
        self.tools: dict[str, Path] = {}
        self.before: list[dict] = []
        self.environ = dict(environment)

    def git(self, repository: Path, *arguments: str) -> str:
        result = self.runner(["git", "-C", str(repository), *arguments],
                             capture_output=True, text=True, check=False)
        if result.returncode:
            raise CaptureError("cannot verify the source Git identity")
        return result.stdout.strip()

    def snapshot(self) -> list[dict]:
        if (self.git(self.source, "rev-parse", "HEAD") != SOURCE_COMMIT or
                self.git(self.source, "rev-parse", "HEAD^{tree}") != SOURCE_TREE):
            raise CaptureError("source commit or tree differs from the frozen input")
        self.git(self.source, "diff", "--exit-code", "HEAD", "--")
        paths = self.git(self.source, "ls-files", "-z").rstrip("\0").split("\0")
        return inventory(self.source, paths)

    def authenticate(self) -> None:
        if not self.environment.get("CANGJIE_HOME"):
            raise CaptureError("the selected SDK home is unavailable")
        command = [sys.executable, str(self.source / "scripts/with_stdx.py"),
                   "--variant", "static", "--print-env", "--"]
        result = self.runner(command, capture_output=True, text=True, check=False)
        if result.returncode:
            raise CaptureError("static stdx authentication failed")
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        required = {"CJDOC_STDX_VARIANT": "static", "CJDOC_STDX_DIGEST": STDX_DIGEST,
                    "CJDOC_TOOLCHAIN_FINGERPRINT": FINGERPRINT,
                    "CJDOC_TOOLCHAIN_TARGET": "x86_64-w64-mingw32",
                    "CJDOC_TOOLCHAIN_VERSION": "1.2.0 (cjnative)"}
        if any(values.get(key) != value for key, value in required.items()):
            raise CaptureError("SDK or static stdx identity differs from the failing run")
        self.environ.update(values)
        self.record["authenticatedIdentity"] = required
        sdk = Path(self.environment["CANGJIE_HOME"]).resolve()
        self.mappings.append((sdk, "<sdk>"))
        for name in ("cjc", "cjpm"):
            candidate = shutil.which(name + ".exe", path=self.environment.get("PATH"))
            if candidate is None:
                raise CaptureError("the selected SDK tool is unavailable")
            path = Path(candidate).resolve()
            if not regular(path) or not path.is_relative_to(sdk):
                raise CaptureError("the selected tool is not inside the authenticated SDK")
            self.tools[name] = path
        llvm = sdk / "third_party/llvm/bin"
        for name in LLVM_FILES + OPTIONAL_LLVM_FILES:
            path = llvm / name
            if not regular(path):
                if name in LLVM_FILES:
                    raise CaptureError("a required LLVM tool identity is unavailable")
                continue
            self.tools[name] = path
        self.record["toolHashesBefore"] = self.tool_hashes()
        self.record["versions"] = {}
        for name in ("cjc", "cjpm"):
            version = self.runner([str(self.tools[name]), "-v"], capture_output=True,
                                  text=True, check=False)
            if version.returncode:
                raise CaptureError("a selected SDK tool cannot report its version")
            self.record["versions"][name] = version.stdout + version.stderr

    def tool_hashes(self) -> dict[str, str]:
        return {name: digest(path) for name, path in self.tools.items()}

    def prepare(self) -> None:
        self.before = self.snapshot()
        self.authenticate()
        copied = self.out / "source"
        copied.mkdir()
        for entry in self.before:
            target = copied / entry["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.source / entry["path"], target)
        self.record["sourceInventory"] = self.before
        manifest = copied / "cjpm.toml"
        original_bytes = manifest.read_bytes()
        original = original_bytes.decode("utf-8")
        observed = instrument_manifest(original, self.out / "ir")
        manifest.write_bytes(observed.encode("utf-8"))
        self.record["manifestBeforeSha256"] = hashlib.sha256(original_bytes).hexdigest()
        self.record["manifestObservedSha256"] = digest(manifest)
        self.record["privateSourceBefore"] = inventory(copied, [entry["path"] for entry in self.before])
        difference = "".join(difflib.unified_diff(original.splitlines(True), observed.splitlines(True),
                                               fromfile="source/cjpm.toml", tofile="observed/cjpm.toml"))
        (self.out / "raw/manifest.diff").write_text(difference, encoding="utf-8")
        for key in ("TMPDIR", "TMP", "TEMP"):
            self.environ[key] = str(self.out / "tmp")
        for key in ("CJDOC_STS_INVOCATION_LOG", "CJDOC_STS_WRAPPER_CJPM", "CJDOC_REAL_CJPM",
                    "CJDOC_STS_OVERRIDE_MODULE"):
            self.environ.pop(key, None)
        self.environ["cjHeapSize"] = "512MB"
        self.record["nativeScanner"] = self.environ.get("MARKDOWN_NATIVE_SCANNER", "unset")

    def build_once(self) -> None:
        command = [str(self.tools["cjpm"]), "build", "--jobs", "1", "-V",
                   "--target-dir", str(self.out / "target")]
        with (self.out / "attempt.json").open("x", encoding="utf-8") as marker:
            json.dump({"buildInvocations": 1, "argv": command}, marker)
        self.record["buildInvocations"] = 1
        self.record["buildArgv"] = command
        with (self.out / "raw/build.log").open("w", encoding="utf-8", newline="\n") as log:
            result = self.runner(command, cwd=self.out / "source", env=self.environ,
                                 stdout=log, stderr=subprocess.STDOUT, check=False)
        self.record["buildExitCode"] = result.returncode

    def publish(self, name: str, contents: str) -> None:
        value = normalize(contents, self.mappings)
        if private_reasons(value, self.environment):
            self.record["privacyBlocked"] = True
            self.record["issues"].append("privacy blocked " + name)
            value = "Privacy check blocked this text; original retained in the private raw directory.\n"
        (self.out / "upload" / name).write_text(value, encoding="utf-8", newline="\n")

    def stage_ir(self) -> bool:
        candidates = [p for p in (self.out / "ir").rglob("*")
                      if p.name.casefold() == "markdown.opt.bc"]
        if len(candidates) != 1 or not regular(candidates[0]):
            self.record["issues"].append("expected one regular markdown.opt.bc")
            return False
        bitcode = candidates[0]
        if not bitcode.resolve().is_relative_to((self.out / "ir").resolve()):
            raise CaptureError("bitcode escapes the owned IR directory")
        self.record["rawIr"] = {"name": "markdown.opt.bc", "sha256": digest(bitcode),
                                "size": bitcode.stat().st_size}
        disassembler = self.tools.get("llvm-dis.exe")
        if disassembler is None:
            self.record["privacyBlocked"] = True
            self.record["issues"].append("same-SDK llvm-dis unavailable; raw IR not uploaded")
            return False
        assembly = self.out / "raw/markdown.opt.ll"
        result = self.runner([str(disassembler), str(bitcode), "-o", str(assembly)],
                             capture_output=True, text=True, check=False)
        if result.returncode or not regular(assembly):
            self.record["privacyBlocked"] = True
            self.record["issues"].append("IR privacy inspection unavailable")
            return False
        if private_reasons(assembly.read_text(encoding="utf-8"), self.environment):
            self.record["privacyBlocked"] = True
            self.record["issues"].append("raw IR privacy check blocked upload")
            return False
        shutil.copyfile(bitcode, self.out / "upload/markdown.opt.bc")
        return True

    def finish(self) -> None:
        log = self.out / "raw/build.log"
        text = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
        commands = [line for line in text.splitlines() if MARKDOWN_COMMAND.search(line)]
        if log.exists():
            self.record["rawBuildLog"] = {"sha256": digest(log), "size": log.stat().st_size}
        command_ok = len(commands) == 1 and all(option in commands[0] for option in
                     ("-O2", "--fno-chir-function-inlining", "-V", "--save-temps", MARKDOWN_COMMIT))
        self.record["markdownCommandCount"] = len(commands)
        self.publish("build.log", text)
        self.publish("argv.json", json.dumps(commands, indent=2) + "\n")
        manifest = self.out / "raw/manifest.diff"
        self.publish("manifest.diff", manifest.read_text() if manifest.exists() else "not prepared\n")
        try:
            stable = self.before == self.snapshot()
            self.record["originalSourceUnchanged"] = stable
            if not stable:
                self.record["issues"].append("original source changed during capture")
            if self.record.get("privateSourceBefore"):
                private_after = inventory(self.out / "source", [entry["path"] for entry in self.before])
                self.record["privateSourceUnchanged"] = private_after == self.record["privateSourceBefore"]
                if not self.record["privateSourceUnchanged"]:
                    self.record["issues"].append("observed private source changed during build")
            hashes = self.tool_hashes()
            self.record["toolHashesAfter"] = hashes
            if hashes != self.record.get("toolHashesBefore", {}):
                self.record["issues"].append("SDK tool bytes changed during capture")
            if self.record["buildInvocations"]:
                home = Path(self.environ.get("USERPROFILE", str(Path.home())))
                dependency = home / ".cjpm/git/markdown" / MARKDOWN_COMMIT
                if self.git(dependency, "rev-parse", "HEAD") != MARKDOWN_COMMIT:
                    raise CaptureError("compiled markdown checkout identity differs")
                self.git(dependency, "diff", "--exit-code", "HEAD", "--")
                paths = self.git(dependency, "ls-files", "-z").rstrip("\0").split("\0")
                self.record["markdownSourceInventory"] = inventory(dependency, paths)
                ir_ok = self.stage_ir()
                self.record["captureIncomplete"] = not (command_ok and ir_ok)
        except (CaptureError, OSError, subprocess.SubprocessError, UnicodeError) as error:
            self.record["issues"].append(str(error))
        self.publish("tools.json", json.dumps({key: self.record.get(key) for key in
                     ("authenticatedIdentity", "toolHashesBefore", "toolHashesAfter", "versions")},
                     indent=2) + "\n")
        self.record["observation"] = ("NOT_REPRODUCED" if self.record["buildExitCode"] == 0 else
                                      "BUILD_FAILED" if self.record["buildExitCode"] is not None else
                                      "BUILD_NOT_STARTED")
        self.record["artifactFiles"] = {p.name: {"sha256": digest(p), "size": p.stat().st_size}
                                        for p in sorted((self.out / "upload").iterdir())}
        public = self.public_record(self.record)
        public["privacyBlocked"] = self.record["privacyBlocked"]
        (self.out / "upload/receipt.json").write_text(
            json.dumps(public, indent=2) + "\n", encoding="utf-8", newline="\n")

    def public_record(self, value):
        if isinstance(value, dict):
            return {key: self.public_record(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.public_record(item) for item in value]
        if isinstance(value, str):
            text = normalize(value, self.mappings)
            if private_reasons(text, self.environment):
                self.record["privacyBlocked"] = True
                return "<privacy-blocked>"
            return text
        return value

    def run(self) -> int:
        if self.original_out.exists() or self.original_out.is_symlink() or self.out.exists():
            raise CaptureError("capture output already exists; refusing another invocation")
        self.out.mkdir(parents=False)
        for name in ("ir", "tmp", "raw", "upload"):
            (self.out / name).mkdir()
        try:
            self.prepare()
            self.build_once()
        except (CaptureError, OSError, subprocess.SubprocessError, UnicodeError) as error:
            self.record["issues"].append(str(error))
        self.finish()
        code = self.record["buildExitCode"]
        if code is not None and code != 0:
            return code
        return 2 if (self.record["issues"] or self.record["captureIncomplete"] or
                     self.record["privacyBlocked"]) else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("the capture entry point requires the selected Windows SDK")
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    if not args.out.resolve().is_relative_to(runner_temp) or args.out.resolve() == runner_temp:
        parser.error("output must be a fresh child of runner temp")
    try:
        return Capture(args.source, args.out, dict(os.environ)).run()
    except CaptureError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
