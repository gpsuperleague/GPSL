/** Club dashboard theme — kit colour sampling, save/load, CSS apply */

import {
  defaultKitImagePath,
  isCrossOriginImageUrl,
  kitSampleSrcCandidates,
  kitUrlFromRow,
  resolveKitImageSrc,
} from "./club_kits_common.js";

export const GPSL_THEME_DEFAULTS = {
  enabled: false,
  color_primary: "#ff9900",
  color_secondary: "#1a1a1a",
  color_border: "#333333",
  color_text: "#ff9900",
  theme_scope: "dashboard",
  source_kit: "manual",
};

/** Where club colours apply (top nav always stays GPSL orange). */
export const THEME_SCOPES = {
  dashboard: "dashboard",
  clubPages: "club_pages",
};

/** @typedef {'dashboard'|'club_details'} ThemePageKey */

export function normalizeThemeScope(value) {
  const v = String(value ?? "")
    .trim()
    .toLowerCase();
  if (v === THEME_SCOPES.clubPages) return THEME_SCOPES.clubPages;
  return THEME_SCOPES.dashboard;
}

export function themeAppliesOnPage(theme, pageKey) {
  if (!theme?.enabled) return false;
  const scope = normalizeThemeScope(theme.theme_scope);
  if (pageKey === "dashboard") return true;
  if (pageKey === "club_details") return scope === THEME_SCOPES.clubPages;
  return false;
}

/** Suggested tile label colour when sampling from a kit. */
export const GPSL_THEME_SUGGESTED_TILE_TEXT = "#ffffff";

const HEX_RE = /^#[0-9a-f]{6}$/i;

export function normalizeHexColor(value, fallback = null) {
  const v = String(value ?? "")
    .trim()
    .toLowerCase();
  if (HEX_RE.test(v)) return v;
  return fallback;
}

export function hexToRgb(hex) {
  const n = normalizeHexColor(hex);
  if (!n) return null;
  return {
    r: parseInt(n.slice(1, 3), 16),
    g: parseInt(n.slice(3, 5), 16),
    b: parseInt(n.slice(5, 7), 16),
  };
}

export function rgbToHex(r, g, b) {
  const clamp = (v) => Math.max(0, Math.min(255, Math.round(v)));
  return (
    "#" +
    [clamp(r), clamp(g), clamp(b)]
      .map((c) => c.toString(16).padStart(2, "0"))
      .join("")
  );
}

export function mixHex(hexA, hexB, t) {
  const a = hexToRgb(hexA);
  const b = hexToRgb(hexB);
  if (!a || !b) return hexA || hexB || GPSL_THEME_DEFAULTS.color_primary;
  const w = Math.max(0, Math.min(1, t));
  return rgbToHex(
    a.r + (b.r - a.r) * w,
    a.g + (b.g - a.g) * w,
    a.b + (b.b - a.b) * w
  );
}

function colorSaturation(r, g, b) {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  if (max === 0) return 0;
  return (max - min) / max;
}

function hueDistance(a, b) {
  const diff = Math.abs(a - b);
  return Math.min(diff, 360 - diff);
}

function rgbToHue(r, g, b) {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  if (d === 0) return 0;
  let h;
  if (max === r) h = ((g - b) / d) % 6;
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  h *= 60;
  if (h < 0) h += 360;
  return h;
}

function isSkippablePixel(r, g, b, a) {
  if (a < 128) return true;
  if (r > 235 && g > 235 && b > 235) return true;
  if (r < 22 && g < 22 && b < 22) return true;
  return false;
}

function bucketKey(r, g, b) {
  const step = 16;
  const br = Math.floor(r / step) * step + step / 2;
  const bg = Math.floor(g / step) * step + step / 2;
  const bb = Math.floor(b / step) * step + step / 2;
  return `${br},${bg},${bb}`;
}

export function deriveThemeFromPrimary(primary) {
  const p = normalizeHexColor(primary, GPSL_THEME_DEFAULTS.color_primary);
  return {
    color_primary: p,
    color_secondary: mixHex(GPSL_THEME_DEFAULTS.color_secondary, p, 0.1),
    color_border: mixHex(GPSL_THEME_DEFAULTS.color_border, p, 0.38),
  };
}

function loadImageElement(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    if (/^https?:\/\//i.test(src)) {
      img.crossOrigin = "anonymous";
    }
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("Could not load kit image"));
    img.src = src;
  });
}

function readCanvasPixels(ctx, width, height) {
  try {
    return ctx.getImageData(0, 0, width, height);
  } catch {
    throw new Error("Kit image blocked by browser security (CORS)");
  }
}

