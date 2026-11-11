"""Member routes are tied to native details identities, not nearby names."""
from __future__ import annotations

import unittest

from showcase_contract.routes import MemberLinks
from showcase_contract.site import ContractError


def _row(anchor: str, href: str) -> str:
    return (
        '<div class="cj-member-row">'
        f'<details class="cj-member" data-cjdoc-member id="{anchor}">'
        '<summary class="cj-member__summary">'
        '<code class="cj-signature-inline cj-member__signature">'
        'public func add(value: String): Unit</code></summary>'
        '<div class="cj-member__body"><h4 class="cj-params__title">Parameters</h4></div>'
        '</details>'
        '<div class="cj-member-actions" role="group" data-cjdoc-member-actions>'
        '<button type="button" class="cj-button cj-button--icon cj-member-actions__toggle"'
        ' data-cjdoc-member-actions-toggle aria-expanded="false">More</button>'
        '<div class="cj-member-actions__list">'
        '<a class="cj-member-actions__item cj-member-actions__item--standalone"'
        f' href="{href}"><span class="cj-member-actions__label">Standalone</span></a>'
        '<button class="cj-member-actions__item cj-member-actions__item--copy"'
        ' data-cjdoc-copy-link>Copy link</button>'
        '</div></div></div>'
    )


class MemberLinksTest(unittest.TestCase):
    def test_sibling_actions_preserve_overload_identities(self) -> None:
        html = (
            '<main><div class="cj-members">'
            + _row("symbol-add-int64", "../symbols/add-int64.html")
            + '<section class="cj-member-group" data-cjdoc-member-group>'
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

    def test_actions_without_native_member_anchor_fail(self) -> None:
        html = (
            '<div class="cj-member-row"><details data-cjdoc-member><summary>x</summary></details>'
            '<div class="cj-member-actions">'
            '<a class="cj-member-actions__item cj-member-actions__item--standalone"'
            ' href="x.html">x</a></div></div>'
        )
        with self.assertRaises(ContractError):
            MemberLinks(html)

    def test_missing_or_duplicate_permalink_fails_closed(self) -> None:
        missing = (
            '<div class="cj-member-row"><details data-cjdoc-member id="one">'
            '<summary>x</summary></details><div class="cj-member-actions"></div></div>'
        )
        duplicated = _row("one", "one.html").replace(
            '<button class="cj-member-actions__item cj-member-actions__item--copy"'
            ' data-cjdoc-copy-link>Copy link</button>',
            '<a class="cj-member-actions__item cj-member-actions__item--standalone"'
            ' href="other.html">Other</a>',
        )
        for html in (missing, duplicated):
            with self.subTest(html=html):
                with self.assertRaises(ContractError):
                    MemberLinks(html)

    def test_link_outside_its_action_container_fails(self) -> None:
        html = (
            '<div class="cj-member-row"><details data-cjdoc-member id="one">'
            '<summary>x</summary></details>'
            '<a class="cj-member-actions__item cj-member-actions__item--standalone"'
            ' href="one.html">Invalid position</a>'
            '<div class="cj-member-actions"></div></div>'
        )
        with self.assertRaises(ContractError):
            MemberLinks(html)


if __name__ == "__main__":
    unittest.main()
