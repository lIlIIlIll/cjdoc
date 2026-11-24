"""Homepage member preview projected from the generated native document set."""
from __future__ import annotations

from html import escape

from showcase_contract.routes import select_declaration
from showcase_contract.site import ContractError, Site, load_json, load_navigation_index


def version_target(manifest: dict, locale: str, version: str) -> dict:
    feature_id = "compact-members" if version == "demo-v2" else "multi-version"
    target_id = ("append-string-" if version == "demo-v2" else "old-integer-overload-") + locale
    matches = [target for feature in manifest["features"] if feature["id"] == feature_id
               for target in feature["targets"] if target["id"] == target_id
               and target["locale"] == locale and target["version"] == version and target["resolved"]]
    if len(matches) != 1:
        raise ContractError("missing resolved homepage preview target: " + target_id)
    return matches[0]


def summary(declaration: dict, locale: str) -> str:
    comment = declaration.get("documentation") or {}
    for field in comment.get("localizedTexts", []):
        if field.get("kind") == "summary" and field.get("language") == locale:
            return field["text"]
    return comment.get("summary", "") if comment.get("defaultLanguage") == locale else ""


def version_data(site: Site, target: dict) -> tuple[dict, list[tuple[dict, str]], str]:
    """Select the native owner and join preview rows by emitted SymbolId."""
    index = load_navigation_index(lambda name: load_json(site.file(name)), target["index"])
    if index["project"] != target["project"]:
        raise ContractError("homepage preview navigation project mismatch")
    pages = index["pages"]
    declaration, _ = select_declaration(site, target, pages)
    ir = load_json(site.file(target["docIr"]))
    owner_id = declaration.get("ownerId")
    owners = [item for item in ir["declarations"] if item["id"] == owner_id]
    if len(owners) != 1:
        raise ContractError("homepage preview needs one source-backed owner")
    owner = owners[0]
    members = [item for item in ir["declarations"] if item.get("ownerId") == owner_id
               and item["name"] in ("add", "at") and item["visibility"] == "public"]
    if {item["name"] for item in members} != {"add", "at"}:
        raise ContractError("homepage preview members are missing")
    members.sort(key=lambda item: (item["name"], item["headerSpelling"]))

    def route(item: dict) -> str:
        matches = [page for page in pages if page.get("kind") == "symbol"
                   and page.get("symbolId") == item["id"]]
        if len(matches) != 1:
            raise ContractError("homepage preview needs one native route for " + item["id"])
        return site.checked_navigation_page(target, matches[0])["href"]

    return owner, [(item, route(item)) for item in members], route(owner)


def render_version(site: Site, target: dict, locale: str) -> str:
    owner, members, owner_href = version_data(site, target)
    zh = locale == "zh-CN"
    open_member = "完整声明" if zh else "Full declaration"
    open_owner = "打开完整文档" if zh else "Open full documentation"
    member_label = "成员预览" if zh else "Member preview"
    no_match = "没有匹配的成员" if zh else "No matching preview members"
    owner_name, package = escape(owner["name"]), escape(owner["packageName"])
    version = escape(target["version"])
    owner_href = escape(owner_href, quote=True)
    description = escape(summary(owner, locale))
    rows = []
    for member, href in members:
        text = summary(member, locale)
        details = f'<p>{escape(text)}</p>' if text else ''
        rows.append(f'<details class="portal-member" data-portal-member>'
                    f'<summary><code>{escape(member["headerSpelling"])}</code></summary>'
                    f'<div>{details}<a href="{escape(href, quote=True)}">{open_member} ↗</a></div></details>')
    return (f'<section class="portal-version" data-portal-version="{version}" aria-label="PocketKit {version}">'
            f'<div class="portal-api"><div class="portal-tree"><span>{package}</span>'
            f'<a href="{owner_href}">{owner_name}</a><span class="portal-tree-caption">{version}</span></div>'
            f'<div class="portal-api-content"><div class="portal-breadcrumb">{package} / {owner_name}</div>'
            f'<h3><a href="{owner_href}">{owner_name}</a> <code class="portal-kind">{escape(owner["kind"])}</code></h3>'
            + (f'<p class="portal-api-summary">{description}</p>' if description else '')
            + f'<h4>{member_label}</h4><div class="portal-members">'
            + ''.join(rows)
            + f'<p data-portal-empty hidden role="status">{no_match}</p></div></div></div>'
            f'<div class="portal-preview-footer"><span>{version} · {member_label}</span>'
            f'<a href="{owner_href}">{open_owner} ↗</a></div></section>')


def preview(site: Site, manifest: dict, locale: str) -> str:
    """Without scripts, both snapshots and their native links remain readable."""
    version_label = "演示版本" if locale == "zh-CN" else "Demo version"
    filter_label = "筛选预览成员" if locale == "zh-CN" else "Filter preview members"
    variants = [render_version(site, version_target(manifest, locale, version), locale)
                for version in ("demo-v2", "demo-v1")]
    return (f'<div data-portal-preview><div class="portal-preview-controls" data-portal-controls hidden>'
            f'<strong>PocketKit</strong><label><span class="visually-hidden">{version_label}</span>'
            '<select data-portal-select><option value="demo-v2" selected>demo-v2</option>'
            '<option value="demo-v1">demo-v1</option></select></label>'
            f'<label class="portal-filter"><span class="visually-hidden">{filter_label}</span>'
            f'<input type="search" data-portal-filter placeholder="{filter_label}"></label></div>'
            + ''.join(variants) + '</div>')
