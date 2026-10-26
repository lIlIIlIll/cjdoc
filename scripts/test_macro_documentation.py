"""Source macro documentation through the real generator and offline clients."""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

try:
    from .test_query_mcp import McpProcess
except ImportError:
    from test_query_mcp import McpProcess

REPO = Path(__file__).resolve().parent.parent


def copy_windows_runtime_dlls(environment: dict[str, str], destination: Path) -> None:
    configured = environment.get("CANGJIE_HOME") or environment.get("CANGJIE_SDK_ROOT")
    if not configured:
        raise AssertionError("Windows offline test requires the selected SDK runtime DLLs")
    sdk = Path(configured).resolve()
    for relative in ("runtime/lib/windows_x86_64_cjnative", "lib/windows_x86_64_cjnative", "tools/lib"):
        directory = sdk / relative
        if not directory.is_dir():
            continue
        for library in sorted(directory.iterdir()):
            if not library.is_file() or library.suffix.lower() != ".dll":
                continue
            source = library.resolve(strict=True)
            if not source.is_relative_to(sdk):
                raise AssertionError("runtime DLL escapes the selected SDK")
            target = destination / library.name
            if not target.exists():
                shutil.copy2(source, target)
    if not any(destination.iterdir()):
        raise AssertionError("selected SDK contains no Windows runtime DLLs")


class OfflineRuntimeInventoryTest(unittest.TestCase):
    def test_private_runtime_copies_only_dlls_from_selected_library_roots(self) -> None:
        with tempfile.TemporaryDirectory(prefix="cjdoc-runtime-inventory-") as temporary:
            root = Path(temporary).resolve()
            sdk, isolated = root / "sdk", root / "runtime"
            isolated.mkdir()
            library = sdk / "runtime/lib/windows_x86_64_cjnative"
            library.mkdir(parents=True)
            (library / "runtime.dll").write_bytes(b"runtime inventory fixture")
            for name in ("cjc.exe", "cjpm.exe", "curl.exe", "api.cj"):
                (library / name).write_bytes(b"must not be copied")
            tools = sdk / "bin"
            tools.mkdir()
            (tools / "compiler.dll").write_bytes(b"compiler library outside runtime roots")
            copy_windows_runtime_dlls({"CANGJIE_HOME": str(sdk), "PATH": str(tools)}, isolated)
            self.assertEqual({path.name for path in isolated.iterdir()}, {"runtime.dll"})


class MacroDocumentationIntegrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = REPO / "target/release/bin/main"
        if not cls.binary.is_file():
            cls.binary = Path(f"{cls.binary}.exe")
        if not cls.binary.is_file():
            raise AssertionError("macro documentation requires the built cjdoc binary")
        cls.temporary = tempfile.TemporaryDirectory(prefix="cjdoc-macro-docs-")
        cls.root = Path(cls.temporary.name).resolve()
        cls.addClassCleanup(cls.temporary.cleanup)
        for fixture in ("macro_sources", "macro_wrapped"):
            for run in ("first", "second"):
                command = [str(cls.binary), "generate", "--project",
                           str(REPO / "tests/fixtures/projects" / fixture),
                           "--format", "json", "--format", "html", "--format", "markdown",
                           "--format", "api-surface", "--agent-full", "--audience", "external",
                           "--output", str(cls.root / fixture / run),
                           "--cache-dir", str(cls.root / "cache" / fixture)]
                result = subprocess.run(command, text=True, capture_output=True, timeout=120)
                if result.returncode:
                    raise AssertionError(result.stderr)

    def document(self, fixture: str) -> dict:
        return json.loads((self.root / fixture / "first/docs.json").read_text(encoding="utf-8"))

    def test_macro_docs_and_all_projections_are_deterministic(self) -> None:
        for fixture in ("macro_sources", "macro_wrapped"):
            first = self.root / fixture / "first"
            second = self.root / fixture / "second"
            first_files = {p.relative_to(first): p.read_bytes() for p in first.rglob("*")
                           if p.is_file() and p.name != ".cjdoc-output.json"}
            second_files = {p.relative_to(second): p.read_bytes() for p in second.rglob("*")
                            if p.is_file() and p.name != ".cjdoc-output.json"}
            self.assertEqual(first_files, second_files)
        document = self.document("macro_sources")
        self.assertEqual(document["status"], "complete")
        self.assertEqual([s["kind"] for s in document["declarations"]], ["macro", "macro"])
        self.assertEqual(len({s["id"] for s in document["declarations"]}), 2)
        self.assertEqual(document["unsupportedDeclarations"], [])
        codes = {d["code"] for d in document["diagnostics"]}
        self.assertFalse(codes & {"CJDOC1001", "CJDOC3023", "CJDOC1009"})
        site = self.root / "macro_sources/first/html"
        packages = "".join(p.read_text(encoding="utf-8") for p in (site / "packages").glob("*.html"))
        self.assertIn('id="macros"', packages)
        self.assertIn("&lt;script&gt;", packages)
        self.assertNotIn("<script>alert(1)</script>", packages)
        search = json.loads((site / "search-index.json").read_text(encoding="utf-8"))
        self.assertEqual([s["kind"] for s in search["entries"]], ["macro", "macro"])
        surface = json.loads((self.root / "macro_sources/first/api-surface/api-surface.json")
                             .read_text(encoding="utf-8"))
        self.assertEqual([s["kind"] for s in surface["declarations"]], ["macro", "macro"])
        self.assertTrue((site / "llms-full.txt").is_file())

    def test_wrapped_sources_preserve_visibility_owners_and_unknown_generated_members(self) -> None:
        document = self.document("macro_wrapped")
        self.assertEqual(document["status"], "partial")
        symbols = {s["name"]: s for s in document["declarations"]}
        self.assertEqual(set(symbols), {"State", "Idle", "Busy", "code", "Resource", "size", "Hidden"})
        self.assertEqual(symbols["Hidden"]["visibility"], "private")
        site = self.root / "macro_wrapped/first/html"
        search = json.loads((site / "search-index.json").read_text(encoding="utf-8"))
        self.assertNotIn("Hidden", {entry["name"] for entry in search["entries"]})
        self.assertEqual(symbols["State"]["source"]["start"]["line"], 4)
        self.assertEqual(symbols["code"]["source"]["start"]["line"], 13)
        self.assertEqual(symbols["code"]["ownerId"], symbols["State"]["id"])
        self.assertEqual(symbols["size"]["visibility"], "protected")
        self.assertEqual([s["name"] for s in document["unsupportedDeclarations"]], ["Opaque"])
        self.assertEqual(len(document["macroInvocations"]), 5)
        self.assertEqual(document["orphanDocComments"], [])

    def test_wrapper_annotations_keep_conditional_source_selection(self) -> None:
        project = self.root / "conditional_macro"
        (project / "src").mkdir(parents=True)
        (project / "cjpm.toml").write_text('[package]\nname = "conditional_macro"\n', encoding="utf-8")
        (project / "src/api.cj").write_text(
            'package conditional_macro\n@When[os == "Windows"]\n' +
            '@Outer\n@Derive[Equatable]\npublic enum OnlyWindows { A }\n', encoding="utf-8")
        for platform, expected in (("Linux", set()), ("Windows", {"OnlyWindows", "A"})):
            result = subprocess.run([str(self.binary), "generate", "--project", str(project),
                                     "--format", "json", "--stdout", "--no-cache",
                                     "--cfg", f"os={platform}"],
                                    text=True, capture_output=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(result.stdout)
            self.assertEqual({s["name"] for s in document["declarations"]}, expected)
            if expected:
                owner = next(s for s in document["declarations"] if s["name"] == "OnlyWindows")
                self.assertTrue(any(a["spelling"].startswith("@When") for a in owner["annotations"]))

    def test_tuple_bindings_share_wrapped_annotations_ranges_and_documentation(self) -> None:
        project = self.root / "tuple_macro"
        (project / "src").mkdir(parents=True)
        (project / "cjpm.toml").write_text('[package]\nname = "tuple_macro"\n', encoding="utf-8")
        (project / "src/api.cj").write_text(
            'package tuple_macro\n/** Tuple docs. */\n@When[os == "Windows"]\n' +
            '@Outer\npublic let (left, right) = (1, 2)\n', encoding="utf-8")
        for platform in ("Linux", "Windows"):
            result = subprocess.run([str(self.binary), "generate", "--project", str(project),
                                     "--format", "json", "--stdout", "--no-cache",
                                     "--cfg", f"os={platform}"],
                                    text=True, capture_output=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(result.stdout)
            if platform == "Linux":
                self.assertEqual(document["declarations"], [])
            else:
                declarations = document["declarations"]
                self.assertEqual({s["name"] for s in declarations}, {"left", "right"})
                self.assertEqual(declarations[0]["source"], declarations[1]["source"])
                for symbol in declarations:
                    self.assertEqual(symbol["documentation"]["summary"], "Tuple docs.")
                    self.assertTrue(any(a["spelling"].startswith("@When") for a in symbol["annotations"]))
            self.assertEqual(document["orphanDocComments"], [])

    def test_macro_reexports_keep_all_legal_overloads(self) -> None:
        project = self.root / "macro_reexports"
        (project / "src").mkdir(parents=True)
        dependency = json.dumps(str(REPO / "tests/fixtures/projects/macro_sources"))
        (project / "cjpm.toml").write_text(
            '[package]\nname = "macro_reexports"\n[dependencies]\n' +
            f'macro_sources = {{ path = {dependency} }}\n', encoding="utf-8")
        (project / "src/api.cj").write_text(
            'macro package macro_reexports\npublic import macro_sources.Echo\n' +
            'public import macro_sources.*\n', encoding="utf-8")
        result = subprocess.run([str(self.binary), "generate", "--project", str(project),
                                 "--format", "json", "--stdout", "--no-cache",
                                 "--include-path-dependencies"],
                                text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(result.stdout)
        ids = {s["id"] for s in document["declarations"] if s["kind"] == "macro"}
        self.assertEqual(len(ids), 2)
        package = next(p for p in document["packages"] if p["name"] == "macro_reexports")
        self.assertEqual(len(package["reExports"]), 2)
        for exposure in package["reExports"]:
            self.assertEqual(exposure["state"], "resolved")
            self.assertEqual(set(exposure["bindings"][0]["targetSymbolIds"]), ids)

    def test_duplicate_macro_signatures_fail_without_duplicate_public_ids(self) -> None:
        project = self.root / "duplicate_macros"
        (project / "src").mkdir(parents=True)
        (project / "cjpm.toml").write_text('[package]\nname = "duplicate_macros"\n', encoding="utf-8")
        (project / "src/api.cj").write_text(
            "macro package duplicate_macros\nimport std.ast.*\n" +
            "public macro Echo(input: Tokens): Tokens { input }\n" * 2, encoding="utf-8")
        result = subprocess.run([str(self.binary), "generate", "--project", str(project),
                                 "--format", "json", "--stdout", "--no-cache"],
                                text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["status"], "partial")
        self.assertIn("CJDOC2006", {d["code"] for d in document["diagnostics"]})
        ids = [s["id"] for s in document["declarations"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_generated_agent_snapshot_supports_offline_query_and_stdio_mcp(self) -> None:
        snapshot = self.root / "macro_sources/first/html/agent/manifest.json"
        request = {"operation": "search", "name": "Echo", "parameterTypes": ["Tokens"]}
        # Keep only copied runtime DLLs on Windows; the compiler and network
        # clients remain unavailable to both frozen-artifact consumers.
        runtime = self.root / "offline-runtime"
        runtime.mkdir()
        if os.name == "nt":
            copy_windows_runtime_dlls(dict(os.environ), runtime)
        self.assertTrue(all(path.is_file() and path.suffix.lower() == ".dll"
                            for path in runtime.iterdir()))
        environment = dict(os.environ, PATH=str(runtime))
        for name in ("CANGJIE_HOME", "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH",
                     "CANGJIE_STDX_PATH_STATIC", "CANGJIE_STDX_PATH_DYNAMIC", "CJDOC_STDX_PATH"):
            environment.pop(name, None)
        with contextlib.chdir(self.root), mock.patch.dict(os.environ, environment, clear=True):
            for command in ("cjc", "cjpm", "curl", "wget", "node", "python"):
                self.assertIsNone(shutil.which(command, path=environment["PATH"]), command)
            process = subprocess.run([str(self.binary), "query", "--snapshot", str(snapshot),
                                      "--request", "-"], input=json.dumps(request),
                                     cwd=self.root, env=environment, text=True,
                                     capture_output=True, timeout=120)
            self.assertEqual(process.returncode, 0, process.stderr)
            query = json.loads(process.stdout)
            self.assertEqual(query["status"], "ok")
            item = query["result"]["items"][0]
            self.assertIn("::macro:Echo", item["identity"]["symbolId"])
            mcp = McpProcess(self.binary, (snapshot,))
            try:
                mcp.initialize()
                mcp.mark_initialized()
                result = mcp.result("tools/call", {"name": "search",
                                    "arguments": {k: v for k, v in request.items() if k != "operation"}})
                self.assertFalse(result["isError"])
                self.assertEqual(result["structuredContent"], query)
            finally:
                self.assertEqual(mcp.close(), 0)


if __name__ == "__main__":
    unittest.main()
