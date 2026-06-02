import { supabase, initGlobal } from "./global.js";
import { loadClubsMap, fullClubName } from "./clubs_lookup.js";
import {
  formatMoney,
  GATE_ENTRY_LABELS,
  loadClubBalance,
  loadFinanceLedger,
  loadClubSeasonArchive,
} from "./competition.js";

function entryLabel(type) {
  return GATE_ENTRY_LABELS[type] || type;
}

function renderLedger(rows) {
  const el = document.getElementById("ledgerTable");
  if (!el) return;

  if (!rows.length) {
    el.innerHTML =
      '<p class="empty">No gate receipts yet. League gates post when home results are confirmed. Run <code>competition_phase5_finances.sql</code> and use admin backfill for older games.</p>';
    return;
  }

  const body = rows
    .map((r) => {
      const md = r.matchday ? `MD${r.matchday}` : "—";
      const fixture =
        r.home_club_short_name && r.away_club_short_name
          ? `${r.home_club_short_name} vs ${r.away_club_short_name}`
          : "—";
      return `
        <tr>
          <td>${new Date(r.created_at).toLocaleString("en-GB")}</td>
          <td>${entryLabel(r.entry_type)}</td>
          <td>${md}</td>
          <td>${fixture}</td>
          <td class="money">${formatMoney(r.amount)}</td>
          <td>${r.description || ""}</td>
        </tr>
      `;
    })
    .join("");

  el.innerHTML = `
    <table class="fin-table">
      <thead>
        <tr>
          <th>When</th>
          <th>Type</th>
          <th>MD</th>
          <th>Fixture</th>
          <th>Amount</th>
          <th>Detail</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>
  `;
}

function renderArchive(rows) {
  const el = document.getElementById("archiveList");
  if (!el) return;

  if (!rows.length) {
    el.innerHTML =
      '<p class="empty">No archived seasons — gate history uses a neutral mid-table boost until rows are added (admin RPC or season end).</p>';
    return;
  }

  el.innerHTML = `
    <ul class="archive-ul">
      ${rows
        .map(
          (r) =>
            `<li><b>${r.season_label}</b> — ${r.division}, finished <b>${r.final_position}</b></li>`
        )
        .join("")}
    </ul>
  `;
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }

  document.getElementById("userEmail").textContent = user.email;

  const { data: club } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .eq("owner_id", user.id)
    .maybeSingle();

  if (!club?.ShortName) {
    document.getElementById("pageMeta").textContent =
      "No club linked — assign owner in GPSL Admin.";
    return;
  }

  await loadClubsMap();
  const shortName = club.ShortName;
  const fullName = fullClubName(shortName) || club.Club;

  document.getElementById("pageTitle").textContent = `${fullName} — Finances`;
  document.getElementById("clubBadgeHeader").src =
    `images/club_badges/${shortName}.png`;

  const balanceRow = await loadClubBalance(supabase, shortName);
  document.getElementById("balanceAmount").textContent = formatMoney(
    balanceRow?.balance ?? 0
  );

  const ledger = await loadFinanceLedger(supabase, shortName);
  const gateTotal = ledger
    .filter((r) => r.entry_type?.startsWith("gate_"))
    .reduce((s, r) => s + Number(r.amount || 0), 0);
  document.getElementById("gateSeasonTotal").textContent = formatMoney(gateTotal);

  renderLedger(ledger);
  renderArchive(await loadClubSeasonArchive(supabase, shortName));
});
