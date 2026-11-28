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
  actually runs by name -- otherwise nothing runs it at all. Declarations are read
  where `unittest` looks for them, module scope: a `TestCase` written inside a
  function, inside another class, or inside the `__main__` guard binds nothing
  a collector can see, so it is not a test case.

`--print-modules` lists the static candidates. The gate uses `--run-registered`,
which loads and runs those modules and the showcase discovery suite, rejecting
any selected module that contributes no tests after import.
"""

from __future__ import annotations

import argparse
import ast
from pathlib import Path
import sys
from types import ModuleType
import unittest

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


def _is_main_or_typing(test: ast.expr) -> bool:
    """True for `__name__ == "__main__"` and `TYPE_CHECKING` guards."""
    if isinstance(test, ast.Name):
        return test.id == "TYPE_CHECKING"
    if not isinstance(test, ast.Compare) or len(test.ops) != 1:
        return False
    left, comparator = test.left, test.comparators[0]
    if not (isinstance(left, ast.Name) and left.id == "__name__"):
        return False
    if isinstance(test.ops[0], ast.Eq):
        return isinstance(comparator, ast.Constant) and comparator.value == "__main__"
    if isinstance(test.ops[0], ast.In) and isinstance(comparator, (ast.Tuple, ast.List, ast.Set)):
        return any(isinstance(element, ast.Constant) and element.value == "__main__"
                   for element in comparator.elts)
    return False


def module_scope(body: list[ast.stmt]) -> list[ast.ClassDef]:
    """Classes that can bind at module import, excluding main and typing guards.

    Do not attempt to predict which platform-dependent branch executes. The
    acceptance runner separately checks the real unittest collection.
    """
    classes: list[ast.ClassDef] = []
    for node in body:
        if isinstance(node, ast.If):
            guarded = _is_main_or_typing(node.test)
            classes += module_scope(node.orelse if guarded else node.body)
            if not guarded:
                classes += module_scope(node.orelse)
        elif isinstance(node, (ast.Try, ast.TryStar)):
            blocks = [node.body, node.orelse, node.finalbody]
            blocks += [handler.body for handler in node.handlers]
            for block in blocks:
                classes += module_scope(block)
        elif isinstance(node, (ast.With, ast.AsyncWith)):
            classes += module_scope(node.body)
        elif isinstance(node, (ast.For, ast.AsyncFor, ast.While)):
            # A class created in a module-level loop is bound just like a literal one.
            classes += module_scope(node.body)
            classes += module_scope(node.orelse)
        elif isinstance(node, ast.ClassDef):
            classes.append(node)
    return classes


def declared_tests(tree: ast.Module) -> int:
    """Count declared test candidates, independently of environment-dependent code.

    Only `TestCase` subclasses count, and only their `test*` methods: a module-level
    helper named `test_something` is not a test, and a fixture base class such as
    `CaptureTestCase` declares setup for its children rather than cases of its own.
    A module whose own `setUpModule` skips keeps its declared tests -- an optional
    suite that is skipped without its input is not an empty one, and forcing it to
    run would only make the gate depend on an unavailable toolchain.

    A subclass is recognised through the bases that are resolvable in the same
    module, so `class Cases(CaptureTestCase)` counts while a class nested inside a
    function -- which the loader never reaches -- does not.
    """
    classes = {node.name: node for node in module_scope(tree.body)}

    def is_case(node: ast.ClassDef, seen: frozenset[str]) -> bool:
        for base in node.bases:
            name = ast.unparse(base)
            if name.split(".")[-1] == "TestCase":
                return True
            local = classes.get(name)
            if local is not None and name not in seen and is_case(local, seen | {name}):
                return True
        return False

    return sum(
        sum(1 for item in node.body
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name.startswith("test"))
        for name, node in classes.items()
        if is_case(node, frozenset({name}))
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


class NonEmptyTestLoader(unittest.TestLoader):
    def loadTestsFromModule(self, module: ModuleType, *, pattern: str | None = None) -> unittest.TestSuite:
        tests = super().loadTestsFromModule(module, pattern=pattern)
        path = getattr(module, "__file__", None)
        if path and Path(path).match("test_*.py") and tests.countTestCases() == 0:
            raise SystemExit(f"{module.__name__}: unittest collected no tests")
        return tests


def run_registered(root: Path, group: str) -> int:
    """Load and run a suite once, refusing an empty contributing module."""
    root = root.resolve()
    sys.path[:0] = [str(root), str(root / "scripts")]
    loader = NonEmptyTestLoader()
    if group == "scripts":
        names = collectable_modules(root)
        if not names:
            raise SystemExit("no script unittest modules found")
        tests = loader.loadTestsFromNames(names)
    else:
        tests = loader.discover(str(root / "tests/showcase_contract"), pattern="test_*.py")
        if tests.countTestCases() == 0:
            raise SystemExit("no showcase unittest tests found")
    return 0 if unittest.TextTestRunner().run(tests).wasSuccessful() else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--print-modules", action="store_true",
                        help="print the `scripts.test_*` modules a stage should collect")
    parser.add_argument("--run-registered", choices=("scripts", "showcase"),
                        help="run the actual script and showcase suites, refusing empty modules")
    parser.add_argument("--repo", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    if args.run_registered:
        return run_registered(args.repo, args.run_registered)
    if args.print_modules:
        print(" ".join(collectable_modules(args.repo)))
        return 0
    problems = audit(args.repo)
    for problem in problems:
        print(f"test suite: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