export async function extractKitThemeColors(imageSrc) {
  const img = await loadImageElement(imageSrc);
  const size = 64;
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) throw new Error("Canvas unavailable");

  ctx.drawImage(img, 0, 0, size, size);
  const { data } = readCanvasPixels(ctx, size, size);
  const counts = new Map();

  for (let i = 0; i < data.length; i += 4) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    const a = data[i + 3];
    if (isSkippablePixel(r, g, b, a)) continue;
    const key = bucketKey(r, g, b);
    counts.set(key, (counts.get(key) || 0) + 1);
  }

  if (!counts.size) {
    return { ...GPSL_THEME_DEFAULTS, source_kit: "manual" };
  }

  const ranked = [...counts.entries()]
    .map(([key, count]) => {
      const [r, g, b] = key.split(",").map(Number);
      return {
        r,
        g,
        b,
        count,
        sat: colorSaturation(r, g, b),
        hue: rgbToHue(r, g, b),
        hex: rgbToHex(r, g, b),
      };
    })
    .sort((a, b) => b.count - a.count);

  const total = ranked.reduce((s, c) => s + c.count, 0);
  const minCount = Math.max(3, total * 0.02);

  const candidates = ranked.filter((c) => c.count >= minCount);
  const pool = candidates.length ? candidates : ranked.slice(0, 8);

  pool.sort((a, b) => b.sat * Math.log(b.count + 1) - a.sat * Math.log(a.count + 1));
  const primary = pool[0]?.hex || GPSL_THEME_DEFAULTS.color_primary;

  let secondary = null;
  const primaryHue = pool[0]?.hue ?? 0;
  for (const c of ranked) {
    if (c.hex === primary) continue;
    if (hueDistance(c.hue, primaryHue) >= 25 && c.sat >= 0.12) {
      secondary = mixHex(GPSL_THEME_DEFAULTS.color_secondary, c.hex, 0.22);
      break;
    }
  }
  if (!secondary) {
    secondary = deriveThemeFromPrimary(primary).color_secondary;
  }

  const border = deriveThemeFromPrimary(primary).color_border;

  return {
    enabled: true,
    color_primary: primary,
    color_secondary: secondary,
    color_border: border,
    color_text: GPSL_THEME_SUGGESTED_TILE_TEXT,
    source_kit: "manual",
  };
}

export function kitImageSrcForKind(clubShort, kitRow, kind) {
  const url = kitUrlFromRow(kitRow, kind);
  return resolveKitImageSrc(url, clubShort, kind);
}

export async function suggestThemeFromKit(clubShort, kitRow, kind = "home") {
  const dbUrl = kitUrlFromRow(kitRow, kind);
  const candidates = kitSampleSrcCandidates(dbUrl, clubShort, kind);
  let lastError = null;

  for (const src of candidates) {
    try {
      const colors = await extractKitThemeColors(src);
      return { ...colors, source_kit: kind };
    } catch (err) {
      lastError = err;
    }
  }

  const local = defaultKitImagePath(clubShort, kind);
  if (dbUrl && isCrossOriginImageUrl(resolveKitImageSrc(dbUrl, clubShort, kind))) {
    throw new Error(
      `Could not sample kit colours from ${local}. External kit URLs cannot be read — ask admin to sync local kit images.`
    );
  }

  throw lastError || new Error("Could not sample kit colours");
}

export function normalizeThemeRow(row) {
  if (!row) return { ...GPSL_THEME_DEFAULTS };
  return {
    enabled: row.enabled === true,
    color_primary:
      normalizeHexColor(row.color_primary, GPSL_THEME_DEFAULTS.color_primary) ||
      GPSL_THEME_DEFAULTS.color_primary,
    color_secondary:
      normalizeHexColor(row.color_secondary, GPSL_THEME_DEFAULTS.color_secondary) ||
      GPSL_THEME_DEFAULTS.color_secondary,
    color_border:
      normalizeHexColor(row.color_border, GPSL_THEME_DEFAULTS.color_border) ||
      GPSL_THEME_DEFAULTS.color_border,
    color_text:
      normalizeHexColor(row.color_text, null) ||
      (row.enabled === true
        ? GPSL_THEME_SUGGESTED_TILE_TEXT
        : GPSL_THEME_DEFAULTS.color_text),
    theme_scope: normalizeThemeScope(row.theme_scope),
    source_kit: row.source_kit || "manual",
  };
}

