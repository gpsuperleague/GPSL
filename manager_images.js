/**
 * Manager portrait paths — images/managers/{slug}.jpg (see scripts/fetch_manager_images.mjs).
 */

export function managerImageUrl(slug, ext = "jpg") {
  const key = String(slug || "").trim();
  if (!key) return null;
  return `images/managers/${key}.${ext}`;
}

/** Apply portrait to an <img>; tries jpg then png, then optional fallback element. */
export function applyManagerPortrait(imgEl, slug, { fallbackEl = null, name = "" } = {}) {
  if (!imgEl) return;
  const key = String(slug || "").trim();
  if (!key) {
    imgEl.style.display = "none";
    if (fallbackEl) fallbackEl.hidden = false;
    return;
  }

  const showFallback = () => {
    imgEl.style.display = "none";
    if (fallbackEl) fallbackEl.hidden = false;
  };

  const showImage = () => {
    imgEl.style.display = "";
    if (fallbackEl) fallbackEl.hidden = true;
  };

  showFallback();

  imgEl.onerror = () => {
    if (imgEl.dataset.triedPng === "1") {
      showFallback();
      return;
    }
    imgEl.dataset.triedPng = "1";
    imgEl.src = managerImageUrl(key, "png");
  };

  delete imgEl.dataset.triedPng;
  imgEl.alt = String(name || "").trim();
  imgEl.src = managerImageUrl(key, "jpg");
  imgEl.onload = showImage;
}

export function managerInitials(name) {
  const parts = String(name || "")
    .trim()
    .replace(/[.\u00b7]/g, " ")
    .split(/\s+/)
    .filter(Boolean);
  if (!parts.length) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return `${parts[0][0] || ""}${parts[parts.length - 1][0] || ""}`.toUpperCase();
}

/** Inline thumb + name for auction list rows. */
export function managerListCellHtml(mgr) {
  const slug = String(mgr?.slug || "").trim();
  const name = mgr?.name || "—";
  const initials = managerInitials(name);
  const src = slug ? managerImageUrl(slug) : "";
  const thumb = slug
    ? `<span class="manager-list-thumb-wrap">
        <img class="manager-list-thumb" src="${src}" alt=""
          onerror="this.hidden=true;this.nextElementSibling.hidden=false">
        <span class="manager-list-thumb-fallback" hidden>${initials}</span>
      </span>`
    : `<span class="manager-list-thumb-wrap"><span class="manager-list-thumb-fallback">${initials}</span></span>`;
  const id = mgr?.id;
  const href = id ? `manager_draftauction_manager.html?manager=${id}` : "#";
  return `<span class="manager-list-cell">${thumb}<a class="player-link" href="${href}">${name}</a></span>`;
}
