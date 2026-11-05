package cjdoc

internal func versionSymbolAnchor(id: String): String {
    let out = StringBuilder()
    let digits = "0123456789abcdef"
    out.append("symbol-")
    for (byte in id.toArray()) {
        let high = Int64((byte >> 4) & 0x0F)
        let low = Int64(byte & 0x0F)
        out.append(digits[high..high + 1])
        out.append(digits[low..low + 1])
    }
    out.toString()
}

internal enum VersionNavigationState {
    Exact | MissingSymbol | MissingLanguage | MissingSection | MissingPage
}

internal class VersionNavigationTarget {
    let href: String
    let state: VersionNavigationState

    init(href: String, state: VersionNavigationState) {
        this.href = href
        this.state = state
    }
}

// Only validated symbol-index routes are serialized into escaped attributes.
// Update real hrefs, so copy-link, middle-click and keyboard navigation agree.
internal let VERSION_NAVIGATION_SCRIPT = #"
(function () {
  'use strict';
  var links = Array.from(document.querySelectorAll('[data-cjdoc-version-link]')).map(function (link) {
    var routes = {};
    var messages = {};
    try { routes = JSON.parse(link.getAttribute('data-cjdoc-version-routes') || '{}'); } catch (_) {}
    try { messages = JSON.parse(link.getAttribute('data-cjdoc-version-messages') || '{}'); } catch (_) {}
    return {
      link: link,
      routes: routes,
      messages: messages,
      href: link.getAttribute('href'),
      text: link.textContent,
      state: link.getAttribute('data-cjdoc-version-state')
    };
  });
  function restoreAttribute(link, name, value) {
    if (value === null) link.removeAttribute(name);
    else link.setAttribute(name, value);
  }
  function update() {
    var anchor = location.hash.slice(1);
    try { anchor = decodeURIComponent(anchor); } catch (_) {}
    links.forEach(function (entry) {
      var value = Object.prototype.hasOwnProperty.call(entry.routes, anchor) ? entry.routes[anchor] : null;
      if (value) {
        var state = value[1];
        var message = Object.prototype.hasOwnProperty.call(entry.messages, state) ? entry.messages[state] : '';
        entry.link.setAttribute('href', value[0]);
        entry.link.textContent = entry.link.getAttribute('data-cjdoc-version-label') + message;
        entry.link.setAttribute('data-cjdoc-version-state', state);
      } else {
        restoreAttribute(entry.link, 'href', entry.href);
        entry.link.textContent = entry.text;
        restoreAttribute(entry.link, 'data-cjdoc-version-state', entry.state);
      }
    });
  }
  update();
  addEventListener('hashchange', update);
  addEventListener('pageshow', update);
}());
"#;
