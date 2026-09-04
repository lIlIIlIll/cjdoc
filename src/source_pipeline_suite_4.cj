package cjdoc

import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*


@Test
class SourcePipelineSuite4 {
    @TestCase
    func rejectsOversizedManifestAndSourceThroughPublicApi(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let manifestRoot = temporary.join("manifest")
            Directory.create(manifestRoot.join("src"), recursive: true)
            File.writeTo(manifestRoot.join("cjpm.toml"),
                Array<Byte>(32 * 1024 * 1024 + 1, repeat: b' '))
            let manifestResult = DocumentationEngine().generate(GenerationRequest(
                manifestRoot.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(manifestResult.status, "partial")
            @Expect(containsDiagnostic(manifestResult, "CJDOC1010"), true)
            for (diagnostic in manifestResult.diagnostics) {
                @Expect(diagnostic.message.contains(temporary.toString()), false)
            }

            let sourceRoot = temporary.join("source")
            Directory.create(sourceRoot.join("src"), recursive: true)
            File.writeTo(sourceRoot.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "oversized_source"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(sourceRoot.join("src/api.cj"),
                Array<Byte>(32 * 1024 * 1024 + 1, repeat: b' '))
            let sourceResult = DocumentationEngine().generate(GenerationRequest(
                sourceRoot.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(sourceResult.status, "partial")
            @Expect(containsDiagnostic(sourceResult, "CJDOC1026"), true)
            for (diagnostic in sourceResult.diagnostics) {
                @Expect(diagnostic.message.contains(temporary.toString()), false)
                if (diagnostic.code == "CJDOC1026") {
                    let range = diagnostic.source.getOrThrow()
                    @Expect(range.start.byteOffset, 0)
                    @Expect(range.end.byteOffset, 0)
                }
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func publicEngineFailsClosedWithoutParserWorker(): Unit {
        let documentation = DocumentationEngine().generate(GenerationRequest(
            FIXTURES + "basic", lintProfile: "off", audience: "all"))
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 0)
        @Expect(containsDiagnostic(documentation, "CJDOC1020"), true)
    }

    @TestCase
    func scansWorkspaceAndOptInPathDependencies(): Unit {
        let workspace = generateFixture("workspace")
        @Expect(workspace.modules.size, 2)
        @Expect(workspace.packages.size, 2)
        @Expect(workspace.declarations.size, 2)

        let dependencies = generateFixture("path_dependencies", includePathDependencies: true)
        @Expect(dependencies.modules.size, 3)
        @Expect(dependencies.packages.size, 3)
        @Expect(dependencies.declarations.size, 3)
        @Expect(dependencies.diagnostics.size, 0)
        @Expect(declarationNamed(dependencies, "alphaApi").source.start.byteOffset > 0, true)
        @Expect(declarationNamed(dependencies, "betaApi").source.start.byteOffset > 0, true)
    }

    @TestCase
    func honorsCustomSourceDirectoriesAcrossEveryModuleDiscoveryPath(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("custom-source-roots")
            let explicit = temporary.join("explicit")
            let cache = temporary.join("cjpm-cache")
            Directory.create(root.join("code/root"), recursive: true)
            Directory.create(root.join("member/member-code"), recursive: true)
            Directory.create(root.join("dep/lib"), recursive: true)
            Directory.create(explicit.join("generated"), recursive: true)
            Directory.create(cache.join("git/cached/abc123/cache-code"), recursive: true)

            File.writeTo(root.join("cjpm.toml"), """
                package.name = "custom_root"
                package.src-dir = "code/root"

                [workspace]
                members = ["member"]

                [dependencies.dep]
                path = "dep"
                """.toArray())
            File.writeTo(root.join("cjpm.lock"), """
                [requires]
                cached = { git = "https://example.invalid/cached.git", commitId = "abc123" }
                """.toArray())
            File.writeTo(root.join("member/cjpm.toml"), """
                [package]
                name = "custom_member"
                src-dir = "member-code"
                """.toArray())
            File.writeTo(root.join("dep/cjpm.toml"), """
                [package]
                name = "custom_dep"
                src-dir = "lib"
                """.toArray())
            File.writeTo(explicit.join("cjpm.toml"), """
                [package]
                name = "custom_explicit"
                src-dir = "generated"
                """.toArray())
            File.writeTo(cache.join("git/cached/abc123/cjpm.toml"), """
                [package]
                name = "custom_cached"
                src-dir = "cache-code"
                """.toArray())
            File.writeTo(root.join("code/root/root.cj"),
                "package custom_root\npublic func rootCustom(): Unit {}\n".toArray())
            File.writeTo(root.join("member/member-code/member.cj"),
                "package custom_member\npublic func memberCustom(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/lib/dep.cj"),
                "package custom_dep\npublic func pathCustom(): Unit {}\n".toArray())
            File.writeTo(explicit.join("generated/explicit.cj"),
                "package custom_explicit\npublic func explicitCustom(): Unit {}\n".toArray())
            File.writeTo(cache.join("git/cached/abc123/cache-code/cached.cj"),
                "package custom_cached\npublic func cachedCustom(): Unit {}\n".toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, includeCachedDependencies: true,
                dependencySources: [DependencySourceInput("explicit", explicit.toString())],
                cjpmCacheRoot: Some(cache.toString()), astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "complete")
            @Expect(documentation.modules.size, 5)
            @Expect(declarationNamed(documentation, "rootCustom").source.path,
                "code/root/root.cj")
            @Expect(declarationNamed(documentation, "memberCustom").source.path,
                "member/member-code/member.cj")
            @Expect(declarationNamed(documentation, "pathCustom").source.path,
                "dependencies/custom_dep/lib/dep.cj")
            @Expect(declarationNamed(documentation, "explicitCustom").source.path,
                "dependencies/explicit/generated/explicit.cj")
            @Expect(declarationNamed(documentation, "cachedCustom").source.path,
                "dependencies/cached/cache-code/cached.cj")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func attachesPureWorkspaceRootPathDependenciesToMembers(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("pure-workspace")
            Directory.create(root.join("member/src"), recursive: true)
            Directory.create(root.join("shared/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                [workspace]
                members = ["member"]

                [dependencies.shared]
                path = "shared"
                """.toArray())
            File.writeTo(root.join("member/cjpm.toml"),
                "[package]\nname = \"workspace_member\"\n".toArray())
            File.writeTo(root.join("shared/cjpm.toml"),
                "[package]\nname = \"workspace_shared\"\n".toArray())
            File.writeTo(root.join("member/src/member.cj"),
                "package workspace_member\npublic func memberApi(): Unit {}\n".toArray())
            File.writeTo(root.join("shared/src/shared.cj"),
                "package workspace_shared\npublic func sharedApi(): Unit {}\n".toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "complete")
            @Expect(documentation.modules.size, 2)
            @Expect(documentation.declarations.size, 2)
            var workspaceEdges: Int64 = -1
            for (module in documentation.modules) {
                if (module.role == "workspace") { workspaceEdges = module.dependencyIds.size }
            }
            @Expect(workspaceEdges, 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func selectsCurrentTargetDependenciesAndMarksUnsupportedProfilesPartial(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let target = testCjpmTarget()
            let root = temporary.join("target-dependencies")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("dep/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), ("""
                [package]
                name = "target_root"

                [target.${target}.dependencies.dep]
                path = "dep"
                """).toArray())
            File.writeTo(root.join("dep/cjpm.toml"),
                "[package]\nname = \"target_dep\"\n".toArray())
            File.writeTo(root.join("src/root.cj"),
                "package target_root\npublic func targetRoot(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/src/dep.cj"),
                "package target_dep\npublic func selectedTargetDep(): Unit {}\n".toArray())

            let selected = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(selected.status, "complete")
            @Expect(selected.modules.size, 2)
            @Expect(declarationNamed(selected, "selectedTargetDep").kind, "function")

            File.writeTo(root.join("cjpm.toml"), ("""
                [package]
                name = "target_root"

                [target.${target}.debug.dependencies.dep]
                path = "dep"
                """).toArray())
            let profileSpecific = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(profileSpecific.status, "partial")
            @Expect(profileSpecific.modules.size, 1)
            @Expect(profileSpecific.declarations.size, 1)
            @Expect(containsDiagnostic(profileSpecific, "CJDOC1016"), true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func rejectsDriveLikePackageSourceDirectoriesBeforeHostPathResolution(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("drive-like-source")
            Directory.create(root.join("src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                package.name = "drive_like_source"
                package.src-dir = "C:/source"
                """.toArray())
            File.writeTo(root.join("src/must_not_scan.cj"),
                "package drive_like_source\npublic func mustNotScan(): Unit {}\n".toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "partial")
            @Expect(documentation.modules.size, 1)
            @Expect(documentation.declarations.size, 0)
            @Expect(containsDiagnostic(documentation, "CJDOC1010"), true)
            @Expect(relativePathFromResolved("/project",
                "/project/C:/source/api.cj").isNone(), true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func keepsRootWhenWorkspaceMemberIsBadAndScansSrcTarget(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("root")
            Directory.create(root.join("src/target"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "root_kept"
                version = "0.1.0"
                output-type = "static"

                [workspace]
                members = ["missing"]
                """.toArray())
            File.writeTo(root.join("src/root.cj"), """
                package root_kept

                public func rootApi(): Unit {}
                """.toArray())
            File.writeTo(root.join("src/target/kept.cj"), """
                package root_kept

                public func targetApi(): Unit {}
                """.toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "partial")
            @Expect(containsDiagnostic(documentation, "CJDOC1010"), true)
            @Expect(documentation.modules.size, 1)
            @Expect(documentation.declarations.size, 2)
            @Expect(declarationNamed(documentation, "rootApi").kind, "function")
            @Expect(declarationNamed(documentation, "targetApi").kind, "function")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func skipsSelfAndCyclicDependencyEdgesAsPartialSource(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("cycle")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("dep/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "cycle_root"
                version = "0.1.0"
                output-type = "static"

                [dependencies]
                self = { path = "." }
                dep = { path = "dep" }
                """.toArray())
            File.writeTo(root.join("dep/cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "cycle_dep"
                version = "0.1.0"
                output-type = "static"

                [dependencies]
                root = { path = ".." }
                """.toArray())
            File.writeTo(root.join("src/root.cj"),
                "package cycle_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/src/dep.cj"),
                "package cycle_dep\npublic func depApi(): Unit {}\n".toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "partial")
            @Expect(diagnosticCount(documentation, "CJDOC1016"), 1)
            @Expect(documentation.modules.size, 2)
            @Expect(documentation.declarations.size, 2)
            var rootEdges: Int64 = -1
            var dependencyEdges: Int64 = -1
            for (module in documentation.modules) {
                if (module.role == "root") { rootEdges = module.dependencyIds.size }
                if (module.role == "pathDependency") {
                    dependencyEdges = module.dependencyIds.size
                }
            }
            @Expect(rootEdges, 1)
            @Expect(dependencyEdges, 0)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }


}
