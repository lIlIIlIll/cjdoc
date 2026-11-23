protected package cjdoc.versions

import cjdoc.render as public_render
import cjdoc.render.foundation.RenderArtifactStore
import std.collection.*

private func injectVersionSelector(html: String, selector: String): String {
    let shellMarker = "<div class=\"cj-layout\">"
    match (html.indexOf(shellMarker)) {
        case Some(index) => html[..index] + selector + html[index..]
        case None =>
            match (html.indexOf("</header>")) {
                case Some(index) =>
                    let end = index + "</header>".size
                    html[..end] + selector + html[end..]
                case None =>
                    match (html.indexOf("</body>")) {
                        case Some(index) => html[..index] + selector + html[index..]
                        case None => html + selector
                    }
            }
    }
}
private func versionManifest(sites: ArrayList<VersionSite>, latest: String,
    latestPolicy: String): String {
    let out = StringBuilder()
    out.append("{\n  \"schemaVersion\": \"${VERSION_MANIFEST_SCHEMA}\",\n")
    out.append("  \"project\": \"composed\",\n  \"latest\": ${versionJsonEscape(latest)},\n")
    out.append("  \"latestPolicy\": ${versionJsonEscape(latestPolicy)},\n  \"versions\": [")
    var first = true
    for (site in sites) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\":${versionJsonEscape(site.spec.id)},\"label\":${versionJsonEscape(site.spec.label)},")
        out.append("\"basePath\":${versionJsonEscape(site.spec.basePath)},\"channel\":${versionJsonEscape(site.spec.channel)},")
        out.append("\"status\":${versionJsonEscape(site.spec.status)},\"index\":${versionJsonEscape(versionOutputPath(site, "index.html"))},")
        let symbolIndex = if (site.hasPath("symbol-index.json")) {
            versionJsonEscape(versionOutputPath(site, "symbol-index.json"))
        } else {
            "null"
        }
        let apiDiff = match (site.spec.apiDiffSource) {
            case Some(_) => versionJsonEscape(versionOutputPath(site, "api-diff.json"))
            case None => "null"
        }
        out.append("\"symbolIndex\":" + symbolIndex + ",\"apiDiff\":" + apiDiff)
        if (!site.logicalRoutes.isEmpty()) {
            out.append(",\"languages\":[")
            var firstLanguage = true
            for (language in ["en", "zh-CN"]) {
                let root = "html/" + language
                if (!site.hasPath(root + "/index.html")) { continue }
                if (!firstLanguage) { out.append(",") }; firstLanguage = false
                out.append("{\"language\":${versionJsonEscape(language)},\"root\":${versionJsonEscape(versionOutputPath(site, root))},\"index\":${versionJsonEscape(versionOutputPath(site, root + "/index.html"))}}")
            }
            out.append("]")
        }
        match (site.spec.release) {
            case Some(value) => out.append(",\"release\":${versionJsonEscape(value)}")
            case None => ()
        }
        out.append("}")
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

private let VERSION_ROOT_STYLE = """
:root{color-scheme:light;--cj-bg:#f5f7fa;--cj-surface:#fff;--cj-fg:#17212b;--cj-muted:#536071;--cj-border:#d7dee8;--cj-accent:#176b5d;--cj-accent-soft:#dff4ef;--cj-shadow:0 18px 48px rgba(23,33,43,.12);font:16px/1.6 system-ui,-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
*{box-sizing:border-box}body{margin:0;background:var(--cj-bg);color:var(--cj-fg)}
.cj-page-header{border-bottom:1px solid var(--cj-border);background:var(--cj-surface)}
.cj-page-header__inner{max-width:1080px;margin:0 auto;padding:1rem 1.5rem;display:flex;align-items:center;justify-content:space-between;gap:1rem}
.cj-header__brand{color:inherit;text-decoration:none;display:flex;align-items:center;gap:.7rem}
.cj-header__project{display:grid;place-items:center;width:2rem;height:2rem;border-radius:7px;background:var(--cj-accent);color:#fff;font:700 .95rem/1 ui-monospace,SFMono-Regular,Menlo,monospace}
.cj-header__brand-copy{display:flex;flex-direction:column;line-height:1.15}
.cj-header__brand-title{font-size:.98rem}
.cj-header__brand-note,.cj-version-root__meta{color:var(--cj-muted);font-size:.8rem}
.cj-version-root{max-width:900px;margin:0 auto;padding:clamp(3rem,8vw,7rem) 1.5rem}
.cj-version-root__eyebrow{margin:0 0 .75rem;color:var(--cj-accent);font:700 .75rem/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.08em;text-transform:uppercase}
.cj-version-root h1{max-width:12ch;margin:0;font-size:clamp(2.4rem,7vw,5.2rem);line-height:.98;letter-spacing:-.06em}
.cj-version-root__lead{max-width:44rem;margin:1.4rem 0 2.5rem;color:var(--cj-muted);font-size:1.08rem}
.cj-version-list{display:grid;gap:.75rem}
.cj-version-card{display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:1.1rem 1.2rem;border:1px solid var(--cj-border);border-radius:10px;background:var(--cj-surface);box-shadow:var(--cj-shadow);color:inherit;text-decoration:none}
.cj-version-card:hover,.cj-version-card:focus-visible{border-color:var(--cj-accent);outline:2px solid var(--cj-accent-soft);outline-offset:2px}
.cj-version-card__main{display:flex;flex-direction:column}
.cj-version-card__main strong{font-size:1.08rem}
.cj-version-card__main span,.cj-version-card__meta{color:var(--cj-muted);font-size:.85rem}
.cj-footer{max-width:900px;margin:0 auto;padding:1.5rem;color:var(--cj-muted);font-size:.8rem}
@media(prefers-color-scheme:dark){:root{color-scheme:dark;--cj-bg:#111820;--cj-surface:#18222d;--cj-fg:#e8eef5;--cj-muted:#aab7c7;--cj-border:#2b3948;--cj-accent:#5ed6bd;--cj-accent-soft:#123b34;--cj-shadow:0 18px 48px rgba(0,0,0,.3)}}
@media(max-width:600px){.cj-page-header__inner{padding:.8rem 1rem}.cj-version-root{padding:3rem 1rem}.cj-version-card{align-items:flex-start;flex-direction:column}.cj-version-root h1{font-size:3.3rem}.cj-version-root__meta{display:none}}
"""

