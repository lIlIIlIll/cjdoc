"""Native member-route projection. Never reconstruct a SymbolId or HTML anchor.

Overloads are selected by the full headerSpelling in Doc IR, joined to the
navigation index by the emitted id. Owner pages and inline ids are then read
from emitted HTML. Source signatures are not claimed to be canonical types.
"""
from __future__ import annotations

from html.parser import HTMLParser
from urllib.parse import quote, urlsplit

from .site import ContractError, load_json


class MemberLinks(HTMLParser):
    """Collect only permalinks nested in actual renderer member details."""

    def __init__(self, source: str) -> None:
        super().__init__(convert_charrefs=True)
        self.details: list[str | None] = []
        self.members: list[tuple[str, str]] = []
        self.feed(source)
        self.close()
        if self.details:
            raise ContractError("unclosed details element in generated member page")

    def handle_starttag(self, tag: str, attributes: list[tuple[str, str | None]]) -> None:
        attrs = dict(attributes)
        if tag == "details":
            self.details.append(attrs.get("id") if "data-cjdoc-member" in attrs else None)
        if tag == "a" and "member-permalink" in (attrs.get("class") or "").split():
            anchor = next((item for item in reversed(self.details) if item is not None), None)
            if not anchor or not attrs.get("href"):
                raise ContractError("member permalink is missing its enclosing native anchor")
            self.members.append((anchor, attrs["href"]))

    def handle_endtag(self, tag: str) -> None:
        if tag == "details":
            if not self.details:
                raise ContractError("unbalanced details element in generated member page")
            self.details.pop()


def select_declaration(site, target: dict, pages: list[dict]) -> tuple[dict, dict]:
    """Match exact source spelling, then join native navigation by SymbolId."""
    ir = load_json(site.file(target["docIr"]))
    if ir.get("schemaVersion") != "cjdoc.doc-ir/10":
        raise ContractError("member selectors require the current cjdoc.doc-ir/10")
    if (ir.get("project", {}).get("name") != target["project"]["name"]
            or ir.get("configuration", {}).get("audience") != target["project"]["audience"]
            or ir.get("generator", {}).get("name") != "cjdoc"):
        raise ContractError("Doc IR/navigation project or audience mismatch")
    declarations = ir.get("declarations")
    if not isinstance(declarations, list) or any(not isinstance(d, dict) for d in declarations):
        raise ContractError("invalid Doc IR declaration inventory")
    ids = [d.get("id") for d in declarations]
    if any(not isinstance(i, str) or not i for i in ids) or len(ids) != len(set(ids)):
        raise ContractError("duplicate or missing Doc IR declaration identity")
    match = target["match"]
    candidates = [d for d in declarations if d.get("qualifiedName") == match["title"]
                  and all(d.get(k) == v for k, v in match.items()
                          if k not in ("title", "kind"))]
    if "signature" in target:
        candidates = [d for d in candidates if d.get("headerSpelling") == target["signature"]]
    if len(candidates) != 1:
        raise ContractError(f"Doc IR selector needs exactly one declaration, got {len(candidates)}")
    declaration = candidates[0]
    candidates = [p for p in pages if p.get("symbolId") == declaration["id"]
                  and all(p.get(k) == v for k, v in match.items())]
    if len(candidates) != 1:
        raise ContractError("Doc IR declaration must join exactly one scoped navigation record")
    return declaration, candidates[0]


def inline_route(site, target: dict, declaration: dict, pages: list[dict], member: dict) -> dict:
    """Locate the exact member permalink in its generated owner's HTML.

    Missing owners/anchors and ambiguous duplicates are errors. In particular,
    extension applicability is NOT inferred and member names alone are not used.
    """
    owner_id = declaration.get("ownerId")
    if not owner_id:
        raise ContractError("inline member selector has no source-backed ownerId")
    owners = [p for p in pages if p.get("kind") == "symbol" and p.get("symbolId") == owner_id]
    if len(owners) != 1:
        raise ContractError("inline member must have exactly one emitted owner page")
    owner = site.checked_navigation_page(target, owners[0])
    owner_path = urlsplit(owner["href"]).path
    native_links = MemberLinks(site.file(owner_path).read_text(encoding="utf-8"))
    expected = site.local_link(target["index"], member["href"])
    anchors = [anchor for anchor, href in native_links.members
               if site.local_link(owner_path, href) == expected]
    if len(anchors) != 1:
        raise ContractError(f"inline member needs exactly one native permalink, got {len(anchors)}")
    anchor = anchors[0]
    if anchor not in site.documents[owner_path].ids or anchor in site.documents[owner_path].duplicates:
        raise ContractError("missing or duplicate native member anchor")
    member_result = site.checked_navigation_page(target, member)
    return {**member_result, "href": owner_path + "#" + quote(anchor, safe="-._~"),
            "memberPageHref": member_result["href"], "ownerSymbolId": owner_id,
            "signature": declaration["headerSpelling"], "memberName": declaration["name"]}
