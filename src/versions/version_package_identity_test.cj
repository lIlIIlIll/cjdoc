protected package cjdoc.versions

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func versionTestFile(path: String, content: String): VersionSourceFile {
    VersionSourceFile(path, if (path.endsWith(".json")) { "application/json" } else { "text/html" },
        content.toArray())
}

private func versionTestManifestPackages(entries: Array<(String, String)>,
    schema!: String = "cjdoc.machine-manifest/2"): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"${schema}\",\"representations\":[")
    var first = true
    for ((id, html) in entries) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"kind\":\"package\",\"id\":\"cjdoc:package:${id}\",\"html\":\"${html}\"")
        out.append(",\"markdown\":\"agent/packages/package-${id}.md\",")
        out.append("\"json\":\"agent/packages/package-${id}.json\"}")
    }
    out.append("]}")
    out.toString()
}

private func versionTestPageBody(attributes: String, body: String): String {
    "<!doctype html><html lang=\"en\"><head><title>t</title></head><body class=\"cj-page\" " +
        attributes + ">" + body + "</body></html>"
}

@Test
class VersionPackageIdentityTest {
    @TestCase
    func oldMonolingualPackageComesFromItsOwnManifestRepresentation(): Unit {
        let old = VersionSite(VersionComposeSpec("old", "unused"), VersionSymbolIndex())
        let identity = "cjdoc:module:v1:root:pocketkit"
        let legacy = "packages/package-6c6567616379.html"
        let legacyEntry: Array<(String, String)> = [(identity, legacy)]
        let files = ArrayList<VersionSourceFile>([
            versionTestFile("index.html", versionTestPageBody("", "")),
            versionTestFile(legacy, versionTestPageBody("data-cjdoc-route=\"api\"",
                "<a id=\"declarations\"></a>")),
            versionTestFile("agent/manifest.json",
                versionTestManifestPackages(legacyEntry))])
        loadMonolingualVersionRoutes(old, files)
        let page = VersionLogicalIdentity("en", pageId: Some("package:${identity}"))
        @Expect(versionIdentityRoute(old, page).getOrThrow(), legacy)
        @Expect(old.logicalIdentityByHref[legacy].pageId, Some("package:${identity}"))
        // A compatibility alias is never a package destination, even when a
        // stale manifest row names it.
        let aliased = VersionSite(VersionComposeSpec("aliased", "unused"), VersionSymbolIndex())
        let aliasEntry: Array<(String, String)> = [(identity, "packages/package-alias.html")]
        let aliasFiles = ArrayList<VersionSourceFile>([
            versionTestFile("index.html", versionTestPageBody("", "")),
            versionTestFile("packages/package-alias.html", versionTestPageBody(
                "data-cjdoc-route=\"package-alias\" data-cjdoc-package-alias-for=\"package:${identity}\"" +
                " data-cjdoc-page-id=\"package:${identity}\"", "")),
            versionTestFile("agent/manifest.json",
                versionTestManifestPackages(aliasEntry))])
        @ExpectThrows[IllegalArgumentException](loadMonolingualVersionRoutes(aliased, aliasFiles))
    }

    @TestCase
    func newMonolingualPackageUsesBodyIdentityAndActualRowAnchors(): Unit {
        let canonical = "packages/pocketkit/index.html"
        let alias = "packages/package-6c6567616379.html"
        let identity = "cjdoc:module:v1:root:pocketkit"
        let row = "symbol-7061636b616765"
        let canonicalEntry: Array<(String, String)> = [(identity, canonical)]
        let files = ArrayList<VersionSourceFile>([
            versionTestFile("index.html", versionTestPageBody("", "")),
            versionTestFile(canonical, versionTestPageBody(
                "data-cjdoc-route=\"api\" data-cjdoc-page-id=\"package:${identity}\"",
                "<span id=\"declarations\"></span><table><tr id=\"${row}\"></tr></table>")),
            versionTestFile(alias, versionTestPageBody(
                "data-cjdoc-route=\"package-alias\" data-cjdoc-package-alias-for=\"package:${identity}\"",
                "<a data-cjdoc-alias-target href=\"pocketkit/index.html\">go</a>" +
                "<tr id=\"${row}\"></tr>")),
            versionTestFile("agent/manifest.json",
                versionTestManifestPackages(canonicalEntry, schema: "cjdoc.machine-manifest/3"))])
        let site = VersionSite(VersionComposeSpec("new", "unused"), VersionSymbolIndex())
        loadMonolingualVersionRoutes(site, files)
        let page = VersionLogicalIdentity("en", pageId: Some("package:${identity}"))
        @Expect(versionIdentityRoute(site, page).getOrThrow(), canonical)
        @Expect(!site.logicalIdentityByHref.contains(alias))
        @Expect(!site.sectionIdsByPage.contains(alias))
        @Expect(!site.apiDirectoryFiles.contains(alias))
        // Only real ids of the canonical body become scoped row positions.
        let sections = site.sectionIdsByPage[canonical]
        @Expect(sections.size, 1)
        @Expect(sections[row].pageId, Some("package:${identity}"))
        @Expect(sections[row].symbolId, None<String>)
        @Expect(versionIdentityRoute(site, sections[row]).getOrThrow(), canonical + "#" + row)
        // An absent language/page/row stays a fallback, never an exact target.
        let empty = VersionSite(VersionComposeSpec("empty", "unused"), VersionSymbolIndex())
        let missingPage = versionLanguageTarget(empty, page, empty)
        @Expect(missingPage.href, "index.html")
        @Expect(match (missingPage.state) { case VersionNavigationState.MissingPage => true; case _ => false })
    }

