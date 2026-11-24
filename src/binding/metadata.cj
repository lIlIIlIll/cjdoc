protected package cjdoc.binding

import cjdoc.semantic.SemanticDeclaration
import cjdoc.source.model.SourceSnapshot
import cjdoc.source.Diagnostic
import cjdoc.documentation.metadata.{
    DocumentationMetadataConfig, DocumentationMetadataInventory, MetadataContainer, MetadataGroupConfig,
    MetadataModuleConfiguration, MetadataPackageScope, MetadataTagConfig, metadataOwnerIdSelectorKey,
    metadataOwnerNameSelectorKey, parseDocumentationMetadataConfig}
import cjdoc.documentation.comments.{CommentSpec, parseCommentSpec}
import cjdoc.source.SourceLocation
import cjdoc.filesystem.readTextBounded
import std.fs.*
import cjdoc.model as api_model
import std.collection.*

private let DOCUMENTATION_METADATA_MAX_DEFINITIONS: Int64 = 2048

internal class ResolvedMetadataGroup {
    let moduleId: String
    let ownerSourceKey: ?String
    let config: MetadataGroupConfig
    let scopeKey: String
    let configPath: String

    init(moduleId: String, ownerSourceKey: ?String, config: MetadataGroupConfig,
        scopeKey: String, configPath: String) {
        this.moduleId = moduleId
        this.ownerSourceKey = ownerSourceKey
        this.config = config
        this.scopeKey = scopeKey
        this.configPath = configPath
    }
}

internal class ResolvedMetadataTag {
    let moduleId: String
    let config: MetadataTagConfig
    let scopeKey: String
    let configPath: String

    init(moduleId: String, config: MetadataTagConfig, scopeKey: String, configPath: String) {
        this.moduleId = moduleId
        this.config = config
        this.scopeKey = scopeKey
        this.configPath = configPath
    }
}

// One bounded read per actual module root feeds both configuration namespaces,
// so `[metadata]` and `[comments]` can never observe different file versions.
// Both namespaces read the same bounded file; the limit is the metadata
// reader's published 64 KiB budget.
private let PROJECT_CONFIGURATION_MAX_BYTES: Int64 = 64 * 1024

private class ProjectModuleConfig {
    let metadata: DocumentationMetadataConfig
    let comments: CommentSpec

    init(metadata: DocumentationMetadataConfig, comments: CommentSpec) {
        this.metadata = metadata
        this.comments = comments
    }
}

private func readProjectModuleConfig(root: String, configPath: String): ProjectModuleConfig {
    let path = Path(root).join("cjdoc.toml")
    if (!exists(path)) {
        return ProjectModuleConfig(parseDocumentationMetadataConfig(""), CommentSpec())
    }
    let text = try {
        readTextBounded(path, PROJECT_CONFIGURATION_MAX_BYTES)
    } catch (_: Exception) {
        throw IllegalArgumentException(
            "CJDOC3133 at ${configPath}:1: configuration must be valid UTF-8 and no larger than 65536 bytes")
    }
    ProjectModuleConfig(parseDocumentationMetadataConfig(text),
        parseCommentSpec(text, configPath: configPath))
}

private func metadataInventoryFailure(detail: String): IllegalArgumentException {
    IllegalArgumentException("CJDOC3133: ${detail}")
}

private func metadataHasOwnerSelector(config: MetadataGroupConfig): Bool {
    config.owner.isSome() || config.ownerId.isSome()
}

private func metadataEligibleOwnerKind(kind: String): Bool {
    kind == "class" || kind == "struct" || kind == "interface" || kind == "enum" || kind == "extend"
}

private func metadataPackageExists(inventory: DocumentationMetadataInventory,
    moduleId: String, packageName: String): Bool {
    for (pkg in inventory.packages) {
        if (pkg.moduleId == moduleId && pkg.packageName == packageName) { return true }
    }
    false
}

private func metadataGroupScopeKey(moduleId: String, packageName: String,
    ownerSourceKey: ?String, groupId: String): String {
    let ownerKey = ownerSourceKey.getOrDefault({ => "" })
    "${moduleId.size}:${moduleId}${packageName.size}:${packageName}${ownerKey.size}:${ownerKey}${groupId.size}:${groupId}"
}

private func metadataTagScopeKey(moduleId: String, tagId: String): String {
    "${moduleId.size}:${moduleId}${tagId.size}:${tagId}"
}
/**
 * Validate a workspace descriptor directory's own configuration.
 *
 * A directory that only lists members contributes no declarations, so its
 * `[comments]` policy is parsed for diagnostics but never attached to a module.
 */
