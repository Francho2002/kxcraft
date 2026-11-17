(() => {
  "use strict";

  const dataNode = document.getElementById("kxcraft-playable-mods");
  const grid = document.getElementById("mods-grid");
  const filterRoot = document.getElementById("category-filters");
  const queryInput = document.getElementById("mod-search");
  const countNode = document.getElementById("results-count");
  const emptyNode = document.getElementById("empty-state");
  const dialog = document.getElementById("mod-dialog");
  const dialogTitle = document.getElementById("dialog-title");
  const dialogDescription = document.getElementById("dialog-description");
  const dialogCategory = document.getElementById("dialog-category");
  const dialogPlacement = document.getElementById("dialog-placement");
  const dialogPlacementNote = document.getElementById("dialog-placement-note");
  const dialogMedia = document.getElementById("dialog-media");
  const distributionSummary = document.getElementById("distribution-summary");
  if (!dataNode || !grid || !filterRoot || !queryInput || !countNode || !emptyNode) return;

  let mods;
  try {
    mods = JSON.parse(dataNode.textContent);
  } catch {
    countNode.textContent = "No pudimos cargar el catálogo.";
    emptyNode.hidden = false;
    return;
  }

  if (!Array.isArray(mods) || mods.length === 0) {
    countNode.textContent = "Todavía no hay mods para mostrar.";
    emptyNode.hidden = false;
    return;
  }

  const normalize = (text) => String(text ?? "")
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLocaleLowerCase("es-AR")
    .trim();

  const categories = [...new Set(mods.map((mod) => mod.category))];
  let selectedCategory = "Todos";

  const placementLabels = {
    "client-profile": "En el perfil cliente",
    "client-and-server": "En cliente y servidor",
    "server-only": "Solo en el servidor de KxCraft"
  };

  const makeElement = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };

  function makeIcon(mod, large = false) {
    const holder = makeElement("div", "icon-fallback", mod.initials || "KX");
    holder.setAttribute("aria-hidden", "true");
    const url = mod.icon;
    if (!url || !/^https:\/\//i.test(url)) return holder;

    const image = document.createElement("img");
    image.className = large ? "mod-icon mod-icon-large" : "mod-icon";
    image.src = url;
    image.alt = mod.iconAlt || (mod.name + ", imagen");
    image.loading = "lazy";
    image.decoding = "async";
    image.referrerPolicy = "no-referrer";
    image.addEventListener("error", () => image.replaceWith(holder), { once: true });
    return image;
  }

  function openDetails(mod) {
    if (!dialog || typeof dialog.showModal !== "function") return;
    dialogTitle.textContent = mod.name;
    dialogDescription.textContent = mod.description;
    dialogCategory.textContent = mod.category;
    if (dialogPlacement) dialogPlacement.textContent = placementLabels[mod.placement] || "";
    if (dialogPlacementNote) {
      dialogPlacementNote.textContent = mod.placementNote || "";
      dialogPlacementNote.hidden = !mod.placementNote;
    }
    dialogMedia.replaceChildren(makeIcon(mod, true));
    dialog.showModal();
  }

  function drawDistributionSummary() {
    if (!distributionSummary) return;
    const clientCount = mods.filter((mod) => ["client-profile", "client-and-server"].includes(mod.placement)).length;
    const serverCount = mods.filter((mod) => ["server-only", "client-and-server"].includes(mod.placement)).length;
    const sharedCount = mods.filter((mod) => mod.placement === "client-and-server").length;
    distributionSummary.replaceChildren(
      makeElement("span", "distribution-counter", "Cliente · " + clientCount),
      makeElement("span", "distribution-counter", "Servidor · " + serverCount),
      makeElement("span", "distribution-counter-note", "Compartidos · " + sharedCount)
    );
  }

  function drawFilters() {
    filterRoot.replaceChildren();
    ["Todos", ...categories].forEach((category) => {
      const button = makeElement("button", "category-filter", category);
      button.type = "button";
      button.setAttribute("aria-pressed", String(category === selectedCategory));
      button.addEventListener("click", () => {
        selectedCategory = category;
        drawFilters();
        drawMods();
      });
      filterRoot.append(button);
    });
  }

  function drawMods() {
    const query = normalize(queryInput.value);
    const visible = mods.filter((mod) => {
      const categoryMatches = selectedCategory === "Todos" || mod.category === selectedCategory;
      const textMatches = normalize([mod.name, mod.description, mod.category].join(" ")).includes(query);
      return categoryMatches && textMatches;
    });

    grid.replaceChildren();
    visible.forEach((mod) => {
      const card = makeElement("button", "mod-card");
      card.type = "button";
      card.setAttribute("aria-label", "Ver detalles de " + mod.name);
      const top = makeElement("span", "card-top");
      top.append(makeIcon(mod));
      const text = makeElement("span", "card-title-wrap");
      text.append(makeElement("span", "mod-name", mod.name));
      text.append(makeElement("span", "mod-category", mod.category));
      top.append(text);
      card.append(top);
      if (mod.placement && mod.placement !== "client-profile") {
        card.append(makeElement("span", "placement-tag", placementLabels[mod.placement] || "Distribución especial"));
      }
      if (mod.featured) card.append(makeElement("span", "featured-tag", "Destacado"));
      card.append(makeElement("span", "mod-description", mod.description));
      card.append(makeElement("span", "card-open", "Ver detalle →"));
      card.addEventListener("click", () => openDetails(mod));
      grid.append(card);
    });

    const noun = visible.length === 1 ? "mod" : "mods";
    countNode.textContent = visible.length + " " + noun;
    emptyNode.hidden = visible.length > 0;
  }

  queryInput.addEventListener("input", drawMods);
  document.addEventListener("keydown", (event) => {
    if (event.key === "/" && document.activeElement !== queryInput && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault();
      queryInput.focus();
    }
  });
  drawFilters();
  drawDistributionSummary();
  drawMods();
})();
