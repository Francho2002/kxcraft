(() => {
  "use strict";

  const dataNode = document.getElementById("kxcraft-schematics");
  const grid = document.getElementById("schematics-grid");
  const countNode = document.getElementById("schematics-count");
  const emptyNode = document.getElementById("schematics-empty");
  const searchInput = document.getElementById("schematics-search");
  const categorySelect = document.getElementById("schematics-category");
  if (!dataNode || !grid || !countNode || !emptyNode || !searchInput || !categorySelect) return;

  const editorRequested = new URLSearchParams(window.location.search).get("editar-precios") === "1";
  const localHosts = new Set(["localhost", "127.0.0.1", "::1"]);
  const priceEditorEnabled = editorRequested && (window.location.protocol === "file:" || localHosts.has(window.location.hostname.toLowerCase()));
  const priceStorageKey = "kxcraft-store-price-overrides-v1";
  const priceOverrides = Object.create(null);
  let priceStorageAvailable = true;

  if (priceEditorEnabled) {
    try {
      const savedOverrides = JSON.parse(window.localStorage.getItem(priceStorageKey) || "{}");
      if (savedOverrides && typeof savedOverrides === "object" && !Array.isArray(savedOverrides)) {
        for (const [id, value] of Object.entries(savedOverrides)) {
          if (typeof value === "string") priceOverrides[id] = value;
        }
      }
    } catch {
      priceStorageAvailable = false;
    }
  }

  const makeElement = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };

  const safeUrl = (value) => {
    try {
      const url = new URL(String(value ?? ""));
      return url.protocol === "https:" && !url.username && !url.password ? url : null;
    } catch {
      return null;
    }
  };

  let source;
  try {
    source = JSON.parse(dataNode.textContent);
  } catch {
    source = [];
  }
  const allItems = Array.isArray(source) ? source : Array.isArray(source?.schematics) ? source.schematics : [];
  const items = allItems.filter((item) => {
    const createUrl = safeUrl(item?.createUrl);
    const imageUrl = String(item?.imageUrl ?? "").trim();
    const validImage = !imageUrl || (safeUrl(imageUrl)?.hostname === "createmod.com" &&
      safeUrl(imageUrl)?.pathname.startsWith("/api/files/schematics/"));
    return item && typeof item.title === "string" && typeof item.category === "string" &&
      typeof item.price === "string" && Array.isArray(item.requiredMods) &&
      Array.isArray(item.missingMods) && ["listed", "not_listed"].includes(item.requirementsStatus) &&
      createUrl?.hostname === "createmod.com" && createUrl.pathname.startsWith("/schematics/") && validImage;
  });

  const categories = [...new Set(items.map((item) => item.category))].sort((a, b) => a.localeCompare(b, "es"));
  for (const category of categories) {
    const option = makeElement("option", "", category);
    option.value = category;
    categorySelect.append(option);
  }

  const makeModList = (names, className) => {
    const list = makeElement("ul", className);
    for (const name of names) list.append(makeElement("li", "", name));
    return list;
  };

  const persistPriceOverrides = () => {
    try {
      window.localStorage.setItem(priceStorageKey, JSON.stringify(priceOverrides));
      priceStorageAvailable = true;
    } catch {
      priceStorageAvailable = false;
    }
  };

  const exportPriceOverrides = () => {
    const prices = Object.entries(priceOverrides).map(([id, price]) => {
      const item = items.find((candidate) => candidate.id === id);
      return { id, title: item?.title || id, price };
    });
    const payload = {
      schemaVersion: 1,
      exportedAt: new Date().toISOString(),
      prices
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const link = makeElement("a");
    link.href = url;
    link.download = "kxcraft-precios-temporales.json";
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  const addPriceEditor = () => {
    if (!priceEditorEnabled) return;
    const banner = makeElement("aside", "store-price-editor");
    banner.setAttribute("aria-label", "Editor local temporal de precios");
    const copy = makeElement("div", "store-price-editor-copy");
    copy.append(makeElement("strong", "", "Edición local de precios"));
    const status = makeElement("span", "store-price-editor-status");
    const updateStatus = () => {
      const count = Object.keys(priceOverrides).length;
      status.textContent = priceStorageAvailable
        ? `${count} precio${count === 1 ? "" : "s"} editado${count === 1 ? "" : "s"}; se guarda en este navegador.`
        : "El navegador no permite guardar localmente. Exportá los cambios antes de cerrar.";
    };
    copy.append(status);

    const actions = makeElement("div", "store-price-editor-actions");
    const exportButton = makeElement("button", "store-price-editor-button", "Exportar precios");
    exportButton.type = "button";
    exportButton.addEventListener("click", exportPriceOverrides);
    const resetButton = makeElement("button", "store-price-editor-button store-price-editor-button--quiet", "Borrar cambios");
    resetButton.type = "button";
    resetButton.addEventListener("click", () => {
      if (!window.confirm("¿Borrar los precios temporales guardados en este navegador?")) return;
      for (const id of Object.keys(priceOverrides)) delete priceOverrides[id];
      try {
        window.localStorage.removeItem(priceStorageKey);
        priceStorageAvailable = true;
      } catch {
        priceStorageAvailable = false;
      }
      updateStatus();
      render();
    });
    actions.append(exportButton, resetButton);
    banner.append(copy, actions);
    grid.parentElement.insertBefore(banner, grid);
    updateStatus();
    return updateStatus;
  };

  const updateEditorStatus = addPriceEditor();

  const makeCard = (item) => {
    const createUrl = safeUrl(item.createUrl);
    const card = makeElement("article", "schematic-card");
    const media = makeElement("div", "schematic-media");
    const imageUrl = safeUrl(item.imageUrl);

    const makeCreateLink = (className, label) => {
      const link = makeElement("a", className, label);
      link.href = createUrl.href;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.setAttribute("aria-label", "Abrir " + item.title + " en CreateMod en una pestaña nueva");
      return link;
    };

    if (imageUrl) {
      const image = document.createElement("img");
      image.src = imageUrl.href;
      image.alt = item.imageAlt || (item.title + ", imagen de CreateMod");
      image.loading = "lazy";
      image.decoding = "async";
      image.referrerPolicy = "no-referrer";
      image.addEventListener("error", () => {
        media.replaceChildren(makeCreateLink("schematic-image-fallback", "Vista previa no disponible. Abrir en CreateMod"));
      }, { once: true });
      const imageLink = makeCreateLink("schematic-image-link", "");
      imageLink.append(image);
      media.append(imageLink);
    } else {
      media.append(makeCreateLink("schematic-image-fallback", "Vista previa no disponible. Abrir en CreateMod"));
    }

    const body = makeElement("div", "schematic-body");
    body.append(makeElement("span", "schematic-category", item.category));
    body.append(makeElement("h2", "schematic-title", item.title));
    if (item.description) body.append(makeElement("p", "schematic-description", item.description));

    if (item.requirementsStatus === "listed") {
      const details = document.createElement("details");
      details.className = "schematic-requirements";
      const requirementCount = item.requiredMods.length;
      const requirementLabel = requirementCount === 1
        ? "1 tecnología requerida"
        : requirementCount + " tecnologías requeridas";
      details.append(makeElement("summary", "", requirementLabel));
      details.append(makeModList(item.requiredMods, "schematic-mod-list"));
      body.append(details);

      if (item.missingMods.length) {
        const missing = makeElement("div", "schematic-fit schematic-fit--missing");
        missing.append(makeElement("strong", "", "Faltan en KxCraft:"));
        missing.append(makeModList(item.missingMods, "schematic-missing-list"));
        body.append(missing);
      } else {
        body.append(makeElement("p", "schematic-fit schematic-fit--ok", "Los bloques y tecnologías listados están disponibles en KxCraft."));
      }
    } else {
      body.append(makeElement("p", "schematic-fit schematic-fit--unknown",
        "La ficha de CreateMod no enumera las tecnologías requeridas."));
    }

    const actions = makeElement("div", "schematic-actions");
    const price = makeElement("div", "schematic-price");
    price.append(makeElement("span", "", "Construcción armada"));
    const currentPrice = Object.prototype.hasOwnProperty.call(priceOverrides, item.id)
      ? priceOverrides[item.id]
      : item.price;
    if (priceEditorEnabled) {
      const editor = makeElement("label", "schematic-price-editor-label", "Precio");
      const input = document.createElement("input");
      input.className = "schematic-price-editor-input";
      input.type = "text";
      input.value = currentPrice;
      input.maxLength = 80;
      input.setAttribute("aria-label", "Precio de " + item.title);
      input.autocomplete = "off";
      input.addEventListener("input", () => {
        const value = input.value;
        if (value === item.price) delete priceOverrides[item.id];
        else priceOverrides[item.id] = value;
        persistPriceOverrides();
        updateEditorStatus?.();
      });
      editor.append(input);
      price.append(editor);
    } else {
      price.append(makeElement("strong", "", "Precio: " + currentPrice));
    }

    actions.append(price);
    card.append(media, body, actions);
    return card;
  };

  const render = () => {
    const query = searchInput.value.trim().toLocaleLowerCase("es");
    const category = categorySelect.value;
    const visible = items.filter((item) => {
      const text = [item.title, item.category, ...(item.requiredMods || []), ...(item.missingMods || [])]
        .join(" ").toLocaleLowerCase("es");
      return (!query || text.includes(query)) && (category === "all" || item.category === category);
    });

    grid.replaceChildren(...visible.map(makeCard));
    countNode.textContent = visible.length === items.length
      ? items.length + " schematics · " + categories.length + " categorías"
      : visible.length + " de " + items.length + " schematics";
    emptyNode.hidden = visible.length > 0;
  };

  searchInput.addEventListener("input", render);
  categorySelect.addEventListener("change", render);
  render();
})();
