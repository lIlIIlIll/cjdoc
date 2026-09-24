"""HTML fragments for the homepage, rendered from the same resolved manifest."""

from __future__ import annotations

from html import escape

from .contract import ContractError, validate_manifest

LABELS = {
    "complete": "实现完成", "partial": "部分实现", "not-implemented": "尚未实现",
    "available": "可体验（发布前必须验收）", "uncovered": "演示未覆盖", "blocked": "演示阻塞",
}


def render_cards(manifest: dict) -> str:
    validate_manifest(manifest)
    rows = ['<section id="showcase-features" aria-labelledby="showcase-features-title">',
            '<h2 id="showcase-features-title">功能演示与覆盖边界</h2>']
    for feature in manifest["features"]:
        fid = escape(feature["id"], quote=True)
        rows.extend([f'<article id="feature-{fid}" data-feature-id="{fid}">',
                     f'<h3>{escape(feature["title"])}</h3>',
                     f'<p>{LABELS[feature["implementation"]]} · {LABELS[feature["demonstration"]]}</p>'])
        if feature["reason"]:
            rows.append(f'<p class="feature-limitation">{escape(feature["reason"])}</p>')
        for target in feature["targets"]:
            if target.get("resolved") is None:
                continue
            tid = escape(target["id"], quote=True)
            href = escape(target["resolved"]["href"], quote=True)
            caption = escape(f"{target['locale']} / {target['version']} — {target['instructions']}")
            rows.append(f'<p><a data-target-id="{tid}" href="{href}">{caption}</a></p>')
        if feature["trackingIssues"]:
            numbers = ", ".join(f"#{number}" for number in feature["trackingIssues"])
            rows.append(f'<p>跟踪事项：{numbers}</p>')
        rows.append("</article>")
    rows.append("</section>")
    return "\n".join(rows) + "\n"


def render_home(template: str, manifest: dict) -> str:
    """Exactly one explicit marker avoids fragile arbitrary HTML replacement."""
    marker = "<!-- CJDOC_SHOWCASE_FEATURES -->"
    if template.count(marker) != 1:
        raise ContractError("homepage must contain exactly one CJDOC_SHOWCASE_FEATURES marker")
    return template.replace(marker, render_cards(manifest))
