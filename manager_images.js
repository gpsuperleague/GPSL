/**
 * Manager portraits — images/managers/{slug}.jpg (see scripts/fetch_manager_images.mjs).
 * Only loads images listed in data/manager_portraits.json (avoids 404 spam on GitHub Pages).
 */

let portraitSlugs = null;
let manifestPromise = null;

export async function loadManagerPortraitManifest() {
  if (portraitSlugs) return portraitSlugs;
  if (!manifestPromise) {
    manifestPromise = (async () => {
      try {
        const url = new URL("./data/manager_portraits.json", import.meta.url);
        const res = await fetch(`${url.href}?v=${Date.now()}`);
        if (!res.ok) {
          portraitSlugs = new Set();
          return portraitSlugs;
        }
        const data = await res.json();
        const list = Array.isArray(data?.slugs) ? data.slugs : [];
        portraitSlugs = new Set(list.map((s) => String(s).trim().toLowerCase()).filter(Boolean));
      } catch {
        portraitSlugs = new Set();
      }
      return portraitSlugs;
    })();
  }
  return manifestPromise;
}

export function hasManagerPortrait(slug) {
  const key = String(slug || "").trim().toLowerCase();
  if (!key || !portraitSlugs) return false;
  return portraitSlugs.has(key);
}

export function managerImageUrl(slug, ext = "jpg") {
  const key = String(slug || "").trim().toLowerCase();
  if (!key || !hasManagerPortrait(key)) return null;
  return `images/managers/${key}.${ext}`;
}

/** Apply portrait to an <img>; tries jpg then png, then optional fallback element. */
export async function applyManagerPortrait(imgEl, slug, { fallbackEl = null, name = "" } = {}) {
  if (!imgEl) return;
  await loadManagerPortraitManifest();

  const key = String(slug || "").trim().toLowerCase();
  if (!key || !hasManagerPortrait(key)) {
    imgEl.style.display = "none";
    imgEl.removeAttribute("src");
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
      imgEl.removeAttribute("src");
      return;
    }
    const png = managerImageUrl(key, "png");
    if (!png) {
      showFallback();
      return;
    }
    imgEl.dataset.triedPng = "1";
    imgEl.src = png;
  };

  delete imgEl.dataset.triedPng;
  imgEl.alt = String(name || "").trim();
  const jpg = managerImageUrl(key, "jpg");
  if (!jpg) {
    showFallback();
    return;
  }
  imgEl.src = jpg;
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

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Inline thumb + name for auction list rows (call after loadManagerPortraitManifest). */
export function managerListCellHtml(mgr) {
  const slug = String(mgr?.slug || "").trim().toLowerCase();
  const name = mgr?.name || "—";
  const initials = managerInitials(name);
  const hasImg = slug && hasManagerPortrait(slug);
  const src = hasImg ? managerImageUrl(slug) : "";
  const thumb = hasImg
    ? `<span class="manager-list-thumb-wrap">
        <img class="manager-list-thumb" src="${escapeHtml(src)}" alt=""
          onerror="this.hidden=true;this.nextElementSibling.hidden=false;this.removeAttribute('src');">
        <span class="manager-list-thumb-fallback" hidden>${escapeHtml(initials)}</span>
      </span>`
    : `<span class="manager-list-thumb-wrap"><span class="manager-list-thumb-fallback">${escapeHtml(initials)}</span></span>`;
  const id = mgr?.id;
  const href = id ? `manager_draftauction_manager.html?manager=${id}` : "#";
  return `<span class="manager-list-cell">${thumb}<a class="player-link" href="${href}">${escapeHtml(name)}</a></span>`;
}