export async function loadClubDashboardTheme(supabase, clubShort) {
  if (!clubShort) return { ...GPSL_THEME_DEFAULTS };

  const { data, error } = await supabase
    .from("club_dashboard_theme")
    .select(
      "club_short_name, enabled, color_primary, color_secondary, color_border, color_text, theme_scope, source_kit"
    )
    .eq("club_short_name", clubShort)
    .maybeSingle();

  if (error) {
    if (error.code === "PGRST205" || error.code === "42P01") {
      return { ...GPSL_THEME_DEFAULTS };
    }
    throw error;
  }

  return normalizeThemeRow(data);
}

export async function saveClubDashboardTheme(supabase, theme) {
  const payload = {
    p_enabled: theme.enabled === true,
    p_color_primary:
      normalizeHexColor(theme.color_primary, GPSL_THEME_DEFAULTS.color_primary) ||
      GPSL_THEME_DEFAULTS.color_primary,
    p_color_secondary:
      normalizeHexColor(theme.color_secondary, GPSL_THEME_DEFAULTS.color_secondary) ||
      GPSL_THEME_DEFAULTS.color_secondary,
    p_color_border:
      normalizeHexColor(theme.color_border, GPSL_THEME_DEFAULTS.color_border) ||
      GPSL_THEME_DEFAULTS.color_border,
    p_color_text:
      normalizeHexColor(theme.color_text, GPSL_THEME_DEFAULTS.color_text) ||
      GPSL_THEME_DEFAULTS.color_text,
    p_theme_scope: normalizeThemeScope(theme.theme_scope),
    p_source_kit: theme.source_kit || "manual",
  };

  const { data, error } = await supabase.rpc("club_owner_dashboard_theme_save", payload);
  if (error) throw error;
  return data;
}

function clearClubThemeVars(scope) {
  if (!scope) return;
  scope.classList.remove("club-themed-scope");
  scope.style.removeProperty("--club-accent");
  scope.style.removeProperty("--club-panel");
  scope.style.removeProperty("--club-border");
  scope.style.removeProperty("--club-tile-text");
  scope.style.removeProperty("--club-glow");
  scope.style.removeProperty("--club-accent-rgb");
}

export function applyClubDashboardTheme(theme, options = {}) {
  const scope =
    options.scopeEl || document.querySelector(".page-container") || document.body;
  const pageKey = options.pageKey || window.CURRENT_PAGE || "dashboard";
  const active = themeAppliesOnPage(theme, pageKey);

  if (!active) {
    clearClubThemeVars(scope);
    return;
  }

  scope.classList.add("club-themed-scope");

  const primary =
    normalizeHexColor(theme.color_primary, GPSL_THEME_DEFAULTS.color_primary) ||
    GPSL_THEME_DEFAULTS.color_primary;
  const secondary =
    normalizeHexColor(theme.color_secondary, GPSL_THEME_DEFAULTS.color_secondary) ||
    GPSL_THEME_DEFAULTS.color_secondary;
  const border =
    normalizeHexColor(theme.color_border, GPSL_THEME_DEFAULTS.color_border) ||
    GPSL_THEME_DEFAULTS.color_border;
  const tileText =
    normalizeHexColor(theme.color_text, GPSL_THEME_DEFAULTS.color_text) ||
    GPSL_THEME_DEFAULTS.color_text;
  const rgb = hexToRgb(primary) || { r: 255, g: 153, b: 0 };

  scope.style.setProperty("--club-accent", primary);
  scope.style.setProperty("--club-panel", secondary);
  scope.style.setProperty("--club-border", border);
  scope.style.setProperty("--club-tile-text", tileText);
  scope.style.setProperty("--club-glow", `rgba(${rgb.r}, ${rgb.g}, ${rgb.b}, 0.14)`);
  scope.style.setProperty("--club-accent-rgb", `${rgb.r}, ${rgb.g}, ${rgb.b}`);
}

export function renderThemePreviewHtml(theme) {
  const t = normalizeThemeRow(theme);
  return `
    <div class="theme-preview-card" style="
      background: ${t.color_secondary};
      border: 1px solid ${t.color_border};
      border-radius: 8px;
      padding: 12px 14px;
      box-shadow: inset 0 0 28px rgba(0,0,0,0.35);
    ">
      <div style="color:${t.color_primary};font-weight:bold;font-size:15px;margin-bottom:4px;">
        Sample dashboard header
      </div>
      <div style="color:#aaa;font-size:12px;margin-bottom:10px;">Dark GPSL base with club accents</div>
      <div style="
        display:inline-block;
        padding:8px 14px;
        border-radius:8px;
        border:1px solid ${t.color_border};
        color:${t.color_text};
        font-weight:bold;
        font-size:13px;
      ">Tile label</div>
    </div>`;
}
