package cjdoc

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func graphProofNode(rows: ArrayList<DependencyInstance>, owner: String, name: String,
    content: String, child!: String = "", childContent!: String = "", childState!: String = "observed", childName!: String = "leaf"): Unit {
    rows.add(DependencyInstance(owner, name, "self-" + owner, "source", Sha256Digest.digest(content),
        "observed", "controlled source bytes", componentModuleId: owner))
    for (kind in ["std", "stdx", "toolchain"]) {
        rows.add(DependencyInstance(owner, kind, kind + owner, kind, "", "unknown", "not supplied"))
    }
    if (!child.isEmpty()) {
        rows.add(DependencyInstance(owner, childName, "leaf-" + owner, "source", Sha256Digest.digest(childContent),
            childState, "controlled selected input", componentModuleId: child))
    }
}

@Test
class DependencyGraphBindingTest {
    @TestCase
    func documentationQueriesStayInEntriesAndNeverBecomeDisplayRoots(): Unit {
        @Expect(isSafeAbsoluteDocumentationUrl("https://docs.example.test/api.md?plain=1&view=source#L3"))
        @Expect(isSafeDocumentationRoute("api.md?plain=1#L3"))
        @Expect(isSafeAbsoluteDocumentationUrl("https://docs.example.test/?view=source#overview"))
        for (base in ["https://docs.example.test/api?plain=1", "./api?plain=1",
            "https://docs.example.test/api#overview", "./api#overview"]) {
            @Expect(!safeDependencyExternalBase(base))
        }
        @Expect(safeDependencyExternalBase("https://docs.example.test/api"))
        @Expect(safeDependencyExternalBase("./api"))
    }

    @TestCase
    func dependencyGraphProofRebasesProducerModulePointersButRetainsSourceEvidence(): Unit {
        let selected = ArrayList<DependencyInstance>()
        let published = ArrayList<DependencyInstance>()
        graphProofNode(selected, "cjdoc:module:v1:selected", "library", "library")
        graphProofNode(published, "cjdoc:module:v1:producer", "library", "library")
        let actual = DependencyGraphIndex(selected)
        let inventory = DependencyGraphIndex(published)
        let work = DependencyNavigationWork()
        @Expect(inventory.binding(actual, "cjdoc:module:v1:selected", "cjdoc:module:v1:producer", work), "matched")
        @Expect(selected[1].state, "unknown")
        @Expect(published[1].state, "unknown")
    }

    @TestCase
    func dependencyGraphProofAndScopedInstanceChangeWhenOnlyTransitiveSourceChanges(): Unit {
        let selected = ArrayList<DependencyInstance>()
        let published = ArrayList<DependencyInstance>()
        graphProofNode(selected, "selected", "library", "unchanged library", child: "selected-leaf", childContent: "leaf B")
        graphProofNode(selected, "selected-leaf", "leaf", "leaf B")
        graphProofNode(published, "producer", "library", "unchanged library", child: "producer-leaf", childContent: "leaf A")
        graphProofNode(published, "producer-leaf", "leaf", "leaf A")
        let actual = DependencyGraphIndex(selected)
        let inventory = DependencyGraphIndex(published)
        let work = DependencyNavigationWork()
        @Expect(inventory.binding(actual, "selected", "producer", work), "mismatch")
        let edge = DependencyInstance("consumer", "library", "temporary", "source", "same-library-content", "observed", "fixture")
        let left = dependencyScopedInstance(edge, actual.context("selected", work).fingerprint, work)
        let right = dependencyScopedInstance(edge, inventory.context("producer", work).fingerprint, work)
        @Expect(left != right, true)
    }

    @TestCase
    func dependencyGraphProofRejectsUnknownAndConflictingTransitiveInputs(): Unit {
        for (state in ["unknown", "conflict"]) {
            let selected = ArrayList<DependencyInstance>()
            let published = ArrayList<DependencyInstance>()
            graphProofNode(selected, "selected", "library", "library", child: "selected-leaf", childContent: "leaf", childState: state)
            graphProofNode(selected, "selected-leaf", "leaf", "leaf")
            graphProofNode(published, "producer", "library", "library", child: "producer-leaf", childContent: "leaf")
            graphProofNode(published, "producer-leaf", "leaf", "leaf")
            let work = DependencyNavigationWork()
            @Expect(DependencyGraphIndex(published).binding(DependencyGraphIndex(selected), "selected", "producer", work),
                if (state == "conflict") { "conflict" } else { "unavailable" })
        }
    }

    @TestCase
    func dependencyGraphCyclesAreUnavailableAndIndependentOfTraversalOrder(): Unit {
        let rows = ArrayList<DependencyInstance>()
        graphProofNode(rows, "a", "library", "a", child: "b", childContent: "b")
        graphProofNode(rows, "b", "leaf", "b", child: "a", childContent: "a", childName: "library")
        let first = DependencyGraphIndex(rows)
        let second = DependencyGraphIndex(rows)
        let work = DependencyNavigationWork()
        @Expect(first.context("a", work).cyclic, true)
        @Expect(second.context("b", work).cyclic, true)
        @Expect(first.context("a", work).fingerprint, "")
        @Expect(second.context("a", work).fingerprint, "")
        @Expect(second.binding(first, "a", "a", work), "unavailable")
    }

    @TestCase
    func dependencyNavigationBudgetCannotBeResetAfterExhaustion(): Unit {
        let work = DependencyNavigationWork()
        @Expect(work.consumeBytes(32 * 1024 * 1024 + 1), false)
        @Expect(work.exhausted, true)
        @Expect(work.consumeBytes(0), false)
        @Expect(work.take(), false)
        let rows = ArrayList<DependencyInstance>()
        graphProofNode(rows, "a", "library", "library")
        @Expect(DependencyGraphIndex(rows).context("a", work).fingerprint, "")
    }
}
