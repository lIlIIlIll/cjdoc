protected package cjdoc.render.browser

// Start the shared Reader scope with DOM primitives and the on-page outline.
// Outline clicks and fragments own the active highlight until reader input
// releases it; overloads stay siblings. Settings, copy and members follow in
// the same scope so initialization and TOC visibility stay in sync.
internal let HTML_READING_OUTLINE_SCRIPT = """
(() => {
  const isChinese = (document.documentElement.lang || "").toLowerCase().startsWith("zh");
  const text = (english, chinese) => isChinese ? chinese : english;
  const find = selector => document.querySelector(selector);
  const all = selector => document.querySelectorAll(selector);
  const element = (tag, className, caption) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (caption !== undefined) node.textContent = caption;
    return node;
  };
  const attrs = (node, attributes) => {
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    return node;
  };
  const svg = (tag, attributes) => attrs(document.createElementNS("http://www.w3.org/2000/svg", tag), attributes);
  const icon = () => svg("svg", {class: "cj-icon", viewBox: "0 0 24 24",
    fill: "none", stroke: "currentColor", "stroke-width": "1.8", "aria-hidden": "true"});

  const CLICK_RELEASE_EVENTS = ["wheel", "touchstart", "keydown"];
  let syncTocVisibility = () => {};
  const initToc = () => {
    const toc = find("[data-cjdoc-toc]");
    const content = find("[data-cjdoc-content]");
    if (!toc || !content) return;
    const layout = toc.closest(".cj-layout");
    const tocList = toc.querySelector("ol");
    const mobileToc = find("[data-cjdoc-mobile-toc]");
    const mobileList = mobileToc && mobileToc.querySelector("ol");
    if (!tocList) return;
    const mobileOutline = window.matchMedia("(max-width: 1180px)");
    const headings = [...content.querySelectorAll(
      "h1, h2, h3, h4, h5, h6, [data-cjdoc-toc-role='member'], [data-cjdoc-toc-role='entry']")].filter(heading => {
      const role = heading.dataset.cjdocTocRole;
      if (role === "member") return true;
      if (role === "entry") return Boolean(heading.id) && !heading.closest("details");
      if (heading.closest("[data-cjdoc-member]")) return false;
      if (heading.closest("details")) return false;
      return (role === "api-root" || role === "api" || role === "group" ||
        role === "overload" || heading.tagName === "H2" || heading.tagName === "H3");
    });
    const usedIds = new Set(Array.from(all("[id]"), node => node.id));
    const ensureId = (heading, index) => {
      if (heading.id) return;
      let id = (heading.textContent || "").toLowerCase().replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "") || "section-" + index;
      const base = id;
      let suffix = 2;
      while (usedIds.has(id)) { id = base + "-" + suffix; suffix += 1; }
      heading.id = id;
      usedIds.add(id);
    };
    const headingLabel = heading =>
      (heading.dataset.cjdocTocLabel || heading.textContent || "").trim().replace(/\\s+/g, " ");
    // Reuse the primary label's breaks without copying links, badges or markup.
    const appendEntryLabel = (link, entry) => {
      const code = entry.querySelector("a[data-cjdoc-api-link] > code");
      if (!code) return;
      for (const child of code.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) link.append(child.data);
        else if (child.nodeName === "WBR") link.append(element("wbr"));
      }
    };
    const targetId = heading => {
      if (heading.dataset.cjdocTocRole === "member") {
        const member = heading.closest("details.cj-member");
        if (member && member.id) return member.id;
      }
      return heading.id;
    };
    const itemClass = heading => {
      const role = heading.dataset.cjdocTocRole;
      if (role === "member") return "cj-toc__item cj-toc__item--member";
      if (role === "entry") return "cj-toc__item cj-toc__item--entry";
      if (role === "group") return "cj-toc__item cj-toc__item--group";
      if (role === "api-root" || role === "api") return "cj-toc__item cj-toc__item--api";
      return "cj-toc__item";
    };
    const boundedTreeKey = value => String(value).replace(/[^A-Za-z0-9_-]+/g, "-");
    // An overload label and its signatures are peers in the reading outline.
    // Their semantic heading levels in the body do not set the outline depth.
    const depthOf = heading => {
      const parent = parentOf.get(heading);
      if (parent) return depthOf(parent) + 1;
      const role = heading.dataset.cjdocTocRole;
      if (role === "member" || role === "entry") return Number(heading.dataset.cjdocTocDepth || 3);
      return Number(heading.tagName.slice(1));
    };
    const createLink = heading => {
      const id = targetId(heading);
      const entry = heading.dataset.cjdocTocRole === "entry";
      const link = element("a", "cj-toc__link", entry ? undefined : headingLabel(heading));
      if (entry) appendEntryLabel(link, heading);
      link.setAttribute("href", "#" + id);
      link.dataset.tocTarget = id;
      return link;
    };
    const createToggle = (label, children) => {
      const button = element("button", "cj-toc__toggle");
      button.type = "button";
      button.setAttribute("aria-controls", children.id);
      const apply = expanded => {
        button.setAttribute("aria-expanded", expanded ? "true" : "false");
        button.setAttribute("aria-label",
          (expanded ? text("Collapse ", "收起 ") : text("Expand ", "展开 ")) + label);
        children.hidden = !expanded;
      };
      button.addEventListener("click", () => {
        apply(button.getAttribute("aria-expanded") !== "true");
      });
      apply(true);
      return button;
    };
    const buildChildren = prefix => {
      const list = element("ol", "cj-toc__children");
      list.id = "cjdoc-toc-children-" + boundedTreeKey(prefix);
      return list;
    };
    for (let index = 0; index < headings.length; index += 1) ensureId(headings[index], index);
    tocList.replaceChildren();
    const headingSet = new Set(headings);
    const containerHeading = (heading, containerSelector, titleSelector) => {
      const container = heading.closest(containerSelector);
      const title = container && container.querySelector(titleSelector);
      return title && headingSet.has(title) ? title : null;
    };
    const enclosingGroup = heading =>
      containerHeading(heading, "[data-cjdoc-member-group]", "[data-cjdoc-toc-role='group']") ||
      containerHeading(heading, "[data-cjdoc-declaration-group]", ":scope > h2");
    // A declaration entry belongs to the visible kind heading that states its
    // kind; when that heading is merged into its author group, the group title is
    // the parent. A choice page has neither, so its `#api-options` heading wins.
    const enclosingEntry = heading =>
      containerHeading(heading, ".cj-decl-group", ":scope > [data-cjdoc-toc-role='group']") ||
      enclosingGroup(heading);
    let section = null;
    const parentOf = new Map();
    for (const heading of headings) {
      const role = heading.dataset.cjdocTocRole;
      if (role === "api-root" || role === "api" || role === "group") {
        section = heading;
      } else if (role === "overload" || role === "member" || role === "entry") {
        const parent = (role === "entry" ? enclosingEntry(heading) : enclosingGroup(heading)) || section;
        if (parent) parentOf.set(heading, parent);
      }
    }
    const withChildren = new Set(parentOf.values());
    const childLists = new Map();
    for (const heading of headings) {
      const item = element("li", itemClass(heading));
      item.dataset.depth = String(depthOf(heading));
      const link = createLink(heading);
      if (withChildren.has(heading)) {
        const children = buildChildren(targetId(heading));
        const row = element("div", "cj-toc__row");
        row.append(createToggle(headingLabel(heading), children), link);
        item.append(row, children);
        childLists.set(heading, children);
      } else {
        item.append(link);
      }
      const owner = parentOf.get(heading);
      (owner && childLists.get(owner) || tocList).append(item);
    }
    if (mobileList) {
      mobileList.replaceChildren();
      for (const heading of headings) {
        const item = element("li", itemClass(heading));
        item.append(createLink(heading));
        mobileList.append(item);
      }
    }
    toc.hidden = headings.length === 0;
    if (mobileToc) mobileToc.hidden = headings.length === 0;
    layout?.classList.toggle("cj-layout--with-toc", !toc.hidden);
    if (!headings.length) return;
    // One target can be listed by both the desktop and the mobile outline, so
    // the active state and `aria-current` are applied to every copy.
    const linksByTarget = new Map();
    for (const list of [tocList, mobileList]) {
      if (!list) continue;
      for (const link of list.querySelectorAll("a[data-toc-target]")) {
        const target = link.dataset.tocTarget;
        const links = linksByTarget.get(target);
        if (links) links.push(link); else linksByTarget.set(target, [link]);
      }
    }
    let activeLinks = [];
    const setActive = targetIdValue => {
      const next = linksByTarget.get(targetIdValue) || [];
      if (next.length && activeLinks.length && next[0] === activeLinks[0]) return;
      for (const link of activeLinks) {
        link.classList.remove("cj-toc__link--active");
        link.removeAttribute("aria-current");
      }
      for (const link of next) {
        link.classList.add("cj-toc__link--active");
        link.setAttribute("aria-current", "location");
      }
      activeLinks = next;
    };
    let clickedTarget = null;
    let releaseTimer = 0;
    const releaseClick = () => {
      clickedTarget = null;
      if (releaseTimer) { clearTimeout(releaseTimer); releaseTimer = 0; }
      for (const type of CLICK_RELEASE_EVENTS) {
        window.removeEventListener(type, releaseClick, true);
      }
    };
    for (const list of [tocList, mobileList]) {
      if (!list) continue;
      list.addEventListener("click", event => {
        const link = event.target && event.target.closest
          ? event.target.closest("a[data-toc-target]") : null;
        if (!link) return;
        clickedTarget = link.dataset.tocTarget;
        setActive(clickedTarget);
        for (const type of CLICK_RELEASE_EVENTS) {
          window.addEventListener(type, releaseClick, {capture: true, passive: true});
        }
        if (releaseTimer) clearTimeout(releaseTimer);
        releaseTimer = setTimeout(releaseClick, 2500);
      });
    }
    if ("IntersectionObserver" in window) {
      const observer = new IntersectionObserver(entries => {
        if (clickedTarget !== null) return;
        for (const entry of entries) {
          if (entry.isIntersecting && !entry.target.closest("[hidden]")) setActive(targetId(entry.target));
        }
      }, {rootMargin: "-18% 0px -68% 0px", threshold: 0});
      for (const heading of headings) observer.observe(heading);
    }
    setActive(targetId(headings[0]));
    const syncHash = () => {
      if (!window.location.hash || window.location.hash.length <= 1) return;
      let id = window.location.hash.slice(1);
      try { id = decodeURIComponent(id); } catch (_) { /* keep raw */ }
      if (linksByTarget.has(id)) setActive(id);
    };
    syncHash();
    window.addEventListener("hashchange", syncHash);
    const byTarget = new Map(headings.map(heading => [targetId(heading), heading]));
    const outline = [tocList, mobileList].filter(Boolean).flatMap(list =>
      [...list.querySelectorAll("[data-toc-target]")].map(link => ({
        list, link, item: link.closest("li"), heading: byTarget.get(link.dataset.tocTarget)
      })));
    syncTocVisibility = () => {
      const visible = headings.filter(heading => !heading.closest("[hidden]"));
      const visibleIds = new Set(visible.map(targetId));
      const activeList = mobileOutline.matches && mobileList || tocList;
      for (const {list, link, item, heading} of outline) {
        if (list !== activeList) continue;
        const hidden = !visibleIds.has(link.dataset.tocTarget);
        if (item && item.hidden !== hidden) item.hidden = hidden;
        const role = heading?.dataset.cjdocTocRole;
        if (heading && role !== "member" && role !== "entry") {
          const label = headingLabel(heading);
          if (link.textContent !== label) link.textContent = label;
        }
      }
      if (activeLinks.length && !visibleIds.has(activeLinks[0].dataset.tocTarget) && visible.length) {
        setActive(targetId(visible[0]));
      }
      toc.hidden = visible.length === 0;
      if (mobileToc) mobileToc.hidden = visible.length === 0;
      layout?.classList.toggle("cj-layout--with-toc", !toc.hidden);
    };
    mobileOutline.addEventListener("change", syncTocVisibility);
  };

"""
