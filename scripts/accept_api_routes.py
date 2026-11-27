#!/usr/bin/env python3
"""Accept canonical API route stability and page heading tiers from real CLI output.

Two projects with identical sources except for `extend Counter` blocks are
generated with the real cjdoc binary. The check proves:

* every base page path still exists in the extended site with the same
  canonical address (listings legitimately gain the new extension entries);
* the type page and its members keep `<package>/Counter/...` directories;
* extension blocks own `<package>/Counter/extensions/` (and `extensions/2/`);
* overload signatures use readable `signature-<n>/` directories;
* an opaque `~<hex>` segment appears only for a genuine portable collision;
* every generated page has exactly one h1 and never skips a heading level.

Nothing inside the repository is written: both projects, their build trees and
the generated sites live under a new --workdir.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROUTES = "route_check"
BASE_SOURCE = """package route_check

/** A counter. */
public class Counter {
    /** Current value. */
    public var value: Int64 = 0

    /** Create a counter. */
    public init(value: Int64) {
        this.value = value
    }

    /** Read the value. */
    public func get(): Int64 {
        value
    }

    /**
     * Set a numeric value.
     * @param next new value
     */
    public func set(next: Int64): Unit {
        value = next
    }

    /**
     * Set a textual value.
     * @param text new text
     */
    public func set(text: String): Unit {
        value = Int64(text.size)
    }
}

/** Distinct spellings that only differ by case. */
public class Sketch {}

/** Second portable-collision spelling. */
public class sketch {}

/**
 * A documented standalone function.
 *
 * ## Details
 *
 * The authored heading must stay below a real parent section.
 *
 * @return the input
 * @see route_check.greet(Int64)
 */
public func greet(value: Int64): Int64 {
    value
}

/** Greet an Int64. */
public func greet(value: Int64, loud!: Bool): Int64 {
    value
}
"""

EXTENSION_SUFFIX = """
/** First extension block. */
extend Counter {
    /** Add one. */
    public func increment(): Unit {
        value += 1
    }
}

/** Second extension block. */
extend Counter {
    /** Subtract one. */
    public func decrement(): Unit {
        value -= 1
    }
}
"""

PACKAGE_MANIFEST = """[package]
  cjc-version = "1.2.0"
  name = "route_check"
  version = "0.1.0"
  output-type = "static"

