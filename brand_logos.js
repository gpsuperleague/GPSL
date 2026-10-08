/**
 * Sponsor brand logos: images/brands/<slug>.webp, lettered badge otherwise.
 */
import { KOFI_URL, KOFI_CUP_SRC } from "./support_banner.js";

export const KOFI_BRAND = "GPSL on Ko-fi";

/** Slugs with an image in images/brands/ (add as batches are generated). */
const LOGO_SLUGS = new Set([
  "volta-motors",
  "northgate-bank",
  "aurelia-watches",
  "skyline-airways",
  "nimbus-mobile",
  "meridian-insurance",
  "crown-anchor-hotels",
  "orbital-tech",
  "halcyon-resorts",
  "apex-fuels",
  "silverline-rail",
  "quantum-cloud",
  "regal-cola",
  "zenith-capital",
  "lumen-electronics",
  "atlas-logistics",
  "low-air",
  "lovely-buttery",
  "fizzpop",
  "brew-brothers",
  "bytewave-broadband",
  "pixel-forge",
  "sole-mate",
  "zappo-energy",
  "crunchwell-crisps",
  "snugglebed",
  "kwik-klean",
  "golden-crumb",
  "moo-co",
  "sky-pillow-hotels",
  "trusty-tyres",
  "sparkle-smile",
  "chillbox",
  "pawfect",
  "rapid-rentals",
  "driftwave",
  "fitfuel",
  "homely-homes",
]);

export function brandSlug(name) {
  return String(name || "")
    .toLowerCase()
    .replace(/['’]/g, "")
    .replace(/&/g, " ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function isKofiBrand(name) {
  return String(name || "") === KOFI_BRAND;
}

export function brandLogoSrc(name) {
  if (isKofiBrand(name)) return KOFI_CUP_SRC;
  const slug = brandSlug(name);
  return LOGO_SLUGS.has(slug) ? `images/brands/${slug}.webp` : null;
}

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function initials(name) {
  return String(name || "?")
    .split(/[\s&]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0].toUpperCase())
    .join("");
}

function hue(name) {
  let h = 0;
  for (const ch of String(name || "")) h = (h * 31 + ch.charCodeAt(0)) % 360;
  return h;
}

/**
 * @param {string} name
 * @param {string} [cls] extra class, e.g. "brand-logo--lg"
 */
export function brandLogoHtml(name, cls = "") {
  const src = brandLogoSrc(name);
  const klass = `brand-logo ${cls}`.trim();
  if (src) {
    return `<img class="${klass}${isKofiBrand(name) ? " brand-logo--kofi" : ""}" src="${src}" alt="${esc(name)}" loading="lazy">`;
  }
  return `<span class="${klass} brand-logo--text" style="--brand-hue:${hue(name)}" aria-hidden="true">${esc(
    initials(name)
  )}</span>`;
}

export { KOFI_URL };
