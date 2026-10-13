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
    """Bind each member permalink to its native details anchor, not its name.

    A member row contains sibling <details> and action controls. Tracking the
    containing row prevents a source/overload link from being attributed to a
    neighboring declaration when the details node closes before the actions.
    """

    def __init__(self, source: str) -> None:
        super().__init__(convert_charrefs=True)
        self.details: list[str | None] = []
        self.members: list[tuple[str, str]] = []
        self.div_depth = 0
        self.row_depth: int | None = None
        self.row_anchor: str | None = None
        self.row_has_link = False
        self.actions_depth: int | None = None
        self.feed(source)
        self.close()
        if self.details or self.row_depth is not None or self.actions_depth is not None:
            raise ContractError("unclosed native member structure in generated page")

    def handle_starttag(self, tag: str, attributes: list[tuple[str, str | None]]) -> None:
        attrs = dict(attributes)
        classes = (attrs.get("class") or "").split()
        if tag == "div":
            self.div_depth += 1
            if "member-row" in classes:
                if self.row_depth is not None:
                    raise ContractError("nested native member rows are not supported")
                self.row_depth = self.div_depth
                self.row_anchor = None
                self.row_has_link = False
            elif ("member-detail-actions" in classes and self.row_depth is not None
                  and self.div_depth == self.row_depth + 1):
                if not self.row_anchor or self.actions_depth is not None:
                    raise ContractError("member actions have no unique preceding native anchor")
                self.actions_depth = self.div_depth
        elif tag == "details":
            is_member = "data-cjdoc-member" in attrs
            self.details.append(attrs.get("id") if is_member else None)
            if is_member and self.row_depth is not None:
                if self.row_anchor is not None or not attrs.get("id"):
                    raise ContractError("member row must contain exactly one native details anchor")
                self.row_anchor = attrs["id"]
        elif tag == "a" and "member-permalink" in classes:
            if self.row_depth is not None:
                if self.actions_depth is None or self.row_has_link:
                    raise ContractError("member permalink is outside its unique sibling actions")
                anchor = self.row_anchor
                self.row_has_link = True
            else:
                # Support older generated pages where actions lived inside details.
                anchor = next((item for item in reversed(self.details) if item is not None), None)
            if not anchor:
                raise ContractError("member permalink is missing its enclosing native anchor")
            if not attrs.get("href"):
                raise ContractError("member permalink is missing href")
            self.members.append((anchor, attrs["href"]))

    def handle_endtag(self, tag: str) -> None:
        if tag == "details":
            if not self.details:
                raise ContractError("unbalanced details element in generated member page")
            self.details.pop()
        elif tag == "div":
            if self.div_depth == 0:
                raise ContractError("unbalanced div element in generated member page")
            if self.actions_depth == self.div_depth:
                self.actions_depth = None
            if self.row_depth == self.div_depth:
                if not self.row_anchor or not self.row_has_link:
                    raise ContractError("member row is missing its native anchor or permalink")
                self.row_depth = None
                self.row_anchor = None
                self.row_has_link = False
            self.div_depth -= 1


def select_declaration(site, target: dict, pages: list[dict]) -> tuple[dict, dict]:
    """Match exact source spelling, then join native navigation by SymbolId."""
    ir = load_json(site.file(target["docIr"]))
    if ir.get("schemaVersion") != "cjdoc.doc-ir/13":
        raise ContractError("member selectors require the current cjdoc.doc-ir/13")
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
