import { supabase, initGlobal } from "./global.js";
import { loadCurrentGpslSeasonLabel } from "./player_season_transfer.js";
import {
  loadClubsMap,
  displayClubName,
  clubPageHref,
} from "./clubs_lookup.js";

let allRows = [];

function formatMoney(amount) {
  if (amount == null || Number.isNaN(Number(amount))) return "—";
  return `₿ ${Number(amount).toLocaleString("en-GB")}`;
}

function formatWhen(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleString("en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clubCell(shortName, clubName) {
  const label = clubName || displayClubName(shortName);
  const href = clubPageHref(shortName);
  const sub = shortName && label !== shortName
    ? `<br><span style="font-size:11px;color:#888;">${escapeHtml(shortName)}</span>`
    : "";
  const nameHtml = href
    ? `<a class="gpsl-link" href="${href}">${escapeHtml(label)}</a>`
    : escapeHtml(label);
  return `${nameHtml}${sub}`;
}

function renderSummary() {
  const bar = document.getElementById("summaryBar");
  if (!bar) return;

  if (!allRows.length) {
    bar.hidden = true;
    return;
  }

  const totalFees = allRows.reduce(
    (sum, row) => sum + Number(row.winning_bid || 0),
    0
  );

  bar.hidden = false;
  bar.innerHTML = `
    <span><strong>${allRows.length}</strong> club${allRows.length === 1 ? "" : "s"} purchased</span>
    <span>Total auction spend: <strong>${formatMoney(totalFees)}</strong></span>
  `;
}

function renderTable() {
  const host = document.getElementById("tableHost");

  if (!allRows.length) {
    host.innerHTML =
      "<p class=\"empty\">No club auction purchases recorded yet.</p>";
    renderSummary();
    return;
  }

  const totalFees = allRows.reduce(
    (sum, row) => sum + Number(row.winning_bid || 0),
    0
  );

  const body = allRows
    .map((row) => {
      const tag = String(row.owner_tag || "").trim() || "—";
      return `
        <tr>
          <td class="rank-cell">${row.prestige_rank ?? "—"}</td>
          <td>${clubCell(row.club_short_name, row.club_name)}</td>
          <td>${escapeHtml(row.nation || "—")}</td>
          <td><span class="owner-tag">${escapeHtml(tag)}</span></td>
          <td>${formatMoney(row.opening_bid)}</td>
          <td>${formatMoney(row.winning_bid)}</td>
          <td>${formatWhen(row.settled_at)}</td>
        </tr>
      `;
    })
    .join("");

  host.innerHTML = `
    <table class="gpsl-table">
      <thead>
        <tr>
          <th>Rank</th>
          <th>Club</th>
          <th>Nation</th>
          <th>Owner</th>
          <th>Opening bid</th>
          <th>Winning bid</th>
          <th>Settled</th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
      <tfoot>
        <tr>
          <td colspan="5">Total</td>
          <td>${formatMoney(totalFees)}</td>
          <td></td>
        </tr>
      </tfoot>
    </table>
  `;

  renderSummary();
}

async function loadSeasonStart() {
  const { data, error } = await supabase
    .from("competition_season_public")
    .select("label, started_at")
    .eq("is_current", true)
    .maybeSingle();

  if (error) {
    console.error("competition_season_public:", error);
    return {
      label: (await loadCurrentGpslSeasonLabel(supabase)) || "Current season",
      startedAt: null,
    };
  }

  return {
    label:
      data?.label ||
      (await loadCurrentGpslSeasonLabel(supabase)) ||
      "Current season",
    startedAt: data?.started_at || null,
  };
}

async function loadPurchases() {
  const { data, error } = await supabase
    .from("club_auction_purchases_public")
    .select(
      "club_short_name, club_name, nation, prestige_rank, opening_bid, winning_bid, owner_tag, settled_at"
    )
    .order("prestige_rank", { ascending: true, nullsFirst: false })
    .order("club_short_name", { ascending: true })
    .limit(200);

  if (error) throw error;
  return data || [];
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

  await loadClubsMap();

  try {
    const { label } = await loadSeasonStart();
    const labelEl = document.getElementById("seasonLabel");
    if (labelEl) {
      labelEl.textContent = ` — ${label} club auction results`;
    }

    allRows = await loadPurchases();
    renderTable();
  } catch (err) {
    console.error(err);
    const msg = String(err.message || "error");
    const hint = /club_auction_purchases_public/i.test(msg)
      ? " Run supabase/sql/patches/club_auction_purchases_public.sql in Supabase."
      : "";
    document.getElementById("tableHost").innerHTML =
      `<p class="empty">Could not load club purchases: ${escapeHtml(msg)}${escapeHtml(hint)}</p>`;
  }
});
