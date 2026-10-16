#!/usr/bin/env python3
"""Prepare a local cjdoc.build-context/1 record from explicitly selected inputs.

This is an input observation receipt, not an attestation that a build succeeded.
No compiler, SDK environment variable, cache search, Git command or network is used.
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
import tomllib

MAX_FILE = 64 * 1024 * 1024
MAX_BYTES = 512 * 1024 * 1024
MAX_ENTRIES = 100000

class ObservationBudget:
    def __init__(self):
        self.remaining = MAX_BYTES
        self.entries = 0

    def reserve(self, size):
        if size < 0 or size > self.remaining:
            raise ValueError("aggregate observation byte/work budget exceeded")
        self.remaining -= size

    def visit(self, depth):
        self.entries += 1
        if self.entries > MAX_ENTRIES or depth > 128:
            raise ValueError("aggregate inventory entry/depth limit exceeded")



def artifact_digest(path: Path, expected_size: int | None = None) -> str:
    before = path.stat()
    if expected_size is not None and before.st_size != expected_size:
        raise ValueError("artifact changed before hashing")
    if before.st_size > MAX_BYTES:
        raise ValueError("artifact exceeds aggregate observation budget")
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as stream:
        while chunk := stream.read(64 * 1024):
            total += len(chunk)
            if total > before.st_size:
                raise ValueError("artifact changed while hashing")
            digest.update(chunk)
    after = path.stat()
    if total != before.st_size or (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
        raise ValueError("artifact changed while hashing")
    return digest.hexdigest()




def identity(path: Path, source: bool = True, budget: ObservationBudget | None = None) -> str:
    budget = budget or ObservationBudget()
    path = path.resolve(strict=True)
    if path.is_file():
        if source:
            raise ValueError("source input must be a directory")
        size = path.stat().st_size
        budget.reserve(size)
        return "sha256:" + artifact_digest(path, size)
    files = []

    def walk(directory: Path):
        for entry in directory.iterdir():
            budget.visit(len(entry.relative_to(path).parts))
            relative = entry.relative_to(path).as_posix()
            if entry.name.startswith(".") or (source and entry.name == "target"):
                continue
            if entry.is_symlink():
                raise ValueError("symbolic links are not supported in an inventory")
            if entry.is_dir():
                walk(entry)
            elif entry.is_file() and (not source or entry.suffix == ".cj" or entry.name in ("cjpm.toml", "cjpm.lock")):
                files.append((relative, entry))

    walk(path)
    if not files:
        raise ValueError("inventory is empty")
    digest = hashlib.sha256(b"cjdoc.dependency-inventory/1\n")
    for relative, entry in sorted(files, key=lambda pair: pair[0].encode("utf-8")):
        size = entry.stat().st_size
        if source and size > MAX_FILE:
            raise ValueError("source inventory per-file byte limit exceeded")
        budget.reserve(size)
        if source:
            content = entry.read_bytes()
            if len(content) != size:
                raise ValueError("input changed while observing")
            content_digest = hashlib.sha256(content).hexdigest()
        else:
            content_digest = artifact_digest(entry, size)
        encoded = relative.encode("utf-8")
        digest.update(str(len(encoded)).encode() + b":" + encoded + b":" + str(size).encode() + b":" + content_digest.encode() + b"\n")
    return "sha256:" + digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--target", required=True, help="actual target selected by the build; never inferred from the generator SDK")
    parser.add_argument("--cfg", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--dependency", action="append", default=[], metavar="OWNER:KIND:NAME=PATH",
                        help="actual selected artifact input; kind binary/std/stdx/toolchain")
    parser.add_argument("--source-dependency", action="append", default=[], metavar="OWNER:KIND:NAME=PATH",
                        help="actual selected source input; kind source/std/stdx")
    args = parser.parse_args()
    project = args.project.resolve(strict=True)
    output = args.output.absolute()
    base = output.parent
    cfg = {}
    for item in args.cfg:
        name, separator, value = item.partition("=")
        if not separator or not name or name in cfg and cfg[name] != value:
            parser.error("cfg must be nonconflicting NAME=VALUE")
        cfg[name] = value
    if "target" in cfg and cfg["target"] != args.target:
        parser.error("cfg target must match --target")
    modules = {}
    observation = ObservationBudget()
    identities = {}

    def observed_identity(path, source=True):
        key = (path.resolve(strict=True), source)
        if key not in identities:
            identities[key] = identity(key[0], source, observation)
        return identities[key]

    def local(path):
        return Path(os.path.relpath(path, base)).as_posix()

    def dependency(name, kind, path, content):
        result = {"name": name, "kind": kind, "path": local(path),
                  "identity": observed_identity(path, content == "source"), "content": content}
        if kind == "source":
            manifest = tomllib.loads((path / "cjpm.toml").read_text(encoding="utf-8"))
            version = manifest.get("package", {}).get("version", "")
            if version:
                result["version"] = version
        return result

    def add_module(path):
        path = path.resolve(strict=True)
        if path in modules:
            return
        if len(modules) >= 4096:
            raise ValueError("module limit exceeded")
        manifest = tomllib.loads((path / "cjpm.toml").read_text(encoding="utf-8"))
        name = manifest.get("package", {}).get("name", "workspace")
        module = {"name": name, "path": local(path), "identity": observed_identity(path), "dependencies": []}
        modules[path] = module
        for member in manifest.get("workspace", {}).get("members", []):
            add_module(path / member)
        dependencies = dict(manifest.get("dependencies", {}))
        selected = manifest.get("target", {}).get(args.target, {})
        dependencies.update(selected.get("dependencies", {}))
        for dep_name, specification in sorted(dependencies.items()):
            if isinstance(specification, dict) and "path" in specification:
                # A manifest token is not evidence of cjpm's expanded selection.
                # Do not consult this observer's environment or accept a literal
                # $VAR/${VAR} directory as the actual target dependency.
                if "$" in specification["path"]:
                    print("environment-dependent source path not automatically selected; "
                          "supply --source-dependency with the actual resolved input", file=sys.stderr)
                    continue
                dep_path = (path / specification["path"]).resolve(strict=True)
                module["dependencies"].append(dependency(dep_name, "source", dep_path, "source"))
                add_module(dep_path)

    add_module(project)
    for source, inputs in ((False, args.dependency), (True, args.source_dependency)):
        for item in inputs:
            head, separator, value = item.partition("=")
            fields = head.split(":")
            if not separator or len(fields) != 3 or not value:
                parser.error("dependency must be OWNER:KIND:NAME=PATH")
            owner, kind, name = fields
            if kind not in (("source", "std", "stdx") if source else ("binary", "std", "stdx", "toolchain")):
                parser.error("invalid dependency kind/content")
            matches = [module for module in modules.values() if module["name"] == owner]
            if len(matches) != 1:
                parser.error("dependency owner must identify exactly one project graph module")
            selected = Path(value).resolve(strict=True)
            matches[0]["dependencies"].append(dependency(name, kind, selected, "source" if source else "artifact"))
            if kind == "source":
                add_module(selected)
    for module in modules.values():
        module["dependencies"].sort(key=lambda item: (item["kind"], item["name"]))
        keys = [(item["kind"], item["name"]) for item in module["dependencies"]]
        if len(set(keys)) != len(keys):
            parser.error("duplicate dependency selection")
    result = {"schemaVersion": "cjdoc.build-context/1", "project": {"path": local(project), "identity": modules[project]["identity"]},
              "target": args.target, "cfg": "\n".join(f"{name}={value}" for name, value in sorted(cfg.items())),
              "modules": sorted(modules.values(), key=lambda item: (item["name"], item["path"]))}
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
