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

function rowSearchHaystack(r) {
  const club = displayClubName(r.club) || r.club || "Free agent";
  return [r.player_name, club, r.konami_id, r.position, r.nation]
    .filter((x) => x != null && String(x).trim() !== "")
    .join(" ");
}

function filteredLegacyRows(query) {
  const q = String(query ?? "").trim();
  if (!q) return legacyRows;
  return legacyRows.filter((r) => textMatchesSearch(rowSearchHaystack(r), q));
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
  const q = document.getElementById("legacyPlayerSearch")?.value?.trim();
  if (q) {
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
      ? "No legacy players match this search."
      : "No legacy cards listed.";
    tbody.innerHTML = `<tr><td colspan="7" class="empty-note">${emptyMsg}</td></tr>`;
    updateStatus(0);
    return;
  }

  tbody.innerHTML = rows
    .map((r) => {
      const club = displayClubName(r.club) || r.club || "Free agent";
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

function applyLegacySearch() {
  const q = document.getElementById("legacyPlayerSearch")?.value ?? "";
  renderLegacyTable(filteredLegacyRows(q));
}

function wireLegacySearch() {
  const input = document.getElementById("legacyPlayerSearch");
  if (!input || input.dataset.wired === "1") return;
  input.dataset.wired = "1";
  input.addEventListener("input", () => applyLegacySearch());
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

  wireLegacySearch();
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
  applyLegacySearch();
}
