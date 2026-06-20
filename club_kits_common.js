/** Club kit image helpers — home / away / third */

export const KIT_KINDS = ["home", "away", "third"];

export const KIT_LABELS = {
  home: "Home kit",
  away: "Away kit",
  third: "3rd kit",
};

const KIT_COLUMN = {
  home: "home_image_url",
  away: "away_image_url",
  third: "third_image_url",
};

export function defaultKitImagePath(clubShort, kind) {
  const short = String(clubShort || "").trim().toUpperCase();
  const k = String(kind || "home").toLowerCase();
  return `images/clubs_kits/${short}_${k}.png`;
}

/** True when a URL is http(s) on another site (canvas cannot read pixels). */
export function isCrossOriginImageUrl(url) {
  const trimmed = String(url ?? "").trim();
  if (!trimmed || trimmed.startsWith("data:")) return false;
  if (!/^https?:\/\//i.test(trimmed)) return false;
  try {
    const parsed = new URL(trimmed, window.location.href);
    return parsed.origin !== window.location.origin;
  } catch {
    return true;
  }
}

/**
 * Image paths safe for canvas colour sampling — prefers synced local PNGs
 * when the DB stores external Colours-of-Football URLs.
 */
export function kitSampleSrcCandidates(url, clubShort, kind) {
  const local = defaultKitImagePath(clubShort, kind);
  const candidates = [local];
  const resolved = url ? resolveKitImageSrc(url, clubShort, kind) : null;
  if (resolved && resolved !== local && !isCrossOriginImageUrl(resolved)) {
    candidates.push(resolved);
  }
  return candidates;
}

export function resolveKitImageSrc(url, clubShort, kind) {
  const trimmed = String(url ?? "").trim();
  if (trimmed) return trimmed;
  return defaultKitImagePath(clubShort, kind);
}

export function kitUrlFromRow(row, kind) {
  if (!row) return null;
  const col = KIT_COLUMN[kind];
  return row[col] ?? null;
}

export async function loadClubKits(supabase, clubShort) {
  if (!clubShort) return null;

  const { data, error } = await supabase
    .from("club_kits")
    .select("club_short_name, home_image_url, away_image_url, third_image_url, updated_at")
    .eq("club_short_name", clubShort)
    .maybeSingle();

  if (error) {
    if (error.code === "PGRST205" || error.code === "42P01") {
      return null;
    }
    throw error;
  }

  return data;
}

export function renderKitCardHtml(clubShort, kind, url, { compact = false } = {}) {
  const src = resolveKitImageSrc(url, clubShort, kind);
  const label = KIT_LABELS[kind] || kind;
  const imgClass = compact ? "club-kit-img club-kit-img--compact" : "club-kit-img";

  return `
    <div class="club-kit-card" data-kit-kind="${kind}">
      <div class="club-kit-label">${label}</div>
      <img
        class="${imgClass}"
        src="${escapeAttr(src)}"
        alt="${escapeAttr(label)}"
        loading="lazy"
        onerror="this.classList.add('club-kit-img--missing'); this.alt='No image';"
      >
    </div>`;
}

export function renderKitsPanelHtml(clubShort, kitRow, { compact = false } = {}) {
  return `
    <div class="club-kits-grid${compact ? " club-kits-grid--compact" : ""}">
      ${KIT_KINDS.map((kind) =>
        renderKitCardHtml(clubShort, kind, kitUrlFromRow(kitRow, kind), { compact })
      ).join("")}
    </div>`;
}

function escapeAttr(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}
