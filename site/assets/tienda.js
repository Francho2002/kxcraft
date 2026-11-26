(() => {
  "use strict";
  // Catálogo estático: los precios se publican junto con cada ficha en el HTML.
  const dataNode = document.getElementById("kxcraft-shop-products");
  const grid = document.getElementById("shop-grid");
  const count = document.getElementById("shop-count");
  const empty = document.getElementById("shop-empty");
  if (!dataNode || !grid || !count || !empty) return;

  const collator = new Intl.Collator("es-AR", { sensitivity:"base", numeric:true });
  const invalidPrices = new Set(["", "a definir", "por definir", "sin definir", "pendiente"]);
  const hasPrice = v => typeof v === "string" && !invalidPrices.has(v.trim().toLocaleLowerCase("es"));
  const priceNumber = (value) => {
    const token = String(value ?? "").replace(/[^\d,.]/g, "");
    if (!/\d/.test(token)) return Infinity;
    let p = token;
    if (p.includes(",") && p.includes(".")) {
      p = p.lastIndexOf(",") > p.lastIndexOf(".") ? p.replace(/\./g, "").replace(",", ".") : p.replace(/,/g, "");
    } else if (p.includes(",")) {
      p = /^\d{1,3}(,\d{3})+$/.test(p) ? p.replace(/,/g, "") : p.replace(",", ".");
    } else if (p.includes(".")) {
      p = /^\d{1,3}(\.\d{3})+$/.test(p) ? p.replace(/\./g, "") : p;
    }
    const n = Number(p);
    return Number.isFinite(n) ? n : Infinity;
  };
  const safeImage = (value) => {
    if (["assets/kxcraft-jumbo-green-airplane.png", "assets/kxcraft-landkreuzer-ratte.png"].includes(value)) return value;
    try {
      const u = new URL(value);
      return u.protocol === "https:" && u.hostname === "createmod.com" && u.pathname.startsWith("/api/files/schematics/") ? u.href : "";
    } catch { return ""; }
  };

  let raw = [];
  try { raw = JSON.parse(dataNode.textContent); } catch { return; }
  if (!Array.isArray(raw)) return;
  const items = raw.filter(x => x && typeof x.id === "string" && typeof x.title === "string" && typeof x.category === "string" && typeof x.price === "string");
  const el = (tag, cls, value) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (value !== undefined) n.textContent = value;
    return n;
  };
  const makeCard = (item) => {
    const card = el("article", "shop-card");
    // Photos open the original showcase video if CreateMod has a verified
    // attachment. Otherwise they open that exact schematic's CreateMod page.
    const verifiedVideo = typeof item.videoUrl === "string" && /^https:\/\/(?:youtu\.be\/[a-zA-Z0-9_-]{11}|www\.youtube\.com\/watch\?v=[a-zA-Z0-9_-]{11})$/.test(item.videoUrl)
      ? item.videoUrl : "";
    const schematicUrl = typeof item.createUrl === "string" && /^https:\/\/createmod\.com\/schematics\/[a-zA-Z0-9_-]+\/?$/.test(item.createUrl)
      ? item.createUrl : "";
    const photo = el("a", "shop-photo-link");
    photo.href = verifiedVideo || schematicUrl || "#";
    photo.target = "_blank";
    photo.rel = "noopener noreferrer";
    photo.setAttribute("aria-label", verifiedVideo ? `Ver video de ${item.title} (abre YouTube)` : `Ver ficha de ${item.title} en CreateMod`);
    photo.title = verifiedVideo ? "Ver video del schematic ↗" : "Ver schematic en CreateMod ↗";
    const src = safeImage(item.imageUrl);
    if (src) {
      const img = el("img", "shop-image");
      img.src = src;
      img.alt = item.imageAlt || item.title;
      img.loading = "lazy";
      img.decoding = "async";
      img.referrerPolicy = "no-referrer";
      img.addEventListener("error", () => img.replaceWith(el("div", "shop-image-fallback", "Vista previa no disponible")), { once:true });
      photo.append(img);
    } else {
      const placeholder = el("div", "shop-image-fallback", "Buscando imagen original en CreateMod…");
      photo.append(placeholder);
      if (window.KxCreateModPreview) {
        window.KxCreateModPreview.watch(photo, item.createUrl, (photoUrl) => {
          if (!photoUrl || !photo.isConnected) {
            placeholder.textContent = "Ver imágenes originales en CreateMod";
            return;
          }
          const src = safeImage(photoUrl);
          if (!src) return;
          const img = el("img", "shop-image");
          img.src = src;
          img.alt = "Vista original de " + item.title + " en CreateMod";
          img.loading = "lazy";
          img.decoding = "async";
          img.referrerPolicy = "no-referrer";
          img.addEventListener("load", () => placeholder.replaceWith(img), {once:true});
          img.addEventListener("error", () => {placeholder.textContent = "Ver imágenes originales en CreateMod";}, {once:true});
        });
      }
    }
    const body = el("div", "shop-card-body");
    body.append(el("span", "shop-card-category", item.category));
    body.append(el("h2", "shop-card-name", item.title));
    if (typeof item.description === "string" && item.description.trim()) body.append(el("p", "shop-card-description", item.description));
    const missingMods = Array.isArray(item.missingMods) ? [...new Set(item.missingMods.filter(v => typeof v === "string" && v.trim()))] : [];
    if (missingMods.length) {
      const missingNote = el("p", "shop-card-missing-mods");
      missingNote.append(el("strong", "", "Mods faltantes: "), document.createTextNode(missingMods.join(", ")));
      body.append(missingNote);
    }
    body.append(el("span", "shop-card-price-label", "Precio de construcción armada"));
    body.append(el("strong", "shop-card-price", item.price));
    const repairCost = Number.isInteger(item.repairCostArs) && item.repairCostArs >= 0 ? item.repairCostArs : 8000;
    body.append(el("span", "shop-card-repair", `Costo de reparación: ${new Intl.NumberFormat("es-AR").format(repairCost)} ARS`));
    if (item.category === "Aeronaves") body.append(el("span", "shop-card-repair", "Disponibilidad: 1 unidad"));
    card.append(photo, body);
    return card;
  };
  const show = () => {
    const priced = items.filter(item => hasPrice(item.price));
    priced.sort((a,b) => priceNumber(b.price) - priceNumber(a.price) || collator.compare(a.title,b.title));
    empty.hidden = priced.length > 0;
    const cards = priced.map(makeCard);
    grid.replaceChildren(...cards);
    count.textContent = `${cards.length} construcción${cards.length === 1 ? "" : "es"} con precio`;
  };
  show();
})();