protected func validateDescriptorConfiguration(root: String): Unit {
    let _ = readProjectModuleConfig(root, "cjdoc.toml")
}

protected func captureDocumentationMetadataInventory(source: SourceSnapshot,
    projectRoot!: String = ""): Unit {
    let parsedByRoot = HashMap<String, ProjectModuleConfig>()
    let moduleConfigurations = ArrayList<MetadataModuleConfiguration>()
    var groupDefinitionCount: Int64 = 0
    var tagDefinitionCount: Int64 = 0
    var fieldDefinitionCount: Int64 = 0
    for (moduleRoot in source.metadataModuleRoots) {
        let config = match (parsedByRoot.get(moduleRoot.actualRoot)) {
            case Some(value) => value
            case None =>
                let value = readProjectModuleConfig(moduleRoot.actualRoot, moduleRoot.configPath)
                parsedByRoot[moduleRoot.actualRoot] = value
                value
        }
        if (!config.comments.isEmpty()) { source.commentSpecs[moduleRoot.moduleId] = config.comments }
        moduleConfigurations.add(MetadataModuleConfiguration(moduleRoot.moduleId,
            moduleRoot.configPath, config.metadata))
        groupDefinitionCount += config.metadata.groups.size
        tagDefinitionCount += config.metadata.tags.size
        fieldDefinitionCount += config.comments.fields.size
        if (fieldDefinitionCount > DOCUMENTATION_METADATA_MAX_DEFINITIONS) {
            throw IllegalArgumentException("CJDOC3139 at ${moduleRoot.configPath}:1: " +
                "comment fields exceed 2048 definitions across captured modules")
        }
        if (groupDefinitionCount > DOCUMENTATION_METADATA_MAX_DEFINITIONS ||
            tagDefinitionCount > DOCUMENTATION_METADATA_MAX_DEFINITIONS) {
            throw metadataInventoryFailure("metadata exceeds 2048 definitions in a category")
        }
    }

    if (!projectRoot.isEmpty()) {
        // Module roots are already canonicalized during discovery; compare on the
        // same normalized spelling so a relative or symlinked --project does not
        // make an already-read root look uncovered and read it a second time.
        let normalizedRoot = try {
            canonicalize(projectRoot).toString()
        } catch (_: Exception) {
            projectRoot
        }
        var rootCovered = false
        for (moduleRoot in source.metadataModuleRoots) {
            if (moduleRoot.actualRoot == normalizedRoot) {
                rootCovered = true
                break
            }
        }
        if (!rootCovered) { validateDescriptorConfiguration(normalizedRoot) }
    }

    let packages = ArrayList<MetadataPackageScope>()
    for (pkg in source.packages) {
        packages.add(MetadataPackageScope(pkg.moduleId, pkg.name))
    }

    var needsIdentityProjection = false
    for (moduleConfiguration in moduleConfigurations) {
        for (group in moduleConfiguration.config.groups) {
            if (metadataHasOwnerSelector(group)) { needsIdentityProjection = true }
        }
    }
    let containers = ArrayList<MetadataContainer>()
    if (needsIdentityProjection) {
        let identities = identityProjection(source.declarations, HashMap<String, SemanticDeclaration>(),
            "syntax", false, identityTopologyForSources(source.declarations))
        var index: Int64 = 0
        while (index < source.declarations.size && index < identities.size) {
            let declaration = source.declarations[index]
            if (declaration.isContainer && metadataEligibleOwnerKind(declaration.kind)) {
                let identity = identities[index]
                containers.add(MetadataContainer(declaration.sourceKey, declaration.moduleId,
                    declaration.packageName, declaration.kind, identity.qualifiedName, identity.id))
            }
            index++
        }
    }
    source.metadataInventory = DocumentationMetadataInventory(
        moduleConfigurations: moduleConfigurations.toArray(), packages: packages.toArray(),
        containers: containers.toArray())
}

private func metadataBindingDiagnostic(documentation: DocumentationSet, code: String,
    message: String, line: Int64, configPath: String): Unit {
    documentation.diagnostics.add(Diagnostic("error", code, message,
        source: Some(SourceLocation(configPath, line, 1, line, 1))))
}

