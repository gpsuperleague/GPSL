import { initGlobal, supabase } from "./global.js";
import { loadClubsMap, displayClubName } from "./clubs_lookup.js";
import { contractYearsLabel } from "./player_contracts.js";

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

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  await loadClubsMap();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  await loadLegacyList();
});

async function loadLegacyList() {
  const status = document.getElementById("listStatus");
  const tbody = document.getElementById("legacyBody");

  const { data, error } = await supabase.rpc("gpdb_pesdb_unavailable_list");

  if (error) {
    status.textContent = "Could not load legacy players.";
    tbody.innerHTML = "";
    console.error(error);
    return;
  }

  const rows = data || [];
  status.textContent =
    rows.length === 0
      ? "No legacy players at the moment — all GPDB cards match the latest PESDB scrape."
      : `${rows.length} legacy player${rows.length === 1 ? "" : "s"} across GPSL clubs.`;

  if (!rows.length) {
    tbody.innerHTML =
      '<tr><td colspan="6" class="empty-note">No legacy cards listed.</td></tr>';
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
      <td>${escapeHtml(r.player_name)}</td>
      <td class="num">${escapeHtml(r.position || "—")}</td>
      <td class="num">${escapeHtml(r.rating || "—")}</td>
      <td>${escapeHtml(club)}</td>
      <td><span class="tag-legacy">${escapeHtml(contractNote)}</span></td>
      <td class="num">${escapeHtml(formatLegacySince(r.unavailable_since))}</td>
    </tr>`;
    })
    .join("");
}
