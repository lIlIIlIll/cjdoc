"""Assemble native CLI outputs without inventing declaration or report semantics."""
from __future__ import annotations

import html
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess

from showcase_contract.contract import check_regressions, resolve_plan
from showcase_contract.offline import create_archive
from showcase_contract.site import ContractError, Site, canonical_json, load_json
from . import homepage, legacy, manifest, navigation, report_pages, reports
from . import stage_timing
from .packaging import copy_sources, source_archive, tool_version
from .parallel import BranchRunner
from publication_ir import project as publication_projection

FORMATS = ("html", "json", "markdown", "api-surface", "coverage", "symbol-index")


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file() or source.is_symlink():
        raise ContractError("missing or unsafe showcase input: " + str(source))
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def generate_api(binary: Path, project: Path, output: Path, provenance: dict, repo: Path,
                 runner=subprocess) -> None:
    command = [str(binary), "generate", "--project", str(project)]
    for name in FORMATS:
        command += ["--format", name]
    command += ["--output", str(output), "--locale", "en", "--doc-version", "main",
                "--agent-full", "--no-cache"]
    if project == repo:
        command += ["--repository-url", provenance["repository"], "--repository-revision",
                    provenance["revision"], "--repository-root", str(project)]
    print("+ " + " ".join(command), flush=True)
    runner.run(command, cwd=repo, check=True)