[dependencies]
"""


def write_project(root: Path, source: str) -> Path:
    (root / "src").mkdir(parents=True, exist_ok=True)
    (root / "cjpm.toml").write_text(PACKAGE_MANIFEST, encoding="utf-8")
    (root / "src/api.cj").write_text(source, encoding="utf-8")
    return root


def generate(binary: Path, repo: Path, project: Path, site: Path, work: Path) -> Path:
    environment = {**os.environ, "TMPDIR": str(work), "TMP": str(work), "TEMP": str(work)}
    command = [str(binary), "generate", "--project", str(project),
               "--semantic", "source", "--no-cache", "--format", "html", "--output", str(site)]
    result = subprocess.run(command, text=True, capture_output=True, cwd=str(repo), env=environment)
    html = site / "html"
    if result.returncode != 0 or not html.is_dir():
        details = (result.stderr or result.stdout)[-1200:]
        for value, label in ((str(project), "<project>"), (str(site), "<site>"),
                             (str(repo), "<repo>"), (str(binary), "<binary>"),
                             (str(Path.home()), "$HOME")):
            details = details.replace(value, label)
        raise ValueError(f"generating {project.name} failed: {details}")
    return html


def page_paths(html: Path) -> dict[str, str]:
    paths: dict[str, str] = {}
    for page in sorted(html.rglob("*.html")):
        paths[page.relative_to(html).as_posix()] = page.read_text(encoding="utf-8")
    return paths


HEADING = re.compile(r"<h([1-6])(?=[ >])")
H1 = re.compile(r"<h1(?=[ >])")
CANONICAL = re.compile(r'<link rel="canonical" href="([^"]+)"')


def check_headings(page: str, text: str, failures: list[str]) -> None:
    levels = [int(level) for level in HEADING.findall(text)]
    found_h1 = len(H1.findall(text))
    if found_h1 != 1:
        failures.append(f"{page}: expected exactly one h1, found {found_h1}")
    if not levels:
        return
    if levels[0] not in (1, 2):
        failures.append(f"{page}: page starts at h{levels[0]}")
    previous = 0
    for level in levels:
        if previous and level > previous + 1:
            failures.append(f"{page}: heading level skips from h{previous} to h{level}")
            break
        previous = level


def directories(paths: dict[str, str]) -> dict[str, str]:
    """Map each file's directory (without index.html) to that file's text."""
    return {path.rsplit("/", 1)[0]: text for path, text in paths.items()
            if path.endswith("/index.html")}


def route_directories(html: Path) -> list[str]:
    return sorted(path.relative_to(html).as_posix().rsplit("/", 1)[0]
                  for path in html.rglob("index.html"))


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def accept(binary: Path, repo: Path, workdir: Path) -> int:
    root = workdir.resolve()
    root.mkdir(parents=True, exist_ok=False)
    work = root / "work"
    work.mkdir()

    base_project = write_project(work / "projects" / "base", BASE_SOURCE)
    extend_project = write_project(work / "projects" / "extended",
                                   BASE_SOURCE + EXTENSION_SUFFIX)
    base_html = generate(binary, repo, base_project, work / "base-site", work)
    extend_html = generate(binary, repo, extend_project, work / "extended-site", work)

    failures: list[str] = []
    base_pages = page_paths(base_html)
    extend_pages = page_paths(extend_html)
    # Every published address survives unchanged. Page bodies may list the new
    # declarations (sidebar, package page, home), so the stable unit is the
    # route and its canonical address rather than the whole body.
    for path in base_pages:
        require(path in extend_pages, f"adding an extension removed {path}", failures)
    for path, text in base_pages.items():
        before_canonical = CANONICAL.findall(text)
        after_canonical = CANONICAL.findall(extend_pages.get(path, ""))
        require(before_canonical == after_canonical,
                f"adding an extension changed the canonical address of {path}", failures)

    base_routes = route_directories(base_html)
    extend_routes = set(route_directories(extend_html))
    for route in base_routes:
        require(route in extend_routes, f"adding an extension removed route {route}", failures)

    canonical = {route: text for route, text in directories(base_pages).items()}
    require(f"{ROUTES}/Counter" in canonical, "missing canonical type route", failures)
    require(f"{ROUTES}/Sketch" not in canonical and f"{ROUTES}/sketch" not in canonical,
            "case-only class names must not claim a bare route", failures)
    if f"{ROUTES}/Counter" in canonical:
        urls = CANONICAL.findall(canonical[f"{ROUTES}/Counter"])
        require(bool(urls) and urls[0].endswith(f"/{ROUTES}/Counter/"),
                f"type page canonical address is not its directory: {urls}", failures)
        require("data-member-name=\"get\"" in canonical[f"{ROUTES}/Counter"],
                "type page no longer lists its own member", failures)
        require("data-member-name=\"set\"" in canonical[f"{ROUTES}/Counter"],
                "type page no longer lists its declared member", failures)
        require('data-cjdoc-route="api"' in canonical[f"{ROUTES}/Counter"],
                "type page must be a symbol body, not an alias", failures)

    extended = directories(extend_pages)
    for route, label in ((f"{ROUTES}/Counter/extensions", "first extension block"),
                         (f"{ROUTES}/Counter/extensions/2", "second extension block")):
        require(route in extended, f"missing {label} route {route}", failures)
    require(f"{ROUTES}/Counter" in extended,
            "adding an extension moved the type page", failures)
    require("data-member-name=\"increment\"" in extend_pages.get(
        f"{ROUTES}/Counter/index.html", ""),
            "type page no longer lists its extension members", failures)
    for member in ("get", "increment", "decrement"):
        require(f"{ROUTES}/Counter/{member}" in extended
                or any(route.startswith(f"{ROUTES}/Counter/extensions/{member}")
                       or route.startswith(f"{ROUTES}/Counter/extensions/2/{member}")
                       for route in extend_routes),
                f"missing member route for {member}", failures)

    signatures = sorted(route for route in extend_routes if "/set/signature-" in route)
    require(signatures == [f"{ROUTES}/Counter/set/signature-1", f"{ROUTES}/Counter/set/signature-2"],
            f"overload signature directories are {signatures}", failures)
    require(f"{ROUTES}/Counter/set" in extend_routes,
            "missing overload selection page", failures)

    # A portable fallback is a `~<hex>` segment, whether it replaces a whole
    # name or is appended after a readable stem (`Sketch~<hex>`).
    opaque = sorted(route for route in extend_routes
                    if re.search(r"(^|/)~[0-9a-f]{12,}(/|$)|~[0-9a-f]{12,}$", route))
    require(all(route.startswith((f"{ROUTES}/Sketch~", f"{ROUTES}/sketch~"))
                for route in opaque),
            f"opaque route segment outside a real portable collision: {opaque}", failures)
    require(any(route.startswith(f"{ROUTES}/Sketch~") for route in opaque) and
            any(route.startswith(f"{ROUTES}/sketch~") for route in opaque),
            "case-only collision did not fall back to a suffixed route", failures)

    for path, text in base_pages.items():
        check_headings(path, text, failures)
    for path, text in extend_pages.items():
        check_headings(path, text, failures)
    greet_route = next((path for path in extend_pages
                        if path.startswith(f"{ROUTES}/greet/signature-")), "")
    if greet_route:
        greet = extend_pages[greet_route]
        require(">Details</h2>" in greet,
                "authored '## Details' did not render as a section heading", failures)

    if failures:
        for failure in failures[:40]:
            print(f"FAIL: {failure}", file=sys.stderr)
        print(f"{len(failures)} API route acceptance failures", file=sys.stderr)
        return 1
    print(f"accepted {len(base_pages)} base pages, {len(extend_pages)} extended pages")
    print("extension routes:", ", ".join(route for route in sorted(extend_routes)
                                         if "/extensions" in route))
    print("overload routes:", ", ".join(signatures))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, default=Path("target/release/bin/main"))
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--workdir", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    repo = args.repo.resolve(strict=True)
    return accept(binary, repo, args.workdir)


if __name__ == "__main__":
    sys.exit(main())
