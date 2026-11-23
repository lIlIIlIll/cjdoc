protected package cjdoc.render.codec

import cjdoc.render.routes.{safeRelativePath, documentationSectionAnchor}
import cjdoc.model.*
import std.collection.*

internal func validateDocumentationAssets(documentation: DocumentationSet): HashSet<String> {
    let assetIds = HashSet<String>()
    let assetPaths = HashSet<String>()
    let assetReferences = HashMap<String, String>()
    var totalAssetBytes: Int64 = 0
    var totalAssetPixels: Int64 = 0
    var index: Int64 = 0
    for (asset in documentation.assets) {
        if (!validSha256AssetId(asset.id) || !assetIds.add(asset.id) || !safeRelativePath(asset.sourcePath) ||
            !assetPaths.add(asset.sourcePath)) {
            domainFail("$.assets[${index}]", "duplicate asset id/path or unsafe source path")
        }
        for (reference in [asset.id, asset.sourcePath]) {
            match (assetReferences.get(reference)) {
                case Some(owner) => if (owner != asset.id) {
                    domainFail("$.assets[${index}]", "ambiguous asset id/sourcePath reference")
                }
                case None => assetReferences[reference] = asset.id
            }
        }
        let decoded = try {
            let _ = assetMediaExtension(asset.mediaType)
            decodeAssetBase64(asset.base64)
        } catch (_: Exception) {
            domainFail("$.assets[${index}]", "unsupported media type or invalid base64")
        }
        let pixels = try {
            validateRasterAsset(asset.mediaType, decoded)
        } catch (_: IllegalArgumentException) {
            domainFail("$.assets[${index}]", "invalid or oversized local image asset")
        }
        if (asset.id != "sha256-${contractFingerprintBytes(decoded)}") {
            domainFail("$.assets[${index}].id", "asset id does not match SHA-256 content digest")
        }
        if (decoded.size > DOC_IR_MAX_TOTAL_ASSET_BYTES - totalAssetBytes) {
            domainFail("$.assets", "decoded local assets exceed 64 MiB")
        }
        totalAssetBytes += decoded.size
        if (pixels > DOC_IR_MAX_TOTAL_ASSET_PIXELS - totalAssetPixels) {
            domainFail("$.assets", "decoded local assets exceed the total pixel budget")
        }
        totalAssetPixels += pixels
        index++
    }
    index = 0
    for (declaration in documentation.declarations) {
        if (let Some(comment) <- declaration.documentation) {
            for (text in comment.localizedTexts) {
                validateMarkdownAssetReferences(text.markdown, "$.documentation.localizedTexts.markdown", assetIds)
            }
            validateMarkdownAssetReferences(comment.markdown,
                "$.declarations[${index}].documentation.markdown", assetIds)
            for (tag in comment.tags) {
                if (let Some(markdown) <- tag.descriptionMarkdown) {
                    validateMarkdownAssetReferences(markdown, "$.documentation.tags.descriptionMarkdown", assetIds)
                }
                if (let Some(markdown) <- tag.exampleMarkdown) {
                    validateMarkdownAssetReferences(markdown,
                        "$.declarations[${index}].documentation.tags.exampleMarkdown", assetIds)
                }
            }
        }
        index++
    }
    assetIds
}

internal func validateDocumentationPages(documentation: DocumentationSet, assetIds: HashSet<String>,
    byId: HashMap<String, SymbolDoc>, navigationEvidence: NavigationEvidence): Unit {
    let pageIds = HashSet<String>()
    if (documentation.pages.size > 128) { domainFail("$.pages", "page limit exceeded") }
    // Match the producer's page context: captured target modules first, then
    // root modules (or the sole module). Multiple contexts leave no known owner.
    var pageRootModule = ""
    var pageRootCount: Int64 = 0
    for (module in documentation.modules where module.role == "root") {
        pageRootModule = module.id
        pageRootCount++
    }
    if (pageRootCount == 0 && documentation.modules.size == 1) {
        pageRootModule = documentation.modules[0].id
    } else if (pageRootCount != 1) {
        pageRootModule = ""
    }
    for (page in documentation.pages) {
        if (!safeRelativePath(page.source) || !safeDocumentationPageRoute(page.route) || !page.route.endsWith(".html") ||
            !pageIds.add(page.id + ":" + page.language.getOrDefault({ => "unknown" }))) {
            domainFail("$.pages", "unsafe page path or duplicate logical language variant")
        }
        var pageModuleId = ""
        var hasTargetContext = false
        for (id in page.targetSymbolIds) {
            if (let Some(target) <- byId.get(id)) {
                hasTargetContext = true
                if (pageModuleId.isEmpty()) {
                    pageModuleId = target.moduleId
                } else if (pageModuleId != target.moduleId) {
                    pageModuleId = ""
                    break
                }
            }
        }
        if (!hasTargetContext) { pageModuleId = pageRootModule }
        validateMarkdown(page.markdown, "$.pages.markdown", 0, pageModuleId, navigationEvidence)
        validateMarkdownAssetReferences(page.markdown, "$.pages.markdown", assetIds)
        let sectionIds = HashSet<String>()
        let sectionAnchors = HashSet<String>()
        for (section in page.sections) {
            let anchor = documentationSectionAnchor(page.markdown, section.anchor)
            if (!sectionIds.add(section.id) || anchor.isNone() || !sectionAnchors.add(anchor.getOrThrow())) {
                domainFail("$.pages.sections", "duplicate or nonexistent explicit section mapping")
            }
        }
        for (id in page.targetSymbolIds) { if (!byId.contains(id)) { domainFail("$.pages.targetSymbolIds", "unknown SymbolId") } }
        for (binding in page.bindings) {
            if (let Some(navigation) <- binding.navigation) {
                navigationEvidence.validate(navigation, "$.pages.bindings.navigation", pageModuleId)
            }
            if (let Some(id) <- binding.targetSymbolId) {
                if (!byId.contains(id) || !page.targetSymbolIds.toArray().contains(id)) {
                    domainFail("$.pages.bindings", "binding target must belong to the page's captured targets")
                }
            }
        }
    }
    validateCapturedPageRoutes(documentation)
}