    @TestCase
    func mixedGenerationsResolveEachDirectionWithoutChoosingTheAlias(): Unit {
        let identity = "cjdoc:module:v1:root:pocketkit"
        let legacy = "packages/package-6c6567616379.html"
        let canonical = "packages/pocketkit/index.html"
        let alias = "packages/package-6f6c64.html"
        let row = "symbol-7061636b616765"
        let old = VersionSite(VersionComposeSpec("old", "unused"), VersionSymbolIndex())
        let oldEntry: Array<(String, String)> = [(identity, legacy)]
        let oldFiles = ArrayList<VersionSourceFile>([
            versionTestFile("index.html", versionTestPageBody("", "")),
            versionTestFile(legacy, versionTestPageBody("data-cjdoc-route=\"api\"", "")),
            versionTestFile("agent/manifest.json",
                versionTestManifestPackages(oldEntry))])
        loadMonolingualVersionRoutes(old, oldFiles)
        let newSite = VersionSite(VersionComposeSpec("new", "unused"), VersionSymbolIndex())
        let newEntryTuple: Array<(String, String)> = [(identity, canonical)]
        let newFiles = ArrayList<VersionSourceFile>([
            versionTestFile("index.html", versionTestPageBody("", "")),
            versionTestFile(canonical, versionTestPageBody(
                "data-cjdoc-route=\"api\" data-cjdoc-page-id=\"package:${identity}\"",
                "<tr id=\"${row}\"></tr>")),
            versionTestFile(alias, versionTestPageBody(
                "data-cjdoc-route=\"package-alias\" data-cjdoc-package-alias-for=\"package:${identity}\"", "")),
            versionTestFile("agent/manifest.json",
                versionTestManifestPackages(newEntryTuple, schema: "cjdoc.machine-manifest/3"))])
        loadMonolingualVersionRoutes(newSite, newFiles)
        // Old /2 -> new /3: the genuine old manifest row identifies the package,
        // and the new generation's canonical directory is the only target.
        let forward = versionTargetRoute(old, legacy, newSite)
        @Expect(forward.href, canonical)
        @Expect(match (forward.state) { case VersionNavigationState.Exact => true; case _ => false })
        // New /3 -> old /2: the flat file was a real page of that generation.
        let backward = versionTargetRoute(newSite, canonical, old)
        @Expect(backward.href, legacy)
        @Expect(match (backward.state) { case VersionNavigationState.Exact => true; case _ => false })
        // The new alias is never a package destination in either direction.
        @Expect(!newSite.logicalIdentityByHref.contains(alias))
        @Expect(!old.logicalIdentityByHref.contains(alias))
        let rowIdentity = VersionLogicalIdentity("en", pageId: Some("package:${identity}"),
            sectionId: Some(row))
        @Expect(versionIdentityRoute(newSite, rowIdentity).isSome())
        // The old generation has no row anchor: the package page opens, and the
        // missing declaration is reported instead of a fabricated fragment.
        let rowBack = versionLanguageTarget(newSite, rowIdentity, old)
        @Expect(rowBack.href, legacy)
        @Expect(match (rowBack.state) { case VersionNavigationState.MissingSection => true; case _ => false })
        let selector = versionSelector(newSite, "new/" + canonical, canonical,
            ArrayList<VersionSite>([newSite, old]))
        @Expect(selector.contains("data-cjdoc-version-routes="))
        @Expect(selector.contains("../../../old/" + legacy))
        @Expect(!selector.contains("../../../old/" + alias))
    }

