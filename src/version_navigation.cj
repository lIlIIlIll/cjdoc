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

// Only validated symbol-index routes are serialized into escaped attributes.
// Update real hrefs, so copy-link, middle-click and keyboard navigation agree.
internal let VERSION_NAVIGATION_SCRIPT = #"
(function () {
  'use strict';
  var links = Array.from(document.querySelectorAll('[data-cjdoc-version-link]')).map(function (link) {
    var routes = {};
    try { routes = JSON.parse(link.getAttribute('data-cjdoc-version-routes') || '{}'); } catch (_) {}
    return {link: link, routes: routes, href: link.getAttribute('href'), text: link.textContent};
  });
  function update() {
    var anchor = location.hash.slice(1);
    try { anchor = decodeURIComponent(anchor); } catch (_) {}
    links.forEach(function (entry) {
      var value = Object.prototype.hasOwnProperty.call(entry.routes, anchor) ? entry.routes[anchor] : null;
      entry.link.setAttribute('href', value ? value[0] : entry.href);
      entry.link.textContent = value ? entry.link.getAttribute('data-cjdoc-version-label') +
        (value[1] ? entry.link.getAttribute('data-cjdoc-version-missing') : '') : entry.text;
    });
  }
  update();
  addEventListener('hashchange', update);
  addEventListener('pageshow', update);
}());
"#
