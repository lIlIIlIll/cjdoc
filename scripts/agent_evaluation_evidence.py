#!/usr/bin/env python3
"""What counts as captured, source-confined and frozen-library-bound evidence.

Every adjudication quote is checked here against the bytes that were actually
captured: project-root-relative source with hashes, Doc IR files listed in the
run manifest, and captured answers. A claim that names a library, version or
source identity is admitted only for the module that owns the declaration, so a
consumer's own root module cannot lend identity to a dependency declaration.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
import sys
from typing import Any

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_dumps, strict_load
except ImportError:  # Direct script execution.
    from strict_json import strict_dumps, strict_load

try:
    import agent_evaluation_runtime as consumer_runtime
except ImportError:
    from . import agent_evaluation_runtime as consumer_runtime

try:
    from .agent_evaluation_capture import (
        SCOPE_TABLE, Capture, digest_of, require)
except ImportError:  # Direct script execution.
    from agent_evaluation_capture import (
        SCOPE_TABLE, Capture, digest_of, require)


class Evidence:
    """Source-confined, captured-file and frozen-library-bound evidence."""

    def __init__(self, project_root: Path, doc_ir: dict[str, Path],
                 capture: Capture, verification: dict) -> None:
        self.project_root = project_root.resolve(strict=True)
        self.doc_ir = doc_ir
        self._documents = {}
        self._declarations = {}
        self._doc_digests = {}
        self._bindings = {}
        self._source_reads = {}
        self._primary = {}
        pool = set()
        for scope_name in dict.fromkeys(task.get("scope") or "" for task in capture.protocol["tasks"]):
            requirement = SCOPE_TABLE[scope_name]
            roots = [self.project_root / item["path"] for item in requirement["dependencies"]]
            closure = consumer_runtime.source_closure(self.project_root, roots)
            recorded = ((verification.get("receipt") or {}).get("scopes") or {}).get(scope_name) or {}
            observed = [{"path": item["relative"].as_posix(), "name": item["name"],
                         "version": item["version"], "identity": item["identity"]} for item in closure]
            require(recorded.get("sourceIdentities") == observed,
                    "verification source closure differs from current frozen scope " + scope_name)
            for item in observed:
                pool.add((item["name"], item["version"], item["identity"]))
            if requirement["dependencies"]:
                first = requirement["dependencies"][0]
                primary = next(item for item in observed if item["path"] == first["path"])
                self._primary[scope_name] = primary
        captured_digests = {item.get("sha256") for item in capture.manifest.get("snapshots", [])
                            if isinstance(item, dict)}
        for label, path in doc_ir.items():
            require(path.is_file() and not path.is_symlink(), "Doc IR must be a regular captured file")
            before = digest_of(path)
            require(before in captured_digests,
                    "Doc IR " + label + " bytes were not captured in the evaluator run")
            document = strict_load(path, description="Doc IR " + label)
            require(digest_of(path) == before, "Doc IR changed while loading " + label)
            require(isinstance(document, dict) and document.get("schemaVersion") == "cjdoc.doc-ir/19",
                    "Doc IR " + label + " is not the current captured v19 format")
            self._documents[label] = document
            self._doc_digests[label] = before
            self._declarations[label] = _declaration_index(document)
            bindings = []
            for module in document.get("modules", []):
                for dependency in document.get("dependencies", []):
                    # componentModuleId, not the consuming moduleId, owns these
                    # declarations. Imported sets with a local 'root' id are not
                    # evidence for this snapshot's unrelated root declarations.
                    if dependency.get("componentModuleId") != module.get("id"):
                        continue
                    key = (module.get("name"), dependency.get("version"), dependency.get("identity"))
                    if (dependency.get("kind") != "source" or
                            dependency.get("state") not in ("observed", "verified") or key not in pool):
                        continue
                    binding = {"moduleId": module["id"], "library": key[0],
                               "apiVersion": key[1], "sourceIdentity": key[2],
                               "snapshotSha256": before}
                    if binding not in bindings:
                        bindings.append(binding)
            self._bindings[label] = bindings

    def digest(self, path: Path) -> str:
        if path not in self._source_reads:
            content = path.read_bytes()
            self._source_reads[path] = (hashlib.sha256(content).hexdigest(), content)
        return self._source_reads[path][0]

    def check_current_inputs(self) -> None:
        for label, path in self.doc_ir.items():
            require(digest_of(path) == self._doc_digests[label], "Doc IR changed after evidence validation")
        for path, (digest, _) in self._source_reads.items():
            require(not path.is_symlink() and digest_of(path) == digest,
                    "source evidence changed after validation")

    def check(self, item: Any, where: str, *, answer_text: str = "") -> list[str]:
        if not isinstance(item, dict):
            return [where + ": evidence item must be an object"]
        kind = item.get("kind")
        if kind == "source":
            return self._check_source(item, where)
        if kind == "doc-ir":
            return self._check_doc_ir(item, where)
        if kind != "answer":
            return [where + ": unknown evidence kind"]
        quote = item.get("quote")
        if not isinstance(quote, str) or not quote.strip() or quote not in answer_text:
            return [where + ": answer evidence quote does not occur verbatim in the captured answer"]
        return []

    def _check_source(self, item: dict, where: str) -> list[str]:
        relative = item.get("path")
        if not isinstance(relative, str) or not relative:
            return [where + ": source evidence needs a path"]
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            return [where + ": source evidence must be project-root relative"]
        path = self.project_root / candidate
        if any(part.is_symlink() for part in [path, *path.parents] if part != self.project_root):
            return [where + ": symbolic source evidence is not admitted"]
        if not path.is_file() or not path.resolve().is_relative_to(self.project_root):
            return [where + ": source evidence is missing or outside the frozen root"]
        problems = []
        if item.get("sha256") != self.digest(path):
            problems.append(where + ": source evidence digest differs")
        try:
            text = self._source_reads[path][1].decode("utf-8")
        except UnicodeDecodeError:
            return problems + [where + ": source evidence is not UTF-8"]
        start, end = item.get("lineStart"), item.get("lineEnd")
        if start is not None or end is not None:
            if type(start) is not int or type(end) is not int or not 1 <= start <= end:
                return problems + [where + ": invalid source line range"]
            lines = text.splitlines()
            if end > len(lines):
                return problems + [where + ": source line range exceeds the file"]
            text = "\n".join(lines[start - 1:end])
        if "excerpt" in item and (not isinstance(item["excerpt"], str) or
                                  not item["excerpt"] or item["excerpt"] not in text):
            problems.append(where + ": source excerpt is not present in the pinned bytes")
        return problems

    def _eligible_bindings(self, item: dict) -> list[dict]:
        label = item.get("snapshot")
        identifier = item.get("declarationId")
        declaration = self._declarations.get(label, {}).get(identifier) if identifier else None
        module = declaration.get("moduleId") if declaration else item.get("moduleId")
        return [binding for binding in self._bindings.get(label, [])
                if (module is None or binding["moduleId"] == module) and
                all(field not in item or item[field] == binding[field]
                    for field in ("library", "apiVersion", "sourceIdentity"))]

    def _check_doc_ir(self, item: dict, where: str) -> list[str]:
        label = item.get("snapshot")
        if label not in self._documents:
            return [where + ": Doc IR evidence names an uncaptured snapshot"]
        identifier = item.get("declarationId")
        if identifier is not None and identifier not in self._declarations[label]:
            return [where + ": Doc IR evidence names an unknown declaration"]
        if not self._eligible_bindings(item):
            return [where + ": Doc IR library/version/module/source identity is not bound to frozen source"]
        field = item.get("field")
        if not isinstance(field, str) or not field:
            return [where + ": Doc IR evidence needs a field"]
        value = self._declarations[label][identifier] if identifier is not None else self._documents[label]
        for part in field.split("."):
            if not isinstance(value, dict) or part not in value:
                return [where + ": claimed Doc IR field does not exist"]
            value = value[part]
        if "contains" not in item and "equals" not in item:
            return [where + ": Doc IR evidence needs a concrete contains or equals claim"]
        rendered = value if isinstance(value, str) else strict_dumps(value, ensure_ascii=False)
        if "contains" in item and (not isinstance(item["contains"], str) or
                                   not item["contains"] or item["contains"] not in rendered):
            return [where + ": claimed Doc IR text is not present"]
        if "equals" in item and strict_dumps(value, sort_keys=True) != strict_dumps(item["equals"], sort_keys=True):
            return [where + ": claimed Doc IR value differs"]
        return []

    def selects_primary(self, items: list[dict], task: dict) -> bool:
        primary = self._primary.get(task.get("scope") or "")
        if not primary:
            return False
        for item in items:
            if item.get("kind") == "source":
                path = Path(item.get("path") or "")
                if path.is_relative_to(Path(primary["path"])):
                    return True
            if item.get("kind") == "doc-ir":
                for binding in self._eligible_bindings(item):
                    if (binding["library"], binding["apiVersion"], binding["sourceIdentity"]) == (
                            primary["name"], primary["version"], primary["identity"]):
                        return True
        return False


def _declaration_index(document: dict) -> dict[str, dict]:
    declarations = document.get("declarations")
    require(isinstance(declarations, list), "captured Doc IR has no flat declaration collection")
    index = {}
    for declaration in declarations:
        require(isinstance(declaration, dict) and isinstance(declaration.get("id"), str),
                "captured declaration is malformed")
        identifier = declaration["id"]
        require(identifier not in index, "captured Doc IR repeats a declaration identity")
        index[identifier] = declaration
    return index
