import { initGlobal, supabase } from "./global.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import { contractYearsLabel } from "./player_contracts.js";
import {
  playerThumbLinkHtml,
  playerNameLinkHtml,
} from "./player_links.js";
import { renderLegacyPlayersRules } from "./legacy_players_rules.js";
import { textMatchesSearch } from "./search_normalize.js";

/** @type {object[]} */
let legacyRows = [];

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function formatLegacySince(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  } catch {
    return "—";
  }
}

function clubKey(r) {
  const raw = String(r?.club ?? "").trim();
  return raw || "__free_agent__";
}

function clubLabel(r) {
  const raw = String(r?.club ?? "").trim();
  if (!raw) return "Free agent";
  return displayClubName(raw) || raw;
}

function rowSearchHaystack(r) {
  return [r.player_name, clubLabel(r), r.konami_id, r.position, r.nation]
    .filter((x) => x != null && String(x).trim() !== "")
    .join(" ");
}

function filteredLegacyRows() {
  const q = document.getElementById("legacyPlayerSearch")?.value ?? "";
  const club = document.getElementById("legacyClubFilter")?.value ?? "";
  return legacyRows.filter((r) => {
    if (club && clubKey(r) !== club) return false;
    return textMatchesSearch(rowSearchHaystack(r), q);
  });
}

function populateClubFilter() {
  const sel = document.getElementById("legacyClubFilter");
  if (!sel) return;
  const prev = sel.value;
  const byKey = new Map();
  for (const r of legacyRows) {
    const key = clubKey(r);
    if (!byKey.has(key)) byKey.set(key, clubLabel(r));
  }
  const options = [...byKey.entries()].sort((a, b) =>
    a[1].localeCompare(b[1], undefined, { sensitivity: "base" })
  );
  sel.innerHTML =
    `<option value="">All clubs</option>` +
    options
      .map(
        ([key, label]) =>
          `<option value="${escapeHtml(key)}">${escapeHtml(label)}</option>`
      )
      .join("");
  if (prev && [...byKey.keys()].includes(prev)) sel.value = prev;
  else sel.value = "";
}

function filtersActive() {
  const q = document.getElementById("legacyPlayerSearch")?.value?.trim();
  const club = document.getElementById("legacyClubFilter")?.value;
  return Boolean(q || club);
}

function updateStatus(visibleCount) {
  const status = document.getElementById("listStatus");
  if (!status) return;
  const total = legacyRows.length;
  if (total === 0) {
    status.textContent =
      "No legacy players at the moment — all GPDB cards match the latest PESDB scrape.";
    return;
  }
  if (filtersActive()) {
    status.textContent = `Showing ${visibleCount} of ${total} legacy player${total === 1 ? "" : "s"}.`;
  } else {
    status.textContent = `${total} legacy player${total === 1 ? "" : "s"} across GPSL clubs.`;
  }
}

function renderLegacyTable(rows) {
  const tbody = document.getElementById("legacyBody");
  if (!tbody) return;

  if (!rows.length) {
    const emptyMsg = legacyRows.length
      ? "No legacy players match these filters."
      : "No legacy cards listed.";
    tbody.innerHTML = `<tr><td colspan="7" class="empty-note">${emptyMsg}</td></tr>`;
    updateStatus(0);
    return;
  }

  tbody.innerHTML = rows
    .map((r) => {
      const club = clubLabel(r);
      const contract = contractYearsLabel(r.contract_seasons_remaining);
      const contractNote =
        Number(r.contract_seasons_remaining) === 1
          ? `${contract} · renew 1 yr from Squad`
          : contract;
      return `
    <tr>
      <td>${playerThumbLinkHtml(r.konami_id, { alt: r.player_name })}</td>
      <td>${playerNameLinkHtml(r.konami_id, r.player_name)}</td>
      <td class="num">${escapeHtml(r.position || "—")}</td>
      <td class="num">${escapeHtml(r.rating || "—")}</td>
      <td>${escapeHtml(club)}</td>
      <td><span class="tag-legacy">${escapeHtml(contractNote)}</span></td>
      <td class="num">${escapeHtml(formatLegacySince(r.unavailable_since))}</td>
    </tr>`;
    })
    .join("");
  updateStatus(rows.length);
}

function applyLegacyFilters() {
  renderLegacyTable(filteredLegacyRows());
}

function wireLegacyFilters() {
  const input = document.getElementById("legacyPlayerSearch");
  const clubSel = document.getElementById("legacyClubFilter");
  if (input && input.dataset.wired !== "1") {
    input.dataset.wired = "1";
    input.addEventListener("input", () => applyLegacyFilters());
  }
  if (clubSel && clubSel.dataset.wired !== "1") {
    clubSel.dataset.wired = "1";
    clubSel.addEventListener("change", () => applyLegacyFilters());
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  renderLegacyPlayersRules();
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  wireLegacyFilters();
  await loadLegacyList();
});

async function loadLegacyList() {
  const status = document.getElementById("listStatus");
  const tbody = document.getElementById("legacyBody");

  const { data, error } = await supabase.rpc("gpdb_pesdb_unavailable_list");

  if (error) {
    status.textContent = "Could not load legacy players.";
    tbody.innerHTML = "";
    legacyRows = [];
    console.error(error);
    return;
  }

  legacyRows = data || [];
  populateClubFilter();
  applyLegacyFilters();
}