private func versionRootIndex(sites: ArrayList<VersionSite>, latest: String): String {
    let out = StringBuilder()
    out.append("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta name=\"color-scheme\" content=\"light dark\">")
    out.append("<title>Documentation versions</title><style>")
    out.append(VERSION_ROOT_STYLE)
    out.append("</style></head><body class=\"cj-page\" data-cjdoc-route=\"version-root\">")
    out.append("<header class=\"cj-page-header\"><div class=\"cj-page-header__inner\">")
    out.append("<a class=\"cj-header__brand\" href=\"latest/index.html\">")
    out.append("<span class=\"cj-header__project\" aria-hidden=\"true\">cj</span>")
    out.append("<span class=\"cj-header__brand-copy\"><strong class=\"cj-header__brand-title\">Documentation</strong>")
    out.append("<span class=\"cj-header__brand-note\">Version index</span></span></a>")
    out.append("<span class=\"cj-version-root__meta\">Composed by cjdoc</span></div></header>")
    out.append("<main class=\"cj-version-root\"><p class=\"cj-version-root__eyebrow\">Documentation versions</p>")
    out.append("<h1>Choose a version.</h1>")
    out.append("<p class=\"cj-version-root__lead\">Select the project and document version that matches the API reference you want to read.</p>")
    out.append("<nav class=\"cj-version-list\" aria-label=\"Documentation versions\">")
    for (site in sites) {
        let href = public_render.escapeStandaloneHtml(versionOutputPath(site, "index.html"))
        let label = public_render.escapeStandaloneHtml(site.spec.label)
        let channel = public_render.escapeStandaloneHtml(site.spec.channel)
        let latestText = if (site.spec.id == latest) { "Latest" } else { "" }
        out.append("<a class=\"cj-version-card\" href=\"")
        out.append(href)
        out.append("\"><span class=\"cj-version-card__main\"><strong>")
        out.append(label)
        out.append("</strong><span>")
        out.append(channel)
        out.append("</span></span><span class=\"cj-version-card__meta\">")
        out.append(latestText)
        match (site.spec.release) {
            case Some(value) =>
                if (!latestText.isEmpty()) { out.append(" · ") }
                out.append("Released ")
                out.append(public_render.escapeStandaloneHtml(value))
            case None => ()
        }
        out.append("</span></a>\n")
    }
    out.append("</nav></main><footer class=\"cj-footer\"><span>cjdoc · Version manifest: </span>")
    out.append("<a href=\"versions.json\">versions.json</a></footer></body></html>\n")
    out.toString()
}

private func versionLatestIndex(sites: ArrayList<VersionSite>, latest: String): String {
    for (site in sites) {
        if (site.spec.id == latest) {
            let href = "../${versionOutputPath(site, "index.html")}".replace("//", "/")
            return "<!doctype html><meta http-equiv=\"refresh\" content=\"0; url=${public_render.escapeStandaloneHtml(href)}\"><title>Latest documentation</title><p><a href=\"${public_render.escapeStandaloneHtml(href)}\">Latest documentation</a></p>\n"
        }
    }
    throw IllegalArgumentException("latest version disappeared during composition")
}