def reproduce_module(repo: Path):
    path = repo / "examples/pocketkit/reproduce.py"
    spec = importlib.util.spec_from_file_location("pocketkit_reproduce", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def publish_reports(root: Path, provenance: dict, version: str, locale: str, **options) -> None:
    reports.publish(root, provenance["revision"], version, locale, **options)
    report_pages.publish(root)
    reports.verify(root, provenance["revision"])


def publish_examples(result: dict, site: Path, provenance: dict) -> None:
    sources = {generated["composed"] for generated in result["locales"].values()}
    if len(sources) != 1:
        raise ContractError("showcase requires one native bilingual composition")
    composed = site / "examples"
    copy_composed_publication(next(iter(sources)), composed)
    for locale, generated in result["locales"].items():
        roots = {name: composed / root.relative_to(generated["composed"])
                 for name, root in generated["roots"].items()}
        for version, root in roots.items():
            if "checks" in result:
                shutil.copytree(result["checks"], root / "check-modes")
            publish_reports(root, provenance, version, locale,
                            baseline=roots["demo-v1"], current=roots["demo-v2"],
                            diff_path=generated["diff"])
        diagnostics = site / "diagnostics" / locale
        shutil.copytree(generated["diagnostics"] / "html", diagnostics)
        if "checks" in result:
            shutil.copytree(result["checks"], diagnostics / "check-modes")
        publish_reports(diagnostics, provenance, "diagnostics", locale)


def copy_composed_publication(source: Path, destination: Path) -> None:
    """Publish native pages and their public machine views, excluding author IR.

    Native composition also preserves generation intermediates beside html/.
    Those contain the complete author corpus; each reading root already carries
    its audience-filtered machine files and selected Markdown.
    """
    versions = {source / name for name in ("demo-v1", "demo-v2")}

    def ignore(directory: str, names: list[str]) -> list[str]:
        if Path(directory) not in versions:
            return []
        return [name for name in names if name not in {"html", "index.html", "api-diff.json"}]

    shutil.copytree(source, destination, ignore=ignore)


def publish_compatibility(repo: Path, site: Path, current: Path, result: dict) -> None:
    shutil.copytree(current / "html", site / "api")
    shutil.copytree(current / "markdown", site / "markdown")
    demo = result["locales"]["en"]["generated"]["demo-v2"]
    inputs = {"docs.json": current / "docs.json",
              "api-surface.json": current / "api-surface/api-surface.json",
              "coverage.json": current / "coverage/coverage.json",
              "quality.json": current / "coverage/quality.json",
              "api-diff.json": result["locales"]["en"]["diff"],
              "demo-docs.json": demo / "docs.json",
              "native-check.json": result["checks"] / "native-check.json"}
    for name in ("navigation-index.json", "symbol-index.json", "search-index.json", "llms.txt", "llms-full.txt"):
        inputs[name] = current / "html" / name
    for name, path in inputs.items():
        if name in ("docs.json", "demo-docs.json"):
            target = site / "artifacts" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(canonical_json(publication_projection(load_json(path))))
        else:
            copy_file(path, site / "artifacts" / name)
    shutil.copytree(repo / "docs/schema", site / "schemas")
    links = ''.join('<li><a href="' + html.escape(path.name) + '">' + html.escape(path.name) + '</a></li>'
                    for path in sorted((site / "schemas").glob("*.json")))
    (site / "schemas/index.html").write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Schema registry</title></head><body><a href="../index.html">Showcase</a><h1>Schema registry</h1><ul>' + links + '</ul></body></html>', encoding="utf-8")
    for name in ("README.md", "usage.md", "advanced-usage.md", "configuration.md", "guides.md",
                 "documentation-quality.md", "i18n.md"):
        copy_file(repo / "docs" / name, site / "docs" / name)


def pin_documentation_links(site: Path, provenance: dict) -> None:
    """Bind the self-hosted manual's reading links without changing author IR."""
    prefixes = [(f"https://github.com/lIlIIlIll/cjdoc/{view}/main/",
                 provenance["repository"] + f"/{view}/" + provenance["revision"] + "/")
                for view in ("blob", "tree")]
    index = site / "api/concepts/index.html"
    if index.is_file():
        content = index.read_text(encoding="utf-8")
        for source_prefix, target_prefix in prefixes:
            content = content.replace('href="' + source_prefix,
                                      'href="' + html.escape(target_prefix, quote=True))
        index.write_text(content, encoding="utf-8")
    markdown = [site / "markdown/concepts/index.md", *sorted((site / "docs").glob("*.md"))]
    for path in markdown:
        if path.is_file():
            content = path.read_text(encoding="utf-8")
            for source_prefix, target_prefix in prefixes:
                content = content.replace("](" + source_prefix, "](" + target_prefix)
            path.write_text(content, encoding="utf-8")


def build(repo: Path, binary: Path, project: Path, site: Path, work: Path,
          provenance: dict, previous: Path | None = None) -> dict:
    with stage_timing.phase("showcase.tool-versions"):
        versions = {"cjdoc": tool_version([str(binary), "--version"], repo),
                    "cjc": tool_version(["cjc", "-v"], repo),
                    "cjpm": tool_version(["cjpm", "-v"], repo),
                    "cjdocSha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    current = work / "api"
    source = work / "source"

    def api_branch(runner):
        with stage_timing.phase("showcase.api"):
            generate_api(binary, project, current, provenance, repo, runner)

    def pocketkit_branch(runner):
        with stage_timing.phase("showcase.source-copy"):
            copy_sources(repo, source)
        # This module is private to the branch, not installed in sys.modules.
        # Leave the independently reproduced source archive byte-for-byte intact.
        reproduce = reproduce_module(repo)
        reproduce.subprocess = runner
        return reproduce.build(binary, source / "examples/pocketkit", work / "generated",
                               repository=provenance["repository"],
                               revision=provenance["revision"], repository_root=source)

    # API needs only immutable inputs. PocketKit fixes its own support index
    # before its serial locale/version chain. Join both before sharing the site.
    result = BranchRunner().pair(api_branch, pocketkit_branch)
    with stage_timing.phase("showcase.site-copy"):
        shutil.copytree(repo / "site", site)
        not_found = site / "404.html"
        base = "/" + provenance["repository"].rstrip("/").rsplit("/", 1)[-1] + "/"
        not_found.write_text(not_found.read_text(encoding="utf-8").replace("__PAGES_BASE__", base), encoding="utf-8")
    with stage_timing.phase("showcase.reports"):
        publish_examples(result, site, provenance)
        publish_compatibility(repo, site, current, result)
        if project == repo:
            pin_documentation_links(site, provenance)
    # `legacy` is a separately listed surface in the issue's phase inventory, so it
    # is timed on its own instead of being folded into the report phase.
    with stage_timing.phase("showcase.legacy"):
        legacy.publish(binary, repo, site, work)
    with stage_timing.phase("showcase.authoring"):
        from check_showcase_authoring import check as check_authoring
        check_authoring(binary, source / "examples/pocketkit", site / "artifacts/authoring.json")
    if hashlib.sha256(binary.read_bytes()).hexdigest() != versions["cjdocSha256"]:
        raise ContractError("native executable changed during showcase generation")
    with stage_timing.phase("showcase.navigation"):
        navigation.publish(site)
    with stage_timing.phase("showcase.downloads"):
        homepage.downloads(site)
        download = source_archive(source, site, {**provenance, "tools": versions})
    with stage_timing.phase("showcase.plan-baseline"):
        plan = manifest.compile_plan(repo, site)
        resolved = resolve_plan(plan, Site(site), repo, provenance["revision"])
        from showcase_contract.baseline import check_baseline
        check_baseline(load_json(repo / "site/showcase-baseline.json"), resolved)
    if previous is not None:
        with stage_timing.phase("showcase.regressions"):
            check_regressions(load_json(previous), resolved)
    metadata = {"schemaVersion": "cjdoc.showcase/2", "source": provenance, "tools": versions,
                "currentDocIr": reports.IR, "locales": ["zh-CN", "en"],
                "exampleVersions": ["demo-v1", "demo-v2"], "sourceDownload": download,
                "surfaces": ["examples", "diagnostics", "api", "demo", "markdown", "artifacts", "schemas"],
                "acceptance": {"browser": "required", "evidence": "separate final-tree evidence artifact"}}
    (site / "showcase-plan.json").write_bytes(canonical_json(plan))
    (site / "showcase-features.json").write_bytes(canonical_json(resolved))
    (site / "build.json").write_bytes(canonical_json(metadata))
    with stage_timing.phase("showcase.homepage"):
        homepage.publish(repo, site, resolved, metadata)
    with stage_timing.phase("showcase.offline-archive"):
        create_archive(site)
    with stage_timing.phase("showcase.link-validate"):
        Site(site).validate_links()
    stage_timing.flush()
    return metadata


def install_output(staged: Path, output: Path) -> None:
    """Publish only a fully assembled, statically checked directory."""
    backup = staged.parent / "previous-output"
    if output.exists():
        if output.is_symlink() or not output.is_dir():
            raise ContractError("existing showcase output must be a regular directory")
        metadata = load_json(output / "build.json")
        if metadata.get("schemaVersion") != "cjdoc.showcase/2":
            raise ContractError("refusing to replace an unowned output directory")
        os.replace(output, backup)
    try:
        os.replace(staged, output)
    except OSError:
        if backup.exists():
            os.replace(backup, output)
        raise
