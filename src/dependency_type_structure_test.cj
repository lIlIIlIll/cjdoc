package cjdoc

import std.unittest.*
import std.unittest.testmacro.*

private func dependencyStructureOrigin(source: String): SourceFileOrigin {
    SourceFileOrigin("src/api.cj", "", "", "", "fixture", capturedSource: source)
}

// Like SourceSignatureLexemeTest, these cases exercise the source/AST boundary
// in isolation. Public generate/render coverage lives with dependency binding.
@Test
class DependencyTypeStructureTest {
    @TestCase
    func nestedGenericOptionalAndTupleTypesUseTheirActualAstChildren(): Unit {
        let shape = dependencyTypeShape("Box<?(Token, other.Value<Int64>)>").getOrThrow()
        @Expect(shape.kind, "generic")
        @Expect(shape.head, "Box")
        @Expect(shape.children.size, 1)
        let optional = shape.children[0]
        @Expect(optional.kind, "optional")
        @Expect(optional.nullable, true)
        let tuple = optional.children[0]
        @Expect(tuple.kind, "tuple")
        @Expect(tuple.children.size, 2)
        @Expect(tuple.children[0].head, "Token")
        let qualified = tuple.children[1]
        @Expect(qualified.head, "other.Value")
        @Expect(qualified.kind, "generic")
        @Expect(qualified.children[0].kind, "primitive")
        @Expect(qualified.children[0].head, "Int64")
    }

    @TestCase
    func functionParametersPrecedeTheStructuredReturnType(): Unit {
        let shape = dependencyTypeShape("(Token, ?Box<Value>) -> (Reply, Int64)").getOrThrow()
        @Expect(shape.kind, "function")
        @Expect(shape.children.size, 3)
        @Expect(shape.children[0].head, "Token")
        @Expect(shape.children[1].kind, "optional")
        @Expect(shape.children[1].children[0].head, "Box")
        @Expect(shape.children[2].kind, "tuple")
        @Expect(shape.children[2].children[0].head, "Reply")
        let nullary = dependencyTypeShape("() -> (() -> Token)").getOrThrow()
        @Expect(nullary.children.size, 1)
        @Expect(nullary.children[0].kind, "function")
        @Expect(nullary.children[0].children.size, 1)
        @Expect(nullary.children[0].children[0].head, "Token")
    }

    @TestCase
    func childSpellingsRetainTheCapturedSourceNotRegeneratedTokens(): Unit {
        let raw = "Box<  ?Token, ( Left , Right ) >"
        let shape = dependencyTypeShape(raw).getOrThrow()
        @Expect(shape.spelling, raw)
        @Expect(shape.children[0].spelling, "?Token")
        @Expect(shape.children[1].spelling, "( Left , Right )")
        @Expect(shape.children[1].children[0].spelling, "Left")
        @Expect(shape.children[1].children[1].spelling, "Right")
    }

    @TestCase
    func malformedOrUnsupportedTypesDoNotProducePartialBindingEvidence(): Unit {
        for (spelling in ["", "Box<", "Token, Reply", "Token ->", "Token extra", "This"]) {
            @Expect(dependencyTypeShape(spelling).isNone(), true)
        }
        // A generic receiver is a member-type lookup, not a package path.
        @Expect(dependencyTypeShape("Box<Int64>.Member").isNone(), true)
    }

    @TestCase
    func singleAliasAndPackageAliasImportsRespectTheirExposedNames(): Unit {
        let origin = dependencyStructureOrigin("""
            package fixture
            import dependency.Token
            import dependency.Result as Reply
            import dependency.types as types
            """)
        let single = dependencyImportCandidates(origin, "Token")
        @Expect(single.size, 2)
        @Expect(single[0], "dependency.Token")
        @Expect(dependencyImportCandidates(origin, "dependency.Token").isEmpty(), true)
        let alias = dependencyImportCandidates(origin, "Reply<Value>")
        @Expect(alias.size, 2)
        @Expect(alias[0], "dependency.Result")
        let member = dependencyImportCandidates(origin, "types.Value")
        @Expect(member.size, 1)
        @Expect(member[0], "dependency.types.Value")
        let hiddenOriginal = dependencyImportCandidates(origin, "Result")
        @Expect(hiddenOriginal.size, 1)
        @Expect(hiddenOriginal[0], "std.core.Result")
        @Expect(dependencyImportCandidates(origin, "dependency.Result").isEmpty(), true)
    }

    @TestCase
    func multiImportsPreserveOrganizationAndEachItemAlias(): Unit {
        let origin = dependencyStructureOrigin("""
            package fixture
            import acme::dependency.types.{Token, Result as Reply}
            """)
        let single = dependencyImportCandidates(origin, "Token")
        @Expect(single.size, 2)
        @Expect(single[0], "acme::dependency.types.Token")
        let alias = dependencyImportCandidates(origin, "Reply")
        @Expect(alias.size, 2)
        @Expect(alias[0], "acme::dependency.types.Result")
        let hiddenOriginal = dependencyImportCandidates(origin, "Result")
        @Expect(hiddenOriginal.size, 1)
        @Expect(hiddenOriginal[0], "std.core.Result")
    }