private func attachComposedApiDiffEvidence(html: String, site: VersionSite,
    outputPath: String, filePath: String): String {
    if (site.spec.apiDiffSource.isNone() || filePath != "validation.html") { return html }
    let diffPath = versionOutputPath(site, "api-diff.json")
    let href = versionRelativeHref(outputPath, diffPath)
    let link = "<a href=\"" + public_render.escapeStandaloneHtml(href) + "\">api-diff.json</a>"
    var result = html
    result = result.replace("API diff: not attached to this generation", "API diff: attached: " + link)
    result = result.replace("API diff：本次生成未附带", "API diff：已附带：" + link)
    result = result.replace("No comparison report was attached to this generation. Run the explicit cjdoc diff command to inspect version-to-version changes; this page does not infer compatibility.", "Attached comparison report: " + link + ".")
    result = result.replace("本次生成未附带比较报告。请显式运行 cjdoc diff 命令检查版本间变化；本页面不会推断兼容性。", "已附带比较报告：" + link + "。")
    result
}

private func versionAliasBody(html: String): Bool {
    match (public_render.generatedHtmlBodyAttribute(html, "data-cjdoc-route")) {
        case Some("symbol-alias") => true
        case Some("package-alias") => true
        case _ => false
    }
}

internal func composeVersionArtifacts(sites: ArrayList<VersionSite>, latest: String,
    latestPolicy: String, budget: VersionComposeBudget): Array<public_render.RenderArtifact> {
    let artifacts = ArrayList<public_render.RenderArtifact>()
    for (site in sites) {
        for (file in site.files) {
            let outputPath = versionOutputPath(site, file.path)
            if (file.path.endsWith(".html")) {
                let remaining = budget.remainingBytes()
                if (file.bytes.size >= remaining) {
                    throw IllegalArgumentException("version artifact '${outputPath}' exceeds composition memory budget")
                }
                let selectorAvailable = remaining - file.bytes.size
                let selectorLimit = if (selectorAvailable < VERSION_FILE_MAX_BYTES) {
                    selectorAvailable
                } else {
                    VERSION_FILE_MAX_BYTES
                }
                let html = try { String.fromUtf8(file.bytes) } catch (_: Exception) {
                    throw IllegalArgumentException("version HTML is not UTF-8 '${file.path}'")
                }
                // Both symbol and package compatibility bodies redirect to their
                // canonical page through symbol-alias.js. Injecting a selector
                // would compete with that redirect; keep query and fragment.
                if (versionAliasBody(html)) {
                    budget.reserveArtifact(outputPath, file.bytes.size)
                    artifacts.add(public_render.RenderArtifact(outputPath, file.mediaType, file.bytes))
                    continue
                }
                let selector = versionSelector(site, outputPath, file.path, sites, limit: selectorLimit,
                    chinese: html.contains("<html lang=\"zh-CN\"") || html.contains("<html lang=\"zh\""))
                budget.reserveArtifact(outputPath, file.bytes.size + selector.size)
                let content = injectVersionSelector(attachComposedApiDiffEvidence(html, site, outputPath, file.path), selector)
                artifacts.add(public_render.RenderArtifact(outputPath, file.mediaType, content))
            } else {
                budget.reserveArtifact(outputPath, file.bytes.size)
                artifacts.add(public_render.RenderArtifact(outputPath, file.mediaType, file.bytes))
            }
        }
    }
    let navigationScript = VERSION_NAVIGATION_SCRIPT +
        "({\"en\":${versionNavigationMessages(false)},\"zh-CN\":${versionNavigationMessages(true)}});\n"
    budget.reserveArtifact("version-navigation.js", navigationScript.size)
    artifacts.add(public_render.RenderArtifact("version-navigation.js", "text/javascript; charset=utf-8", navigationScript))
    let manifest = versionManifest(sites, latest, latestPolicy)
    budget.reserveArtifact("versions.json", manifest.size)
    artifacts.add(public_render.RenderArtifact("versions.json", "application/json", manifest))
    let rootIndex = versionRootIndex(sites, latest)
    budget.reserveArtifact("index.html", rootIndex.size)
    artifacts.add(public_render.RenderArtifact("index.html", "text/html; charset=utf-8", rootIndex))
    let latestIndex = versionLatestIndex(sites, latest)
    budget.reserveArtifact("latest/index.html", latestIndex.size)
    artifacts.add(public_render.RenderArtifact("latest/index.html", "text/html; charset=utf-8", latestIndex))
    artifacts.toArray()
}

private func documentVersionArtifactContent(version: String, projectName: String): String {
    if (!versionSafeId(version)) {
        throw IllegalArgumentException("--doc-version must be a safe version identifier")
    }
    "{\n  \"schemaVersion\": \"${VERSION_FILE_SCHEMA}\",\n  \"id\": ${versionJsonEscape(version)},\n  \"label\": ${versionJsonEscape(version)},\n  \"project\": ${versionJsonEscape(projectName)}\n}\n"
}

/** The CLI publishes `html/version.json` directly into the artifact store. */
protected func appendDocumentVersionArtifactInto(store: RenderArtifactStore,
    version: String, projectName: String): Unit {
    let content = documentVersionArtifactContent(version, projectName)
    let _ = store.addText("html/version.json", "application/json", content)
}