private func metadataOwnerCandidates(inventory: DocumentationMetadataInventory,
    moduleId: String, config: MetadataGroupConfig): ArrayList<MetadataContainer> {
    let candidates = ArrayList<MetadataContainer>()
    let seenSourceKeys = HashSet<String>()
    for (container in inventory.containers) {
        if (container.moduleId != moduleId || container.packageName != config.packageName) { continue }
        var matches = false
        if (let Some(owner) <- config.owner) {
            matches = container.qualifiedName == owner
        }
        if (let Some(ownerId) <- config.ownerId) {
            matches = matches || container.sourceSymbolId == ownerId
            if (let Some(survivingId) <- inventory.survivingId(container.sourceKey)) {
                matches = matches || survivingId == ownerId
            }
        }
        if (matches && seenSourceKeys.add(container.sourceKey)) { candidates.add(container) }
    }
    candidates
}

protected func prepareDocumentationMetadata(documentation: DocumentationSet): Unit {
    let inventory = documentation.metadataInventory
    let resolvedGroups = ArrayList<ResolvedMetadataGroup>()
    let groupCounts = HashMap<String, Int64>()
    let resolvedTags = ArrayList<ResolvedMetadataTag>()
    let tagCounts = HashMap<String, Int64>()

    for (moduleConfiguration in inventory.moduleConfigurations) {
        for (config in moduleConfiguration.config.groups) {
            if (!metadataPackageExists(inventory, moduleConfiguration.moduleId, config.packageName)) {
                metadataBindingDiagnostic(documentation, "CJDOC3134",
                    "metadata group references a package or owner that does not exist in this module",
                    config.line, moduleConfiguration.configPath)
                continue
            }

            var ownerSourceKey: ?String = None
            if (metadataHasOwnerSelector(config)) {
                let candidates = metadataOwnerCandidates(inventory, moduleConfiguration.moduleId, config)
                if (candidates.isEmpty()) {
                    metadataBindingDiagnostic(documentation, "CJDOC3134",
                        "metadata group references a package or owner that does not exist in this module",
                        config.line, moduleConfiguration.configPath)
                    continue
                }
                if (candidates.size > 1) {
                    metadataBindingDiagnostic(documentation, "CJDOC3135",
                        "metadata group owner is ambiguous; use owner-id to select one declaration",
                        config.line, moduleConfiguration.configPath)
                    continue
                }
                ownerSourceKey = Some(candidates[0].sourceKey)
            }

            let scopeKey = metadataGroupScopeKey(moduleConfiguration.moduleId,
                config.packageName, ownerSourceKey, config.id)
            resolvedGroups.add(ResolvedMetadataGroup(moduleConfiguration.moduleId,
                ownerSourceKey, config, scopeKey, moduleConfiguration.configPath))
            groupCounts[scopeKey] = match (groupCounts.get(scopeKey)) {
                case Some(count) => count + 1
                case None => 1
            }
        }
        for (config in moduleConfiguration.config.tags) {
            let scopeKey = metadataTagScopeKey(moduleConfiguration.moduleId, config.id)
            resolvedTags.add(ResolvedMetadataTag(moduleConfiguration.moduleId, config, scopeKey,
                moduleConfiguration.configPath))
            tagCounts[scopeKey] = match (tagCounts.get(scopeKey)) {
                case Some(count) => count + 1
                case None => 1
            }
        }
    }

    let groups = ArrayList<api_model.DocumentationGroupDefinition>()
    for (resolved in resolvedGroups) {
        if (groupCounts[resolved.scopeKey] > 1) {
            metadataBindingDiagnostic(documentation, "CJDOC3136",
                "metadata definitions duplicate the same scoped ID; all competing definitions are invalid",
                resolved.config.line, resolved.configPath)
            continue
        }
        var ownerId: ?String = None
        if (let Some(sourceKey) <- resolved.ownerSourceKey) {
            ownerId = inventory.survivingId(sourceKey)
            if (ownerId.isNone()) { continue }
        }
        groups.add(api_model.DocumentationGroupDefinition(resolved.moduleId,
            resolved.config.packageName, resolved.config.id, resolved.config.title,
            ownerId: ownerId, titles: resolved.config.titles, order: resolved.config.order))
    }

    let tags = ArrayList<api_model.DocumentationTagDefinition>()
    for (resolved in resolvedTags) {
        if (tagCounts[resolved.scopeKey] > 1) {
            metadataBindingDiagnostic(documentation, "CJDOC3136",
                "metadata definitions duplicate the same scoped ID; all competing definitions are invalid",
                resolved.config.line, resolved.configPath)
            continue
        }
        tags.add(api_model.DocumentationTagDefinition(resolved.moduleId,
            resolved.config.id, resolved.config.title, titles: resolved.config.titles))
    }

    documentation.metadata = api_model.DocumentationMetadata(
        groups: groups.toArray(), tags: tags.toArray())
}
