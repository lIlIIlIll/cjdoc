(() => {
  const input = document.querySelector("[data-cjdoc-search]");
  const results = document.querySelector("[data-cjdoc-results]");
  if (!input || !results) return;
  let symbols = [];
  let visible = [];
  let selected = -1;
  const root = input.dataset.root || "";
  const kindFilter = document.querySelector("[data-cjdoc-kind]");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  const score = (entry, query) => {
    const name = entry.name.toLocaleLowerCase();
    const qualified = entry.qualifiedName.toLocaleLowerCase();
    if (name === query) return 0;
    if (qualified === query) return 1;
    if (name.startsWith(query)) return 2;
    if (qualified.startsWith(query)) return 3;
    const tokens = query.split(/\s+/).filter(Boolean);
    const haystack = (entry.qualifiedName + " " + entry.kind + " " + entry.packageName + " " + entry.summary).toLocaleLowerCase();
    return tokens.every((token) => haystack.includes(token)) ? 4 : -1;
  };
  const select = (next) => {
    if (!visible.length) return;
    selected = (next + visible.length) % visible.length;
    for (let i = 0; i < results.children.length; i += 1) {
      results.children[i].setAttribute("aria-selected", i === selected ? "true" : "false");
    }
    const active = results.children[selected];
    input.setAttribute("aria-activedescendant", active.id);
    active.scrollIntoView({block: "nearest"});
  };
  const render = () => {
    results.replaceChildren();
    visible.length = 0;
    selected = -1;
    input.removeAttribute("aria-activedescendant");
    const query = input.value.trim().toLocaleLowerCase();
    if (!query) { input.setAttribute("aria-expanded", "false"); return; }
    const kind = kindFilter ? kindFilter.value : "";
    const packageName = packageFilter ? packageFilter.value : "";
    visible.push(...symbols.map((entry) => ({entry, rank: score(entry, query)}))
      .filter((item) => item.rank >= 0 && (!kind || item.entry.kind === kind) &&
        (!packageName || item.entry.packageName === packageName))
      .sort((left, right) => left.rank - right.rank ||
        left.entry.qualifiedName.localeCompare(right.entry.qualifiedName) || left.entry.id.localeCompare(right.entry.id))
      .slice(0, 20).map((item) => item.entry));
    for (const symbol of visible) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      const name = document.createElement("span");
      const kind = document.createElement("span");
      link.href = root + symbol.url;
      name.textContent = symbol.qualifiedName;
      kind.className = "search-kind";
      kind.textContent = " — " + symbol.kind;
      item.id = "cjdoc-search-result-" + results.children.length;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      link.append(name, kind);
      item.append(link);
      results.append(item);
    }
    input.setAttribute("aria-expanded", visible.length ? "true" : "false");
  };
  const addOptions = (selectElement, values) => {
    if (!selectElement) return;
    for (const value of [...new Set(values)].sort((a, b) => a.localeCompare(b))) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      selectElement.append(option);
    }
  };
  fetch(root + "search-index.json", {credentials: "same-origin"})
    .then((response) => response.ok ? response.json() : Promise.reject(new Error("search index unavailable")))
    .then((index) => {
      symbols = index.schemaVersion === "cjdoc.search-index/2" && Array.isArray(index.symbols) ? index.symbols : [];
      addOptions(kindFilter, symbols.map((entry) => entry.kind));
      addOptions(packageFilter, symbols.map((entry) => entry.packageName));
      render();
    })
    .catch(() => { symbols = []; });
  input.addEventListener("input", render);
  if (kindFilter) kindFilter.addEventListener("change", render);
  if (packageFilter) packageFilter.addEventListener("change", render);
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") { event.preventDefault(); select(selected + 1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); select(selected - 1); }
    else if (event.key === "Enter" && selected >= 0) { event.preventDefault(); results.children[selected].querySelector("a").click(); }
    else if (event.key === "Escape") { input.value = ""; render(); }
  });
  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLocaleLowerCase() === "k") {
      event.preventDefault(); input.focus();
    }
  });
})();
