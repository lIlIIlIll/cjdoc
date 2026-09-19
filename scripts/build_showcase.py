#!/usr/bin/env python3
"""Build the static GitHub Pages showcase from generated cjdoc artifacts."""

from __future__ import annotations

import argparse
import html
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


FORMATS = ("html", "json", "markdown", "api-surface", "coverage", "symbol-index")


def run(command: list[str], cwd: Path) -> None:
    rendered = " ".join(command)
    print(f"+ {rendered}", flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(f"showcase input is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_tree(source: Path, destination: Path) -> None:
    if not source.is_dir():
        raise FileNotFoundError(f"showcase directory is missing: {source}")
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)


def generate(
    binary: Path,
    project: Path,
    output: Path,
    *,
    locale: str,
    doc_version: str,
    repository_url: str | None = None,
    repository_revision: str | None = None,
    repository_root: Path | None = None,
    doctest: bool = False,
) -> None:
    if output.exists():
        shutil.rmtree(output)
    command = [str(binary), "generate", "--project", str(project)]
    for format_name in FORMATS:
        if format_name == "symbol-index" and not doctest:
            command.extend(("--format", format_name))
        elif format_name != "symbol-index":
            command.extend(("--format", format_name))
    command.extend(
        (
            "--output", str(output),
            "--locale", locale,
            "--doc-version", doc_version,
            "--agent-full",
            "--no-cache",
        )
    )
    if repository_url is not None:
        command.extend(("--repository-url", repository_url))
        command.extend(("--repository-revision", repository_revision or ""))
        command.extend(("--repository-root", str(repository_root or project)))
    run(command, cwd=project)


def write_schema_index(schema_root: Path) -> None:
    names = sorted(path.name for path in schema_root.glob("*.json"))
    links = "\n".join(
        f'      <li><a href="{html.escape(name)}"><code>{html.escape(name)}</code></a></li>'
        for name in names
    )
    content = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>cjdoc schemas</title>
  <style>
    :root {{ color-scheme: light dark; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
    body {{ max-width: 72rem; margin: 0 auto; padding: 3rem 1.5rem; line-height: 1.7; background: Canvas; color: CanvasText; }}
    a {{ color: LinkText; }}
    li {{ margin: .35rem 0; }}
  </style>
</head>
<body>
  <p><a href="../index.html">← cjdoc showcase</a></p>
  <h1>Schema registry</h1>
  <p>Frozen and current JSON contracts emitted by cjdoc.</p>
  <ul>
{links}
  </ul>
</body>
</html>
"""
    (schema_root / "index.html").write_text(content, encoding="utf-8")


def resolve_revision(repo: Path, requested: str | None) -> str:
    if requested:
        return requested
    environment_revision = os.environ.get("GITHUB_SHA")
    if environment_revision:
        return environment_revision
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
    )
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--project", type=Path, default=Path("."))
    parser.add_argument("--repository-url", default=None)
    parser.add_argument("--revision", default=None)
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    binary = args.binary if args.binary.is_absolute() else repo / args.binary
    project = args.project if args.project.is_absolute() else repo / args.project
    output = args.output if args.output.is_absolute() else repo / args.output
    repository_url = args.repository_url or (
        f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}"
        f"/{os.environ.get('GITHUB_REPOSITORY', 'lIlIIlIll/cjdoc')}"
    )
    revision = resolve_revision(repo, args.revision)

    if output.exists():
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="cjdoc-showcase-", dir=output.parent) as temporary:
        work = Path(temporary)
        current = work / "current"
        current_repository_url = repository_url if project == repo else None
        generate(
            binary,
            project,
            current,
            locale="en",
            doc_version="main",
            repository_url=current_repository_url,
            repository_revision=revision,
            repository_root=project,
        )

        demo_project = work / "workspace-demo"
        copy_tree(repo / "tests/fixtures/projects/html_reference", demo_project)
        (demo_project / "cjdoc.toml").write_text(
            "[doctest]\nmode = \"warn\"\ntimeout-ms = 2000\nmemory-mb = 2048\njobs = 1\n\n[docs]\nindex = \"docs/index.md\"\n\n[[docs.pages]]\nsource = \"docs/guide.md\"\nroute = \"concepts/guides/getting-started\"\ntitle = \"Getting started\"\n",
            encoding="utf-8",
        )
        demo = work / "demo"
        generate(
            binary,
            demo_project,
            demo,
            locale="en",
            doc_version="demo",
            doctest=True,
        )

        static_source = repo / "site"
        copy_tree(static_source, output)
        pages_name = repository_url.rstrip("/").rsplit("/", 1)[-1]
        pages_base = f"/{pages_name}/"
        not_found = output / "404.html"
        not_found.write_text(
            not_found.read_text(encoding="utf-8").replace("__PAGES_BASE__", pages_base),
            encoding="utf-8",
        )
        copy_tree(current / "html", output / "api")
        copy_tree(current / "markdown", output / "markdown")
        copy_tree(demo / "html", output / "demo")

        artifacts = output / "artifacts"
        artifact_sources = {
            "docs.json": current / "docs.json",
            "api-surface.json": current / "api-surface/api-surface.json",
            "coverage.json": current / "coverage/coverage.json",
            "navigation-index.json": current / "html/navigation-index.json",
            "symbol-index.json": current / "html/symbol-index.json",
            "search-index.json": current / "html/search-index.json",
            "llms.txt": current / "html/llms.txt",
            "llms-full.txt": current / "html/llms-full.txt",
            "demo-docs.json": demo / "docs.json",
            "doctest-results.json": demo / "doctest/results.json",
        }
        for name, source in artifact_sources.items():
            copy_file(source, artifacts / name)

        schema_root = output / "schemas"
        copy_tree(repo / "docs/schema", schema_root)
        write_schema_index(schema_root)

        docs_root = output / "docs"
        docs_root.mkdir(parents=True, exist_ok=True)
        for name in ("usage.md", "advanced-usage.md", "release-process.md"):
            copy_file(repo / "docs" / name, docs_root / name)

        metadata = {
            "schemaVersion": "cjdoc.showcase/1",
            "source": {"repository": repository_url, "revision": revision},
            "surfaces": ["api", "demo", "markdown", "artifacts", "schemas"],
            "currentDocIr": "cjdoc.doc-ir/10",
            "demo": {"workspace": "two packages", "doctest": "warn"},
        }
        (output / "build.json").write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        run([sys.executable, str(repo / "scripts/validate_html_site.py"), str(output / "api")], repo)
        run([sys.executable, str(repo / "scripts/validate_html_site.py"), str(output / "demo")], repo)

    required = (
        output / "index.html",
        output / "api/index.html",
        output / "demo/index.html",
        output / "artifacts/docs.json",
        output / "artifacts/doctest-results.json",
        output / "schemas/doc-ir-v10.schema.json",
        output / "build.json",
    )
    missing = [str(path.relative_to(output)) for path in required if not path.is_file()]
    if missing:
        raise SystemExit(f"showcase output is incomplete: {', '.join(missing)}")
    print(f"showcase built at {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