    @TestCase
    func bilingualPackageIdentityKeepsCanonicalRowAndSectionPerLocale(): Unit {
        let identity = "cjdoc:module:v1:root:pocketkit"
        let page = "packages/pocketkit/index.html"
        let row = "symbol-7061636b616765"
        let manifest = """
{"schemaVersion":"cjdoc.site-manifest/1","defaultLanguage":"en","routes":[
 {"language":"en","pageId":"package:${identity}","symbolId":null,"sectionId":null,
  "ownerSymbolId":null,"href":"html/en/${page}"},
 {"language":"en","pageId":"package:${identity}","symbolId":null,"sectionId":"${row}",
  "ownerSymbolId":null,"href":"html/en/${page}#${row}"},
 {"language":"zh-CN","pageId":"package:${identity}","symbolId":null,"sectionId":null,
  "ownerSymbolId":null,"href":"html/zh-CN/${page}"}]}
"""
        let files = ArrayList<VersionSourceFile>([
            versionTestFile("html/en/index.html", versionTestPageBody("", "")),
            versionTestFile("html/zh-CN/index.html", versionTestPageBody("data-cjdoc-route=\"api\"", "")),
            versionTestFile("html/en/" + page, versionTestPageBody(
                "data-cjdoc-route=\"api\" data-cjdoc-page-id=\"package:${identity}\"",
                "<tr id=\"${row}\"></tr>")),
            versionTestFile("html/zh-CN/" + page, versionTestPageBody(
                "data-cjdoc-route=\"api\" data-cjdoc-page-id=\"package:${identity}\"", "")),
            versionTestFile("html/en/packages/package-6c6567616379.html", versionTestPageBody(
                "data-cjdoc-route=\"package-alias\" data-cjdoc-package-alias-for=\"package:${identity}\"", "")),
            versionTestFile("site-manifest.json", manifest)])
        let paths = HashSet<String>()
        for (file in files) { let _ = paths.add(file.path) }
        let site = VersionSite(VersionComposeSpec("bilingual", "unused"), VersionSymbolIndex())
        loadVersionLanguageRoutes(site, files, paths)
        @Expect(site.defaultLanguage, "en")
        let english = VersionLogicalIdentity("en", pageId: Some("package:${identity}"))
        @Expect(versionIdentityRoute(site, english).getOrThrow(), "html/en/" + page)
        let rowIdentity = VersionLogicalIdentity("en", pageId: Some("package:${identity}"),
            sectionId: Some(row))
        @Expect(versionIdentityRoute(site, rowIdentity).getOrThrow(), "html/en/" + page + "#" + row)
        let chinese = VersionLogicalIdentity("zh-CN", pageId: Some("package:${identity}"))
        @Expect(versionIdentityRoute(site, chinese).getOrThrow(), "html/zh-CN/" + page)
        // The Chinese package page exists, but its row does not: the selector
        // must open that page without inventing the fragment.
        let chineseRow = VersionLogicalIdentity("zh-CN", pageId: Some("package:${identity}"),
            sectionId: Some(row))
        let rowFallback = versionLanguageTarget(site, chineseRow, site)
        @Expect(rowFallback.href, "html/zh-CN/" + page)
        @Expect(match (rowFallback.state) {
            case VersionNavigationState.MissingSection => true; case _ => false
        })
    }

    @TestCase
    func versionNavigationCopyNamesTheActionNotACompletedMove(): Unit {
        let currentIndex = VersionSymbolIndex()
        currentIndex.add("symbol", "symbols/symbol.html")
        let current = VersionSite(VersionComposeSpec("new", "unused"), currentIndex)
        let old = VersionSite(VersionComposeSpec("old", "unused"), VersionSymbolIndex())
        let selector = versionSelector(current, "new/validation.html", "validation.html",
            ArrayList<VersionSite>([current, old]), chinese: true)
        @Expect(selector.contains("此版本无对应页面 · 前往版本首页"))
        @Expect(!selector.contains("已返回版本首页"))
        @Expect(selector.contains("missing-page"))
    }
}
