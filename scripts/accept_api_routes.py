#!/usr/bin/env python3
"""Accept canonical API route stability and page heading tiers from real CLI output.

Generate real sites before extensions, with existing extensions, and after
adding an earlier block and another member. The check proves:

* every base page path still exists in the extended site with the same
  canonical address (listings legitimately gain the new extension entries);
* the type page and its members keep `<package>/Counter/...` directories;
* ordinary extension blocks own `<type>/extensions/` (and `extensions/2/`);
* types near the path limit retain their addresses and still publish extensions;
* readable `signature-<n>/` URLs still resolve to the same declarations when
  inserting an extension moves only one source offset across a decimal digit boundary;
* an overload choice that fits alone stays in place; even when its whole family
  needs compact paths, both real signature links stay readable and stable;
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
from urllib.parse import urljoin

ROUTES = "route_check"
NESTED_EXTENSION_TYPE = "Medium" + "T" * 54
COMPACT_EXTENSION_TYPE = "Large" + "T" * 86
EARLIER_COMPACT_TYPE = "Large" + "T" * 81 + "First"
# route_check/<name>/index.html fits exactly for Bounded, but not for Oversize.
LONG_OVERLOADS = (("Bounded" + "X" * 86, "Bounded", True),
                  ("Oversize" + "X" * 109, "Oversize", False))
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
 * Primary details.
 *
 * ### Usage
 *
 * A subsection of Details.
 *
 * ## Notes
 *
 * A peer of Details, not a subsection.
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

EXTENSION_PREFIX = """
extend Counter {
    public func increment(): Unit { value += 1 }
    /** Calibrate from text. */
    public func calibrate(value: String): String { value }
}
"""
EXISTING_EXTENSIONS = """

