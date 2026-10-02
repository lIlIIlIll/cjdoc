"""Reviewed behavior registry; targets always come from the resolved manifest."""
from __future__ import annotations

JOURNEYS = frozenset({"members", "types", "contracts", "resources", "guides", "search",
                     "doctest", "diff", "versions", "quality", "external", "downloads",
                     "machine", "diagnostics", "authoring", "extension"})
VIEWPORTS = {"desktop": (1440, 1000), "narrow": (960, 900), "mobile": (390, 844)}
TRANSPORTS = {"root": ("http", "/"), "subpath": ("http", "/cjdoc-preview/"),
              "offline": ("file", None)}
SCENARIOS = {
    f"{journey}-{transport}-{viewport}": (journey, mode, width, height, "light", prefix)
    for journey in sorted(JOURNEYS)
    for transport, (mode, prefix) in TRANSPORTS.items()
    for viewport, (width, height) in VIEWPORTS.items()
}
# Keep the reviewed PR #53 scenarios executable for callers of the original contract.
SCENARIOS.update({
    "member-desktop-light-root": ("members", "http", 1280, 900, "light", "/"),
    "member-desktop-dark-subpath": ("members", "http", 1280, 900, "dark", "/cjdoc-preview/"),
    "member-mobile-dark-subpath": ("members", "http", 390, 844, "dark", "/cjdoc-preview/"),
    "member-offline": ("members", "file", 1280, 900, "light", None),
    "search-root": ("search", "http", 1280, 900, "light", "/"),
    "search-subpath": ("search", "http", 1280, 900, "dark", "/cjdoc-preview/"),
    "search-offline": ("search", "file", 1280, 900, "light", None),
})

# Browser timings run from the real input/click event through completed UI
# assertions. Pre-click scrolling is recorded separately. These are controlled
# CI regression ceilings, not claims about end-user latency.
BUDGETS = {"siteBytes": 80_000_000, "offlineBytes": 16_000_000,
           "queryMs": 1500, "expandMs": 1000, "listHeight": 6000,
           "compactRowHeight": 220, "splitContentTop": 260,
           "homepageActivations": 1, "homepageDocumentNavigations": 1}