    @TestCase
    func wildcardCandidatesAreExactPackagesNotUniqueResolutionClaims(): Unit {
        let origin = dependencyStructureOrigin("""
            package fixture
            import dependency.one.*
            import dependency.two.*
            """)
        let candidates = dependencyImportCandidates(origin, "Token")
        @Expect(candidates.size, 3)
        @Expect(candidates[0], "dependency.one.Token")
        @Expect(candidates[1], "dependency.two.Token")
        @Expect(dependencyImportCandidates(origin, "child.Token").isEmpty(), true)
        @Expect(dependencyImportCandidates(origin, "dependency.one.Token").isEmpty(), true)
    }

    @TestCase
    func importingAPackageDoesNotImportItsSubpackages(): Unit {
        let origin = dependencyStructureOrigin("package fixture\nimport dependency\n")
        let candidates = dependencyImportCandidates(origin, "dependency.Token")
        @Expect(candidates.size, 1)
        @Expect(candidates[0], "dependency.Token")
        @Expect(dependencyImportCandidates(origin, "dependency.child.Token").isEmpty(), true)
        @Expect(dependencyImportCandidates(dependencyStructureOrigin(""), "dependency.Token").isEmpty(), true)
    }

    @TestCase
    func unknownConditionalImportCannotSupplyOrDisambiguateABinding(): Unit {
        let origin = dependencyStructureOrigin("""
            package fixture
            @When[feature == "on"]
            import dependency.Token
            import other.Token
            import dependency.Result
            """)
        @Expect(dependencyImportCandidates(origin, "Token").isEmpty(), true)
        let unrelated = dependencyImportCandidates(origin, "Result")
        @Expect(unrelated.size, 2)
        @Expect(unrelated[0], "dependency.Result")
    }

    @TestCase
    func capturedSourceWinsOverAnnotationStrippedImportStrings(): Unit {
        let origin = SourceFileOrigin("src/api.cj", "", "", "", "fixture",
            imports: ["import dependency.Token"], capturedSource: """
                package fixture
                @When[feature == "on"]
                import dependency.Token
                """)
        @Expect(dependencyImportCandidates(origin, "Token").isEmpty(), true)
        let importsOnly = SourceFileOrigin("src/api.cj", "", "", "", "fixture",
            imports: ["import dependency.Token"])
        let candidates = dependencyImportCandidates(importsOnly, "Token")
        @Expect(candidates.size, 2)
        @Expect(candidates[0], "dependency.Token")
    }

    @TestCase
    func implicitCoreImportUsesTheLanguageRuleWithoutGuessingPrimitiveTargets(): Unit {
        let origin = dependencyStructureOrigin("package fixture\n")
        for (spelling in ["Int64", "Bool", "Unit"]) {
            @Expect(dependencyImportCandidates(origin, spelling).isEmpty(), true)
        }
        for ((spelling, head) in [("String", "String"), ("Array<Int64>", "Array"),
            ("Option<Int64>", "Option"), ("UnindexedType", "UnindexedType")]) {
            let candidates = dependencyImportCandidates(origin, spelling)
            @Expect(candidates.size, 1)
            @Expect(candidates[0], "std.core." + head)
        }
        let explicit = dependencyStructureOrigin("package fixture\nimport std.core.String\n")
        let candidates = dependencyImportCandidates(explicit, "String")
        @Expect(candidates.size, 1)
        @Expect(candidates[0], "std.core.String")
    }

    @TestCase
    func conditionalStringImportSuppressesTheImplicitCoreCandidate(): Unit {
        let origin = dependencyStructureOrigin("""
            package fixture
            @When[feature == "on"]
            import dependency.String
            """)
        @Expect(dependencyImportCandidates(origin, "String").isEmpty(), true)
    }

    @TestCase
    func explicitAndImplicitImportsPreservePotentialNameConflicts(): Unit {
        let origin = dependencyStructureOrigin("package fixture\nimport dependency.String\n")
        let candidates = dependencyImportCandidates(origin, "String")
        @Expect(candidates.size, 2)
        @Expect(candidates[0], "dependency.String")
        @Expect(candidates[1], "std.core.String")
    }

    @TestCase
    func memberImportsDoNotExposeTheirPackageQualification(): Unit {
        let origin = dependencyStructureOrigin("""
            package fixture
            import dependency.types.Token
            import dependency.other.*
            """)
        let single = dependencyImportCandidates(origin, "dependency.types.Token")
        @Expect(single.isEmpty(), true)
        let all = dependencyImportCandidates(origin, "dependency.other.Value")
        @Expect(all.isEmpty(), true)
        @Expect(dependencyImportCandidates(origin, "unimported.types.Token").isEmpty(), true)
        @Expect(dependencyImportCandidates(origin, "dependency.other.child.Value").isEmpty(), true)
    }
}
