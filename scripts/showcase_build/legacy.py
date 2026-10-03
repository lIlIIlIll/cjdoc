"""Keep historical fixture URLs as explicit migration notices, without test content."""
from __future__ import annotations

import html
import os
from pathlib import Path
import subprocess

from showcase_contract.site import HtmlDocument, canonical_json


def publish(binary: Path, repo: Path, site: Path, work: Path) -> None:
    generated = work / "legacy-routes"
    command = [str(binary), "generate", "--project", str(repo / "tests/fixtures/projects/html_reference"),
               "--format", "html", "--output", str(generated), "--locale", "en",
               "--doc-version", "demo", "--no-cache"]
    print("+ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=repo, check=True)
    records = []
    for native in sorted((generated / "html").rglob("*.html")):
        relative = native.relative_to(generated / "html")
        page = site / "demo" / relative
        page.parent.mkdir(parents=True, exist_ok=True)
        document = HtmlDocument(native.read_text(encoding="utf-8"))
        home = os.path.relpath(site / "index.html", page.parent).replace(os.sep, "/")
        demo = os.path.relpath(site / "examples/zh-CN/index.html", page.parent).replace(os.sep, "/")
        anchors = ''.join('<span id="' + html.escape(anchor, quote=True) + '"></span>' for anchor in sorted(document.ids))
        content = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>历史演示已迁移 / Historical demo moved</title></head><body>'
        content += anchors + '<main><h1>历史演示入口已迁移 / Historical demo moved</h1><p>此地址属于旧测试夹具，已保留作为兼容入口。旧夹具不再作为公开产品样例。新示例库 PocketKit 与旧 API 并非相同语义的声明。</p><p>This historical fixture route remains available as a migration notice. PocketKit is a new example library, not a replacement declaration with the same identity.</p>'
        content += '<p><a href="' + html.escape(demo) + '">打开 PocketKit / Open PocketKit</a> · <a href="' + html.escape(home) + '">展示首页与指南 / Showcase and guide</a></p></main></body></html>'
        page.write_text(content, encoding="utf-8")
        records.append({"path": relative.as_posix(), "anchors": sorted(document.ids)})
    (site / "demo/routes.json").write_bytes(canonical_json({"schemaVersion": "cjdoc.legacy-routes/1", "source": "native html_reference routes", "routes": records}))