/** Existing extension block. */
extend Counter {
    /** Subtract one. */
    public func decrement(): Unit {
        value -= 1
    }

    /** Calibrate from a number. */
    public func calibrate(value: Int64): Int64 { value }
}
"""

BASE_SOURCE += "\npublic class Occupied { public func extensions(): Int64 { 0 } }\n"
BASE_SOURCE += "\npublic class Neighbor {}\n"
COLLIDING_EXTENSION = "\nextend Occupied {{ public func keep(): Int64 {{ 1 }}{extra} }}\n"
SHARED_OVERLOAD_PREFIX = "commonVeryLongOverloadPrefix" + "X" * 70
PRIOR_OVERLOAD = (SHARED_OVERLOAD_PREFIX + "Old", "Existing extension", False)
SHARED_ENDS = "overlap" + "L" * 56, "R" * 53 + "end"
PRIOR_MIDDLE = (f"{SHARED_ENDS[0]}Before{SHARED_ENDS[1]}", "Established middle", False)


def overload_source(name: str, label: str) -> str:
    return (f"\n/** {label} numeric overload. */\n"
            f"public func {name}(value: Int64): Int64 {{ value }}\n"
            f"/** {label} text overload. */\n"
            f"public func {name}(value: String): String {{ value }}\n")


def overload_extension(name: str, label: str, target: str = "Counter") -> str:
    return f"\nextend {target} {{\n" + overload_source(name, label) + "}\n"


EXISTING_OVERLOAD_EXTENSION = (overload_extension(*PRIOR_OVERLOAD[:2])
                               + overload_extension(*PRIOR_MIDDLE[:2]))
EARLIER_OVERLOAD_EXTENSIONS = (
    overload_extension(SHARED_OVERLOAD_PREFIX + "New", "New extension")
    + overload_extension(PRIOR_OVERLOAD[0], "Unrelated extension", target="Neighbor")
    + overload_extension(f"{SHARED_ENDS[0]}After{SHARED_ENDS[1]}", "Different middle")
)
for name in (NESTED_EXTENSION_TYPE, COMPACT_EXTENSION_TYPE, EARLIER_COMPACT_TYPE):
    BASE_SOURCE += f"\npublic class {name} {{ public func v(): Int64 {{ 0 }} }}\n"
NESTED_EXTENSION = f"\nextend {NESTED_EXTENSION_TYPE} {{ public func w(): Int64 {{ 1 }} }}\n"
EXISTING_COMPACT_EXTENSION = (f"\n/** Established compact extension. */\nextend {COMPACT_EXTENSION_TYPE}"
                             " { public func w(): Int64 { 1 } }\n")
EARLIER_COMPACT_EXTENSION = (f"\n/** Earlier compact extension. */\nextend {EARLIER_COMPACT_TYPE}"
                            " { public func w(): Int64 { 1 } }\n")
for name, label, _ in LONG_OVERLOADS:
    BASE_SOURCE += overload_source(name, label)

# Place the second overload just below byte 1000. Only the second overload
# crosses 1000 when the first extension is inserted before the type.
PACKAGE_LINE, BODY = BASE_SOURCE.split("\n", 1)
PADDING = "//" + " " * (980 - BASE_SOURCE.index("public func set(text: String)") - 3) + "\n"
BASE_SOURCE = PACKAGE_LINE + "\n" + PADDING + BODY
EXISTING_SOURCE = (BASE_SOURCE + EXISTING_EXTENSIONS + EXISTING_OVERLOAD_EXTENSION
                   + COLLIDING_EXTENSION.format(extra="") + EXISTING_COMPACT_EXTENSION)
EXTEND_SOURCE = (PACKAGE_LINE + "\n" + EXTENSION_PREFIX + PADDING + BODY + EXISTING_EXTENSIONS
                 + EARLIER_OVERLOAD_EXTENSIONS + EXISTING_OVERLOAD_EXTENSION
                 + COLLIDING_EXTENSION.format(extra="\n    public func added(): Int64 { 2 }\n")
                 + NESTED_EXTENSION + EARLIER_COMPACT_EXTENSION + EXISTING_COMPACT_EXTENSION)

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
MAIN_CONTENT = re.compile(r'<main\b[^>]*\bid="cjdoc-main"[^>]*>(.*?)</main>', re.DOTALL)
SYMBOL_PAGE = re.compile(r'<body\b[^>]*\bdata-cjdoc-symbol-id="([^"]+)"')
API_LINK = re.compile(r'<a\b[^>]*\bhref="([^"]+)"[^>]*\bdata-cjdoc-api-link(?=[ >])')


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


def main_content(page: str) -> str:
    body = MAIN_CONTENT.search(page)
    return body[1] if body else ""


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def check_long_overloads(base: dict[str, str], extended: dict[str, str],
                         failures: list[str],
                         families: tuple[tuple[str, str, bool], ...] = LONG_OVERLOADS,
                         *, typed_signatures: bool = False) -> None:
    for name, label, fits in families:
        choices = [path for path, page in base.items()
                   if 'data-cjdoc-route="api-choice"' in page and name in main_content(page)]
        if len(choices) != 1:
            failures.append(f"{label} overload must have one choice page: {choices}")
            continue
        choice = choices[0]
        if fits:
            require(choice == f"{ROUTES}/{name}/index.html",
                    f"length alone moved the fitting choice page: {choice}", failures)
        require(name in main_content(extended.get(choice, "")),
                f"{label} lost its choice page after adding an extension: {choice}", failures)
        links = API_LINK.findall(main_content(base[choice]))
        after_links = API_LINK.findall(main_content(extended.get(choice, "")))
        require(len(links) == 2 and links == after_links,
                f"{label} overload destinations changed after adding extensions: {links} → {after_links}",
                failures)
        for ordinal, (href, kind) in enumerate(zip(links, ("numeric", "text")), 1):
            target = urljoin(f"/{choice}", href).lstrip("/")
            before, after = (site.get(target, "") for site in (base, extended))
            ids = SYMBOL_PAGE.findall(before)
            suffix = ("Int64", "String")[ordinal - 1] if typed_signatures else str(ordinal)
            require(target.endswith(f"/signature-{suffix}/index.html") and
                    len(ids) == 1 and ids == SYMBOL_PAGE.findall(after) and
                    all(f"{label} {kind} overload." in main_content(page) for page in (before, after)),
                    f"{href} does not point to a stable readable {label} {kind} signature", failures)


def accept(binary: Path, repo: Path, workdir: Path) -> int:
    root = workdir.resolve()
    root.mkdir(parents=True, exist_ok=False)
    work = root / "work"
    work.mkdir()

    base_project = write_project(work / "projects" / "base", BASE_SOURCE)
    existing_project = write_project(work / "projects" / "existing", EXISTING_SOURCE)
    extend_project = write_project(work / "projects" / "extended", EXTEND_SOURCE)
    base_html = generate(binary, repo, base_project, work / "base-site", work)
    existing_html = generate(binary, repo, existing_project, work / "existing-site", work)
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
    nested = f"{ROUTES}/{NESTED_EXTENSION_TYPE}"
    compact = f"{ROUTES}/{COMPACT_EXTENSION_TYPE}"
    for name in (nested, compact):
        require(f"{name}/v" in canonical and f"{name}/v" in extended,
                f"adding an extension moved an existing member near the path limit: {name}",
                failures)
        page_path = f"{name}/index.html"
        page = main_content(extend_pages.get(page_path, ""))
        member_links = (urljoin(f"/{page_path}", href).lstrip("/")
                        for href in re.findall(r'href="([^"]+)"', page))
        require('data-member-name="w"' in page and any(
            target.endswith("/w/signature-no-args/index.html") and target in extend_pages
            and SYMBOL_PAGE.search(extend_pages[target]) for target in member_links),
            f"the type page does not open the added extension member: {name}", failures)
    require(f"{nested}/extensions" in extended, "missing readable long-type extension", failures)
    for path in ("get", "increment/signature-no-args", "decrement/signature-no-args"):
        require(f"{ROUTES}/Counter/{path}" in extended, f"missing readable member route for {path}", failures)
    existing_pages = page_paths(existing_html)
    existing = directories(existing_pages)
    compact_paths = [route for route, page in existing.items() if route.startswith("~api/extensions/")
                     and "Established compact extension." in main_content(page)]
    require(len(compact_paths) == 1, f"expected a compact extension route: {compact_paths}", failures)
    for route in compact_paths:
        before, after = existing[route], extended.get(route, "")
        ids = SYMBOL_PAGE.findall(before)
        require(len(ids) == 1 and ids == SYMBOL_PAGE.findall(after)
                and "Established compact extension." in main_content(after),
                f"an unrelated earlier extension reassigned {route}", failures)
    require(any(route.startswith("~api/extensions/") and
                "Earlier compact extension." in main_content(page) for route, page in extended.items()),
            "the earlier compact extension was not published", failures)
    survivor = f"{ROUTES}/Counter/decrement/signature-no-args"
    require(all("Subtract one." in main_content(site.get(survivor, ""))
                for site in (existing, extended)),
            "inserting an earlier extension moved an existing member", failures)
    new_choice = f"{ROUTES}/Counter/calibrate"
    numeric = f"{new_choice}/signature-Int64"
    choice_links = API_LINK.findall(main_content(extended.get(new_choice, "")))
    candidates = {urljoin(f"/{new_choice}/index.html", link).lstrip("/") for link in choice_links}
    require(candidates == {f"{numeric}/index.html", f"{new_choice}/signature-String/index.html"}
            and all(path in extend_pages for path in candidates)
            and all("Calibrate from a number." in main_content(site.get(numeric, ""))
                    for site in (existing, extended)),
            "adding a same-target overload replaced the existing signature or lost a choice", failures)
    collision_stem = f"{ROUTES}/Occupied/extensions~"
    collision_before = [route for route in existing if route.startswith(collision_stem)]
    collision_after = [route for route in extended if route.startswith(collision_stem)]
    require(len(collision_before) == 1 and collision_before == collision_after,
            "adding a member changed its block's real collision fallback", failures)
    require(f"{ROUTES}/Occupied/extensions" in extended
            and f"{ROUTES}/Occupied/added/signature-no-args" in extended,
            "the colliding block must keep the ordinary member and publish the added extension member",
            failures)

    signatures = sorted(route for route in extend_routes if "/set/signature-" in route)
    require(signatures == [f"{ROUTES}/Counter/set/signature-1", f"{ROUTES}/Counter/set/signature-2"],
            f"overload signature directories are {signatures}", failures)
    require(f"{ROUTES}/Counter/set" in extend_routes,
            "missing overload selection page", failures)
    for ordinal, summary in enumerate(("Set a numeric value.", "Set a textual value."), 1):
        route = f"{ROUTES}/Counter/set/signature-{ordinal}"
        before, after = (site.get(route, "") for site in (canonical, extended))
        identifiers = SYMBOL_PAGE.findall(before), SYMBOL_PAGE.findall(after)
        require(len(identifiers[0]) == 1 and identifiers[0] == identifiers[1] and
                all(summary in main_content(page) for page in (before, after)),
                f"{route} no longer resolves to its original declaration: {summary}", failures)
    check_long_overloads(base_pages, extend_pages, failures)
    check_long_overloads(existing_pages, extend_pages, failures, (PRIOR_OVERLOAD, PRIOR_MIDDLE),
                         typed_signatures=True)

    # A portable fallback is a `~<hex>` segment, whether it replaces a whole
    # name or is appended after a readable stem (`Sketch~<hex>`).
    opaque = sorted(route for route in extend_routes
                    if re.search(r"~[0-9a-f]{12,}(?:/|$)", route))
    require(all(route.startswith((f"{ROUTES}/Sketch~", f"{ROUTES}/sketch~", collision_stem))
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
                        if path.startswith(f"{ROUTES}/greet/signature-")
                        and ">Details</h2>" in extend_pages[path]), "")
    require(bool(greet_route), "missing the standalone authored section", failures)
    if greet_route:
        greet = extend_pages[greet_route]
        require(">Notes</h2>" in greet and ">Usage</h3>" in greet,
                "standalone authored siblings and child did not retain their headings", failures)

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
