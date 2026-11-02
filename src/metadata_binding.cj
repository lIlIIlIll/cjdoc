package cjdoc

import cjdoc.model as api_model
import std.collection.*

private let DOCUMENTATION_METADATA_MAX_DEFINITIONS: Int64 = 2048

internal class MetadataModuleConfiguration {
    let moduleId: String
    let configPath: String
    let config: DocumentationMetadataConfig

    init(moduleId: String, configPath: String, config: DocumentationMetadataConfig) {
        this.moduleId = moduleId
        this.configPath = configPath
        this.config = config
    }
}

internal class MetadataPackageScope {
    let moduleId: String
    let packageName: String

    init(moduleId: String, packageName: String) {
        this.moduleId = moduleId
        this.packageName = packageName
    }
}

internal class MetadataContainer {
    let sourceKey: String
    let moduleId: String
    let packageName: String
    let kind: String
    let qualifiedName: String
    let sourceSymbolId: String

    init(sourceKey: String, moduleId: String, packageName: String, kind: String,
        qualifiedName: String, sourceSymbolId: String) {
        this.sourceKey = sourceKey
        this.moduleId = moduleId
        this.packageName = packageName
        this.kind = kind
        this.qualifiedName = qualifiedName
        this.sourceSymbolId = sourceSymbolId
    }
}

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

/** Generation-only source evidence; never serialized into Doc IR. */
class DocumentationMetadataInventory {
    private let moduleConfigurationsStorage: ArrayList<MetadataModuleConfiguration>
    private let packagesStorage: ArrayList<MetadataPackageScope>
    private let containersStorage: ArrayList<MetadataContainer>
    private var survivingIdsBySourceKey = HashMap<String, String>()
    private var survivorsCaptured = false

    init(moduleConfigurations!: Array<MetadataModuleConfiguration> = [],
        packages!: Array<MetadataPackageScope> = [], containers!: Array<MetadataContainer> = []) {
        this.moduleConfigurationsStorage = ArrayList<MetadataModuleConfiguration>(moduleConfigurations)
        this.packagesStorage = ArrayList<MetadataPackageScope>(packages)
        this.containersStorage = ArrayList<MetadataContainer>(containers)
    }

    prop moduleConfigurations: ReadOnlyList<MetadataModuleConfiguration> {
        get() { moduleConfigurationsStorage }
    }
    prop packages: ReadOnlyList<MetadataPackageScope> { get() { packagesStorage } }
    prop containers: ReadOnlyList<MetadataContainer> { get() { containersStorage } }

    func captureSurvivingIds(idsBySourceKey: HashMap<String, String>): Unit {
        if (survivorsCaptured) { return }
        if (containers.size == 0) {
            survivorsCaptured = true
            return
        }
        let nameSelectors = HashSet<String>()
        let idSelectors = HashSet<String>()
        for (moduleConfiguration in moduleConfigurations) {
            for (config in moduleConfiguration.config.groups) {
                if (let Some(owner) <- config.owner) {
                    nameSelectors.add(metadataOwnerNameSelectorKey(moduleConfiguration.moduleId,
                        config.packageName, owner))
                }
                if (let Some(ownerId) <- config.ownerId) {
                    idSelectors.add(metadataOwnerIdSelectorKey(moduleConfiguration.moduleId,
                        config.packageName, ownerId))
                }
            }
        }
        let relevant = HashMap<String, String>()
        if (nameSelectors.size > 0 || idSelectors.size > 0) {
            for (container in containers) {
                let nameKey = metadataOwnerNameSelectorKey(container.moduleId,
                    container.packageName, container.qualifiedName)
                var matches = nameSelectors.contains(nameKey)
                if (!matches) {
                    matches = idSelectors.contains(metadataOwnerIdSelectorKey(container.moduleId,
                        container.packageName, container.sourceSymbolId))
                }
                let activeId = idsBySourceKey.get(container.sourceKey)
                if (!matches) {
                    if (let Some(id) <- activeId) {
                        matches = idSelectors.contains(metadataOwnerIdSelectorKey(
                            container.moduleId, container.packageName, id))
                    }
                }
                if (matches) {
                    if (let Some(id) <- activeId) { relevant[container.sourceKey] = id }
                }
            }
        }
        survivingIdsBySourceKey = relevant
        survivorsCaptured = true
    }

    func survivingId(sourceKey: String): ?String {
        survivingIdsBySourceKey.get(sourceKey)
    }
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
private func metadataOwnerNameSelectorKey(moduleId: String, packageName: String,
    ownerName: String): String {
    "${moduleId.size}:${moduleId}${packageName.size}:${packageName}${ownerName.size}:${ownerName}"
}

private func metadataOwnerIdSelectorKey(moduleId: String, packageName: String,
    ownerId: String): String {
    "${moduleId.size}:${moduleId}${packageName.size}:${packageName}${ownerId.size}:${ownerId}"
}

internal func captureDocumentationMetadataInventory(source: SourceSnapshot): Unit {
    let parsedByRoot = HashMap<String, DocumentationMetadataConfig>()
    let moduleConfigurations = ArrayList<MetadataModuleConfiguration>()
    var groupDefinitionCount: Int64 = 0
    var tagDefinitionCount: Int64 = 0
    for (moduleRoot in source.metadataModuleRoots) {
        let config = match (parsedByRoot.get(moduleRoot.actualRoot)) {
            case Some(value) => value
            case None =>
                let value = loadDocumentationMetadataConfig(moduleRoot.actualRoot)
                parsedByRoot[moduleRoot.actualRoot] = value
                value
        }
        moduleConfigurations.add(MetadataModuleConfiguration(moduleRoot.moduleId,
            moduleRoot.configPath, config))
        groupDefinitionCount += config.groups.size
        tagDefinitionCount += config.tags.size
        if (groupDefinitionCount > DOCUMENTATION_METADATA_MAX_DEFINITIONS ||
            tagDefinitionCount > DOCUMENTATION_METADATA_MAX_DEFINITIONS) {
            throw metadataInventoryFailure("metadata exceeds 2048 definitions in a category")
        }
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

internal func captureDocumentationMetadataSurvivors(inventory: DocumentationMetadataInventory,
    idsBySourceKey: HashMap<String, String>): Unit {
    inventory.captureSurvivingIds(idsBySourceKey)
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

internal func prepareDocumentationMetadata(documentation: DocumentationSet,
    request: GenerationRequest): Unit {
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
    // Root selection was captured per module; never fall back to projectRoot here.
    let _ = request.projectRoot
}
