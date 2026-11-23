protected package cjdoc.documentation.metadata

import std.collection.*

protected class MetadataModuleConfiguration {
    protected let moduleId: String
    protected let configPath: String
    protected let config: DocumentationMetadataConfig

    protected init(moduleId: String, configPath: String, config: DocumentationMetadataConfig) {
        this.moduleId = moduleId
        this.configPath = configPath
        this.config = config
    }
}

protected class MetadataPackageScope {
    protected let moduleId: String
    protected let packageName: String

    protected init(moduleId: String, packageName: String) {
        this.moduleId = moduleId
        this.packageName = packageName
    }
}

protected class MetadataContainer {
    protected let sourceKey: String
    protected let moduleId: String
    protected let packageName: String
    protected let kind: String
    protected let qualifiedName: String
    protected let sourceSymbolId: String

    protected init(sourceKey: String, moduleId: String, packageName: String, kind: String,
        qualifiedName: String, sourceSymbolId: String) {
        this.sourceKey = sourceKey
        this.moduleId = moduleId
        this.packageName = packageName
        this.kind = kind
        this.qualifiedName = qualifiedName
        this.sourceSymbolId = sourceSymbolId
    }
}

/** Generation-only source evidence; never serialized into Doc IR. */
protected class DocumentationMetadataInventory {
    private let moduleConfigurationsStorage: ArrayList<MetadataModuleConfiguration>
    private let packagesStorage: ArrayList<MetadataPackageScope>
    private let containersStorage: ArrayList<MetadataContainer>
    private var survivingIdsBySourceKey = HashMap<String, String>()
    private var survivorsCaptured = false

    protected init(moduleConfigurations!: Array<MetadataModuleConfiguration> = [],
        packages!: Array<MetadataPackageScope> = [], containers!: Array<MetadataContainer> = []) {
        this.moduleConfigurationsStorage = ArrayList<MetadataModuleConfiguration>(moduleConfigurations)
        this.packagesStorage = ArrayList<MetadataPackageScope>(packages)
        this.containersStorage = ArrayList<MetadataContainer>(containers)
    }

    protected prop moduleConfigurations: ReadOnlyList<MetadataModuleConfiguration> {
        get() { moduleConfigurationsStorage }
    }
    protected prop packages: ReadOnlyList<MetadataPackageScope> { get() { packagesStorage } }
    protected prop containers: ReadOnlyList<MetadataContainer> { get() { containersStorage } }

    protected func captureSurvivingIds(idsBySourceKey: HashMap<String, String>): Unit {
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

    protected func survivingId(sourceKey: String): ?String {
        survivingIdsBySourceKey.get(sourceKey)
    }
}

protected func metadataOwnerNameSelectorKey(moduleId: String, packageName: String,
    ownerName: String): String {
    "${moduleId.size}:${moduleId}${packageName.size}:${packageName}${ownerName.size}:${ownerName}"
}

protected func metadataOwnerIdSelectorKey(moduleId: String, packageName: String,
    ownerId: String): String {
    "${moduleId.size}:${moduleId}${packageName.size}:${packageName}${ownerId.size}:${ownerId}"
}
