"""Member routes are tied to native details identities, not nearby names."""
from __future__ import annotations

import unittest

from showcase_contract.routes import MemberLinks
from showcase_contract.site import ContractError


def _row(anchor: str, href: str) -> str:
    return (
        '<div class="member-row">'
        f'<details class="declaration-summary member-detail" data-cjdoc-member id="{anchor}">'
        '<summary>public func add(value: String): Unit</summary>'
        '<div class="member-detail-body"><p>Parameters</p></div>'
        '</details>'
        '<div class="member-detail-actions" role="group">'
        '<button type="button" data-cjdoc-member-actions-toggle>More</button>'
        '<div class="member-action-list">'
        f'<a class="member-action member-permalink" href="{href}">Standalone</a>'
        '<button class="member-action-copy">Copy</button>'
        '</div></div></div>'
    )


class MemberLinksTest(unittest.TestCase):
    def test_sibling_actions_preserve_overload_identities(self) -> None:
        html = (
            '<main><div class="declaration-list">'
            + _row("symbol-add-int64", "../symbols/add-int64.html")
            + '<section class="member-group">'
            + _row("symbol-add-string", "../symbols/add-string.html")
            + '</section></div></main>'
        )
        self.assertEqual(
            MemberLinks(html).members,
            [
                ("symbol-add-int64", "../symbols/add-int64.html"),
                ("symbol-add-string", "../symbols/add-string.html"),
            ],
        )

    def test_old_nested_permalink_remains_readable(self) -> None:
        html = (
            '<details data-cjdoc-member id="symbol-old"><summary>old</summary>'
            '<div class="member-detail-body"><a class="member-permalink" href="old.html">'
            'Standalone</a></div></details>'
        )
        self.assertEqual(MemberLinks(html).members, [("symbol-old", "old.html")])

    def test_actions_without_native_member_anchor_fail(self) -> None:
        html = (
            '<div class="member-row"><details data-cjdoc-member><summary>x</summary></details>'
            '<div class="member-detail-actions">'
            '<a class="member-permalink" href="x.html">x</a></div></div>'
        )
        with self.assertRaises(ContractError):
            MemberLinks(html)

    def test_missing_or_duplicate_permalink_fails_closed(self) -> None:
        missing = (
            '<div class="member-row"><details data-cjdoc-member id="one">'
            '<summary>x</summary></details><div class="member-detail-actions"></div></div>'
        )
        duplicated = _row("one", "one.html").replace(
            '<button class="member-action-copy">Copy</button>',
            '<a class="member-permalink" href="other.html">Other</a>',
        )
        for html in (missing, duplicated):
            with self.subTest(html=html):
                with self.assertRaises(ContractError):
                    MemberLinks(html)

    def test_link_outside_its_action_container_fails(self) -> None:
        html = (
            '<div class="member-row"><details data-cjdoc-member id="one">'
            '<summary>x</summary></details>'
            '<a class="member-permalink" href="one.html">Invalid position</a>'
            '<div class="member-detail-actions"></div></div>'
        )
        with self.assertRaises(ContractError):
            MemberLinks(html)


if __name__ == "__main__":
    unittest.main()
