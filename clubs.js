import { supabase, initGlobal } from "./global.js";
import { escapeHtml } from "./escape_html.js";

/** @typedef {{
 *   ShortName: string,
 *   Club: string,
 *   owner?: string|null,
 *   owner_id?: string|null,
 *   is_archived?: boolean,
 *   division?: string|null,
 * }} ClubRow */

/** @type {ClubRow[]} */
let allClubs = [];

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubs();
  wireFilters();
});

function divisionLabel(div) {
  const d = String(div || "").toLowerCase();
  if (d === "superleague") return "Super League";
  if (d === "championship_a") return "Championship A";
  if (d === "championship_b") return "Championship B";
  if (d.startsWith("championship")) return "Championship";
  return "";
}

function isChampionshipDiv(div) {
  const d = String(div || "").toLowerCase();
  return d === "championship_a" || d === "championship_b" || d.startsWith("championship");
}

function sectionForClub(club) {
  const owned = Boolean(club.owner_id);
  const div = String(club.division || "").toLowerCase();
  if (owned) {
    if (div === "superleague") return "superleague";
    if (isChampionshipDiv(div)) return "championship";
    return "other";
  }
  // Vacant: keep league seats separate from pool clubs with no division
  if (div === "superleague") return "empty_superleague";
  if (isChampionshipDiv(div)) return "empty_championship";
  return "unowned";
}

function alphaClubName(a, b) {
  return String(a.Club || a.ShortName || "").localeCompare(
    String(b.Club || b.ShortName || ""),
    "en",
    { sensitivity: "base" }
  );
}

async function loadClubs() {
  const clubsRes = await supabase
    .from("Clubs")
    .select("ShortName, Club, owner, owner_id, is_archived")
    .neq("ShortName", "FOREIGN")
    .order("Club", { ascending: true });

  if (clubsRes.error) {
    console.error(clubsRes.error);
    return;
  }

  let rows = (clubsRes.data || []).filter((c) => !c.is_archived);

  /** @type {Map<string, string>} */
  const divisionByClub = new Map();
  const { data: season } = await supabase
    .from("competition_seasons")
    .select("id")
    .eq("is_current", true)
    .maybeSingle();

  if (season?.id) {
    const { data: seasons, error: divErr } = await supabase
      .from("competition_club_seasons")
      .select("club_short_name, division")
      .eq("season_id", season.id);
    if (divErr) {
      console.warn("competition_club_seasons:", divErr);
    } else {
      for (const row of seasons || []) {
        divisionByClub.set(String(row.club_short_name), row.division);
      }
    }
  }

  allClubs = rows.map((c) => ({
    ...c,
    division: divisionByClub.get(String(c.ShortName)) || null,
  }));

  fillFilterDropdowns();
  renderClubs();
}

function fillFilterDropdowns() {
  const clubSel = document.getElementById("clubSearch");
  const ownerSel = document.getElementById("ownerSearch");
  if (!clubSel || !ownerSel) return;

  const clubOptions = [...allClubs].sort(alphaClubName);
  clubSel.innerHTML =
    `<option value="">All clubs</option>` +
    clubOptions
      .map(
        (c) =>
          `<option value="${escapeHtml(c.ShortName)}">${escapeHtml(
            c.Club || c.ShortName
          )}</option>`
      )
      .join("");

  /** @type {Map<string, string>} owner_id → tag */
  const owners = new Map();
  for (const c of allClubs) {
    if (!c.owner_id) continue;
    const tag = String(c.owner || "").trim() || String(c.owner_id);
    if (!owners.has(String(c.owner_id))) owners.set(String(c.owner_id), tag);
  }
  const ownerOptions = [...owners.entries()].sort((a, b) =>
    a[1].localeCompare(b[1], "en", { sensitivity: "base" })
  );
  ownerSel.innerHTML =
    `<option value="">All owners</option>` +
    ownerOptions
      .map(
        ([id, tag]) =>
          `<option value="${escapeHtml(id)}">${escapeHtml(tag)}</option>`
      )
      .join("");
}

function wireFilters() {
  const clubSel = document.getElementById("clubSearch");
  const ownerSel = document.getElementById("ownerSearch");
  const clearBtn = document.getElementById("clearClubFilters");

  clubSel?.addEventListener("change", () => {
    if (clubSel.value && ownerSel) ownerSel.value = "";
    renderClubs();
  });
  ownerSel?.addEventListener("change", () => {
    if (ownerSel.value && clubSel) clubSel.value = "";
    renderClubs();
  });
  clearBtn?.addEventListener("click", () => {
    if (clubSel) clubSel.value = "";
    if (ownerSel) ownerSel.value = "";
    renderClubs();
  });
}

function filteredClubs() {
  const clubSel = document.getElementById("clubSearch");
  const ownerSel = document.getElementById("ownerSearch");
  const clubFilter = clubSel?.value || "";
  const ownerFilter = ownerSel?.value || "";

  return allClubs.filter((c) => {
    if (clubFilter && String(c.ShortName) !== clubFilter) return false;
    if (ownerFilter && String(c.owner_id || "") !== ownerFilter) return false;
    return true;
  });
}

function clubCardHtml(club, { focus = false } = {}) {
  const name = escapeHtml(club.Club || club.ShortName);
  const short = escapeHtml(club.ShortName);
  const owner = club.owner_id
    ? escapeHtml(String(club.owner || "").trim() || "Owner")
    : "Vacant";
  const divTag = divisionLabel(club.division);
  const divHtml = divTag
    ? `<div class="club-div-tag">${escapeHtml(divTag)}</div>`
    : "";
  return `
    <div class="club-card${focus ? " is-focus" : ""}" data-short="${short}" role="link" tabindex="0">
      <img src="images/club_badges/${short}.png" alt="${name} badge" loading="lazy"
           onerror="this.style.visibility='hidden'">
      <div class="club-name">${name}</div>
      <div class="club-owner">${owner}</div>
      ${divHtml}
    </div>
  `;
}

function renderSection(title, clubs) {
  if (!clubs.length) return "";
  const focusShort = document.getElementById("clubSearch")?.value || "";
  const cards = clubs
    .map((c) =>
      clubCardHtml(c, {
        focus: focusShort && c.ShortName === focusShort,
      })
    )
    .join("");
  return `
    <section class="clubs-section">
      <h2 class="clubs-section-title">${escapeHtml(title)}<span class="count">(${clubs.length})</span></h2>
      <div class="club-grid">${cards}</div>
    </section>
  `;
}

function renderClubs() {
  const root = document.getElementById("clubsSections");
  const empty = document.getElementById("clubsEmpty");
  if (!root) return;

  const list = filteredClubs();
  const bySection = (key) =>
    list.filter((c) => sectionForClub(c) === key).sort(alphaClubName);

  root.innerHTML =
    renderSection("Super League", bySection("superleague")) +
    renderSection("Championship", bySection("championship")) +
    renderSection("Empty Super League", bySection("empty_superleague")) +
    renderSection("Empty Championship", bySection("empty_championship")) +
    renderSection("Other owned", bySection("other")) +
    renderSection("Unowned (no division)", bySection("unowned"));

  empty.hidden = list.length > 0;

  root.querySelectorAll(".club-card").forEach((card) => {
    const go = () => {
      const short = card.getAttribute("data-short");
      if (!short) return;
      window.location.href = `club.html?club=${encodeURIComponent(short)}`;
    };
    card.addEventListener("click", go);
    card.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        go();
      }
    });
  });

  const focus = root.querySelector(".club-card.is-focus");
  if (focus) {
    focus.scrollIntoView({ behavior: "smooth", block: "center" });
  }
}
