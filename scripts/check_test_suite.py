#!/usr/bin/env python3
"""Audit the Python test suite's layout and the modules a gate may collect.

Two defects this refuses, both of which stayed invisible because CI collects with
`-m unittest` while a developer runs a file directly:

* **A `unittest.main()` block in the middle of a file.** Everything defined after it
  is never collected when the file is executed, so a local run reported "OK" with
  fewer cases than CI ran. A module's main block must therefore be its last
  statement.
* **A module collected as a passing suite that asserts nothing.** A file with no
  `TestCase` counted as one more green module while contributing zero checks, so
  "modules collected" stopped meaning anything. A module is collectable only if it
  declares real test methods; anything else must be a driver that a stage script
  actually runs by name -- otherwise nothing runs it at all.

`--print-modules` emits exactly the modules a stage should pass to
`python -m unittest`, which is what makes the second rule enforceable instead of
advisory: the shell gate globs `test_*.py`, so the list it needs is derived here.
"""

from __future__ import annotations

import argparse
import ast
from pathlib import Path
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
# Directories whose `test_*.py` files the python-tools stage owns. The showcase
# suite is discovered by path; the script suite is collected by module name.
MODULE_DIRS = ("scripts", "tests/showcase_contract")
# Files that decide what the gate runs. A driver module is legitimate when one of
# these names it, because then a stage executes it explicitly.
GATE_SOURCES = ("scripts/check.sh", "scripts/check_cli.sh")
# Modules the preflight stage already runs, so the python-tools list does not repeat
# them (which would make the same SDK tests run twice per job).
PREFLIGHT_MODULES = frozenset({"test_install_cangjie_sdk.py", "test_with_stdx.py"})


def test_files(root: Path = ROOT) -> list[Path]:
    """Every `test_*.py` the python-tools stage is responsible for, sorted."""
    found: list[Path] = []
    for directory in MODULE_DIRS:
        found += sorted((root / directory).glob("test_*.py"))
    return found


def main_guard_position(tree: ast.Module) -> int | None:
    """Index in `tree.body` of the `if __name__ == "__main__":` block, if any."""
    for index, node in enumerate(tree.body):
        if isinstance(node, ast.If) and "__name__" in ast.unparse(node.test):
            return index
    return None


def trailing_definitions(tree: ast.Module) -> list[str]:
    """Classes and functions defined after the module's main guard."""
    position = main_guard_position(tree)
    if position is None:
        return []
    return [node.name for node in tree.body[position + 1:]
            if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef))]


def declared_tests(tree: ast.Module) -> int:
    """Test methods a collector would really run.

    Only `TestCase` subclasses count, and only their `test*` methods: a module-level
    helper named `test_something` is not a test, and a fixture base class such as
    `CaptureTestCase` declares setup for its children rather than cases of its own.
    A module whose own `setUpModule` skips keeps its declared tests -- an optional
    suite that is skipped without its input is not an empty one, and forcing it to
    run would only make the gate depend on an unavailable toolchain.
    """
    return sum(
        1
        for node in ast.walk(tree)
        if isinstance(node, ast.ClassDef)
        and any("TestCase" in ast.unparse(base) for base in node.bases)
        for item in node.body
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
        and item.name.startswith("test")
    )


def gate_text(root: Path = ROOT) -> str:
    return "\n".join((root / name).read_text(encoding="utf-8")
                     for name in GATE_SOURCES if (root / name).is_file())


def is_invoked(name: str, text: str) -> bool:
    """True when a gate script names this module or file, i.e. runs it itself."""
    return f"{name}.py" in text


def is_shared_helper(name: str, root: Path = ROOT) -> bool:
    """True when another test module imports this one, i.e. it is a helper library.

    `test_search_semantics.py` is imported by `test_query_mcp.py` rather than run:
    it is support code that happens to live under a `test_` name, not a suite that
    pretends to pass. It is still kept out of the collected module list.
    """
    for path in test_files(root):
        if path.stem == name:
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=path.name)
        for node in ast.walk(tree):
            if isinstance(node, ast.Import) and any(alias.name.split(".")[-1] == name
                                                    for alias in node.names):
                return True
            if isinstance(node, ast.ImportFrom):
                if (node.module or "").split(".")[-1] == name:
                    return True
                if any(alias.name == name for alias in node.names):
                    return True
    return False


def audit(root: Path = ROOT) -> list[str]:
    """Structural problems, in a form a failing assertion can name individually."""
    problems: list[str] = []
    text = gate_text(root)
    for path in test_files(root):
        relative = path.relative_to(root).as_posix()
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=relative)
        trailing = trailing_definitions(tree)
        if trailing:
            problems.append(f"{relative}: defined after `if __name__ == \"__main__\"`: "
                            f"{', '.join(trailing)}; that code never runs when the file is "
                            "executed directly")
        tests = declared_tests(tree)
        if tests:
            continue
        # Not a unittest suite. It is only acceptable as support code: a driver a
        # stage runs by name, or a helper another test module imports. Otherwise the
        # collection list counts it as a passing module that asserts nothing.
        if not is_invoked(path.stem, text) and not is_shared_helper(path.stem, root):
            problems.append(f"{relative}: declares no test cases and no stage runs it; "
                            "collecting it reports zero assertions as a pass")
    return problems


def collectable_modules(root: Path = ROOT) -> list[str]:
    """`scripts.test_*` names that really declare test cases.

    Preflight already runs its own two SDK modules, so they are not repeated here:
    the list is exactly what the python-tools stage should collect.
    """
    names: list[str] = []
    for path in sorted((root / "scripts").glob("test_*.py")):
        if path.name in PREFLIGHT_MODULES:
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=path.name)
        if declared_tests(tree):
            names.append(f"scripts.{path.stem}")
    return names


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--print-modules", action="store_true",
                        help="print the `scripts.test_*` modules a stage should collect")
    parser.add_argument("--repo", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    if args.print_modules:
        print(" ".join(collectable_modules(args.repo)))
        return 0
    problems = audit(args.repo)
    for problem in problems:
        print(f"test suite: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
