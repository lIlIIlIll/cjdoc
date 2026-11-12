package cjdoc.render

// Language toggle behaviour: reopen the current section in the target language
// when that language has a mapping for it, otherwise fall back to the language
// home or the start of the same page, and keep the search scope tags.
internal let LANGUAGE_NAVIGATION_SCRIPT = """
(() => {
  const links = [...document.querySelectorAll("[data-language-routes]")];
  if (!links.length) return;
  const switcher = document.querySelector("details.cj-lang-toggle");
  if (switcher) {
    const summary = switcher.querySelector(".cj-lang-toggle__summary");
    document.addEventListener("click", event => {
      if (!switcher.contains(event.target)) switcher.open = false;
    });
    document.addEventListener("keydown", event => {
      if (event.key !== "Escape" || !switcher.open) return;
      switcher.open = false;
      if (summary && typeof summary.focus === "function") summary.focus();
      event.preventDefault();
      return;
    });
    switcher.addEventListener("click", event => {
      if (event.target instanceof Element && event.target.closest("a")) switcher.open = false;
    });
  }
  const sectionNotice = document.documentElement.lang === "zh-CN"
    ? "该语言没有对应章节，打开同一页面的开头"
    : "No corresponding section in this language; open the start of the same page";
  const pageNotice = document.documentElement.lang === "zh-CN"
    ? "该语言无此页面，打开语言首页"
    : "This page is unavailable; open the language home";
  const update = () => {
    let anchor = location.hash.slice(1);
    try { anchor = decodeURIComponent(anchor); } catch (_) { /* keep raw */ }
    let current = null;
    try { current = new URL(location.href); } catch (_) { /* optional */ }
    for (const link of links) {
      if (!link.dataset.languageBase) link.dataset.languageBase = link.getAttribute("href");
      let routes = {};
      try { routes = JSON.parse(link.dataset.languageRoutes || "{}"); } catch (_) { routes = {}; }
      const candidate = Object.prototype.hasOwnProperty.call(routes, anchor)
        ? routes[anchor] : null;
      const target = Array.isArray(candidate) && typeof candidate[0] === "string"
        ? candidate : null;
      const homeFallback = link.dataset.switchState === "language-home";
      const missingPosition = !homeFallback && Boolean(anchor) && !target;
      const destination = target && !homeFallback ? target[0] : link.dataset.languageBase;
      try {
        const url = new URL(destination, location.href);
        url.searchParams.delete("tag");
        url.searchParams.delete("moduleId");
        url.searchParams.delete("snapshotId");
        if (current) {
          for (const tag of current.searchParams.getAll("tag")) url.searchParams.append("tag", tag);
          for (const moduleId of current.searchParams.getAll("moduleId")) {
            url.searchParams.append("moduleId", moduleId);
          }
        }
        link.href = url.href;
      } catch (_) { link.href = destination; }
      const state = homeFallback ? "language-home" : missingPosition ? "page-start" : "mapped";
      const noticeText = homeFallback ? pageNotice : missingPosition ? sectionNotice : "";
      link.dataset.positionState = state;
      const notice = link.querySelector(".cj-lang-toggle__notice");
      if (notice) {
        notice.textContent = noticeText;
        notice.hidden = !noticeText;
      }
      if (noticeText) link.setAttribute("title", noticeText);
      else link.removeAttribute("title");
    }
  };
  update();
  if (switcher) {
    // pushState changes search tags without a navigation event; resolve links when used.
    switcher.addEventListener("click", update, true);
    switcher.addEventListener("focusin", update);
  }
  window.addEventListener("popstate", update);
  window.addEventListener("hashchange", update);
  window.addEventListener("pageshow", update);
})();
"""
