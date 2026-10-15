#!/usr/bin/env python3
"""Behavior regression tests for the static showcase theme selector."""

from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class ShowcaseThemeTest(unittest.TestCase):
    def test_source_exposes_all_themes_and_no_binary_toggle(self) -> None:
        script = (ROOT / "site/showcase.js").read_text(encoding="utf-8")
        bootstrap = (ROOT / "site/theme-bootstrap.js").read_text(encoding="utf-8")
        homepage = (ROOT / "scripts/showcase_build/homepage.py").read_text(encoding="utf-8")
        for theme in ("system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"):
            with self.subTest(theme=theme):
                self.assertIn(f"['{theme}',", script)
                self.assertIn(f'"{theme}"', bootstrap)
        self.assertIn("dataset.themeChoice", bootstrap)
        self.assertIn("data-showcase-theme", (ROOT / "site/index.html").read_text(encoding="utf-8"))
        self.assertNotIn('"THEME": "Light / Dark"', homepage)
        self.assertNotIn('"THEME": "切换明暗"', homepage)

    @unittest.skipUnless(shutil.which("node"), "Node.js is needed for browser-script smoke tests")
    def test_selector_restores_chooses_closes_and_follows_system(self) -> None:
        assert_showcase_theme_picker_runtime()


def assert_showcase_theme_picker_runtime() -> None:
    bootstrap = (ROOT / "site/theme-bootstrap.js").read_text(encoding="utf-8")
    showcase = (ROOT / "site/showcase.js").read_text(encoding="utf-8")
    harness = r"""
const assert = require('node:assert/strict');
const vm = require('node:vm');

class Element {
  constructor(tag) {
this.tagName = tag;
this.children = [];
this.parentNode = null;
this.attrs = {};
this.dataset = {};
this.events = {};
this.hidden = false;
this.className = '';
this._text = '';
this.style = {};
this.inert = false;
this.tabIndex = tag === 'button' ? 0 : -1;
const values = new Set();
this.classList = {
  add: name => values.add(name),
  remove: name => values.delete(name),
  toggle: (name, flag) => flag ? values.add(name) : values.delete(name),
  contains: name => values.has(name),
};
  }
  appendChild(child) {
    if (child.parentNode) {
      const old = child.parentNode.children;
      old.splice(old.indexOf(child), 1);
    }
    this.children.push(child); child.parentNode = this; return child;
  }
  append(...children) { for (const child of children) this.appendChild(child); }
  insertBefore(child, sibling) {
    if (child.parentNode) {
      const old = child.parentNode.children;
      old.splice(old.indexOf(child), 1);
    }
    this.children.splice(this.children.indexOf(sibling), 0, child);
    child.parentNode = this;
  }
  setAttribute(key, value) { this.attrs[key] = value; }
  removeAttribute(key) { delete this.attrs[key]; }
  getAttribute(key) { return this.attrs[key] || null; }
  addEventListener(key, callback) { this.events[key] = callback; }
  focus() { this.focused = true; document.activeElement = this; }
  getClientRects() { return [{}]; }
  querySelectorAll() {
    const descendants = [];
    const walk = node => {
      for (const child of node.children) {
        if (child.tagName === 'button') descendants.push(child);
        walk(child);
      }
    };
    walk(this);
    return descendants;
  }
  contains(other) { return this === other || this.children.some(child => child.contains(other)); }
  set textContent(value) { this._text = value; this.children = []; }
  get textContent() { return this._text || this.children.map(child => child.textContent).join(''); }
}

const trigger = new Element('button');
const nav = new Element('nav');
nav.appendChild(trigger);
const background = new Element('main');
const body = new Element('body');
body.append(nav, background);
const html = {lang: 'zh-CN', dataset: {}, classList: new Element('html').classList};
const document = {
  body,
  activeElement: null,
  documentElement: html,
  querySelector: () => null,
  querySelectorAll: selector => selector === '[data-showcase-theme]' ? [trigger] : [],
  createElement: tag => new Element(tag),
  createElementNS: (ns, tag) => new Element(tag),
  events: {},
  addEventListener(type, callback) { this.events[type] = callback; },
};
const saved = new Map([['cjdoc-theme', 'violet']]);
const localStorage = {
  getItem: key => saved.get(key) || null,
  setItem: (key, value) => saved.set(key, value),
};
const media = {matches: false, events: {}, addEventListener(type, callback) { this.events[type] = callback; }};
let isMobile = false;
const location = {search: '?theme=forest', href: 'https://docs.test/index.html', protocol: 'https:'};
const window = {
  location, matchMedia: query => query.includes('max-width') ? {matches: isMobile} : media,
  history: {replaceState: () => {}},
};
const context = vm.createContext({document, window, location, localStorage, URL, URLSearchParams});
vm.runInContext(BOOTSTRAP, context);
assert.equal(html.dataset.themeChoice, 'forest');
assert.equal(html.dataset.theme, 'forest');
vm.runInContext(SHOWCASE, context);
const control = trigger.parentNode;
const menu = control.children.find(node => node.className === 'showcase-theme-menu');
const backdrop = control.children.find(node => node.className === 'showcase-theme-backdrop');
const options = menu.children.filter(node => node.className === 'showcase-theme-option');
assert.equal(options.length, 8);
assert.equal(options.find(node => node.getAttribute('aria-pressed') === 'true').dataset.showcaseThemeValue, 'forest');
trigger.events.click();
assert.equal(menu.hidden, false);
assert.equal(trigger.getAttribute('aria-expanded'), 'true');
const ocean = options.find(node => node.dataset.showcaseThemeValue === 'ocean');
ocean.events.click();
assert.equal(html.dataset.themeChoice, 'ocean');
assert.equal(html.dataset.theme, 'ocean');
assert.equal(saved.get('cjdoc-theme'), 'ocean');
assert.equal(menu.hidden, true);
assert.equal(trigger.getAttribute('aria-expanded'), 'false');
assert.equal(trigger.focused, true);
trigger.events.click();
backdrop.events.click();
assert.equal(menu.hidden, true);
trigger.events.click();
document.events.keydown({key: 'Escape', stopPropagation() {}});
assert.equal(menu.hidden, true);
trigger.events.click();
options.find(node => node.dataset.showcaseThemeValue === 'system').events.click();
assert.equal(html.dataset.themeChoice, 'system');
assert.equal(html.dataset.theme, 'light');
media.matches = true;
media.events.change();
assert.equal(html.dataset.theme, 'dark');
trigger.events.click();
options.find(node => node.dataset.showcaseThemeValue === 'paper').events.click();
media.matches = false;
media.events.change();
assert.equal(html.dataset.themeChoice, 'paper');
assert.equal(html.dataset.theme, 'paper');
// At the mobile breakpoint, the sheet must trap Tab and isolate the page.
isMobile = true;
trigger.events.click();
assert.equal(menu.getAttribute('role'), 'dialog');
assert.equal(menu.getAttribute('aria-modal'), 'true');
assert.equal(background.inert, true);
assert.equal(trigger.inert, true);
const closeButton = menu.children[0].children.find(child => child.className === 'showcase-theme-close');
const lastOption = options[options.length - 1];
lastOption.focus();
let prevented = false;
document.events.keydown({key: 'Tab', shiftKey: false, preventDefault() { prevented = true; }});
assert.equal(prevented, true);
assert.equal(document.activeElement, closeButton);
closeButton.focus();
prevented = false;
document.events.keydown({key: 'Tab', shiftKey: true, preventDefault() { prevented = true; }});
assert.equal(prevented, true);
assert.equal(document.activeElement, lastOption);
document.events.keydown({key: 'Escape', stopPropagation() {}});
assert.equal(menu.hidden, true);
assert.equal(background.inert, false);
assert.equal(trigger.inert, false);
assert.equal(menu.getAttribute('aria-modal'), null);
assert.equal(document.activeElement, trigger);
"""
    test = (
        "const BOOTSTRAP = " + json.dumps(bootstrap, ensure_ascii=False) + ";\n"
        + "const SHOWCASE = " + json.dumps(showcase, ensure_ascii=False) + ";\n"
        + harness
    )
    result = subprocess.run(
        ["node"], input=test, encoding="utf-8", text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr)


if __name__ == "__main__":
    unittest.main()
