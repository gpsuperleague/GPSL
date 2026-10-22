import { supabase, initGlobal } from "./global.js";
import { GPSL_MONTH_LABELS, GPSL_MONTH_ORDER, loadCurrentSeason } from "./competition.js";
import {
  loadOwnerSupporterMap,
  ownerTagHtml,
} from "./owner_badge.js";

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function monthLabel(month) {
  const key = String(month || "").toLowerCase();
  return GPSL_MONTH_LABELS[key] || key || "—";
}

function monthSortKey(month) {
  const i = GPSL_MONTH_ORDER.indexOf(String(month || "").toLowerCase());
  return i < 0 ? 99 : i;
}

function recordLine(a) {
  const gd = (a.gf ?? 0) - (a.ga ?? 0);
  const gdLabel = gd > 0 ? `+${gd}` : String(gd);
  return `${a.won ?? 0}–${a.drawn ?? 0}–${a.lost ?? 0} · ${a.pts ?? 0} pts · GD ${gdLabel} (${a.gf ?? 0}–${a.ga ?? 0})`;
}

function renderAwardCard(el, award, emptyMsg) {
  if (!el) return;
  const isChamp = el.classList.contains("champ");
  const heading = isChamp ? "Championship" : "Super League";
  if (!award) {
    el.innerHTML = `<h3>${heading}</h3><p class="ootm-empty">${escapeHtml(emptyMsg)}</p>`;
    return;
  }
  const tag = ownerTagHtml({
    ownerId: award.owner_id,
    ownerTag: award.owner_tag || "—",
    link: !!award.owner_id,
    compact: true,
    showBadgeImage: true,
  });
  el.innerHTML = `
    <h3>${heading}</h3>
    <div class="ootm-tag">${tag}</div>
    <p class="ootm-club">${escapeHtml(award.club_name || award.club_short_name || "—")}</p>
    <p class="ootm-record">${escapeHtml(recordLine(award))}</p>
  `;
}

let allAwards = [];
let selectedMonth = null;

function monthsFromAwards(rows) {
  const set = new Set();
  for (const r of rows || []) {
    if (r.gpsl_month) set.add(String(r.gpsl_month).toLowerCase());
  }
  return [...set].sort((a, b) => monthSortKey(b) - monthSortKey(a));
}

function renderMonthTabs(months) {
  const root = document.getElementById("ootmMonthTabs");
  if (!root) return;
  if (!months.length) {
    root.innerHTML = "";
    return;
  }
  if (!selectedMonth || !months.includes(selectedMonth)) {
    selectedMonth = months[0];
  }
  root.innerHTML = months
    .map(
      (m) =>
        `<button type="button" class="month-tab${m === selectedMonth ? " active" : ""}" data-month="${escapeHtml(m)}">${escapeHtml(monthLabel(m))}</button>`
    )
    .join("");
  root.querySelectorAll(".month-tab").forEach((btn) => {
    btn.onclick = () => {
      selectedMonth = btn.dataset.month;
      renderLatest();
      renderMonthTabs(months);
    };
  });
}

function renderLatest() {
  const month = selectedMonth;
  const forMonth = (allAwards || []).filter(
    (a) => String(a.gpsl_month || "").toLowerCase() === month
  );
  const sl = forMonth.find((a) => a.division_scope === "superleague") || null;
  const ch = forMonth.find((a) => a.division_scope === "championship") || null;
  const empty = month
    ? `No award for ${monthLabel(month)} yet — set when that GPSL month locks.`
    : "No awards yet.";
  renderAwardCard(document.getElementById("ootmSuperCard"), sl, empty);
  renderAwardCard(document.getElementById("ootmChampCard"), ch, empty);
}

function renderHistory() {
  const root = document.getElementById("ootmHistory");
  if (!root) return;
  if (!allAwards.length) {
    root.innerHTML =
      '<p class="ootm-empty">No Owner of the Month awards yet. Run owner_of_the_month_20261022.sql — awarded on End GPSL Month with Manager of the Month.</p>';
    return;
  }
  const rows = [...allAwards].sort((a, b) => {
    if (a.season_id !== b.season_id) return (b.season_id || 0) - (a.season_id || 0);
    const md = monthSortKey(b.gpsl_month) - monthSortKey(a.gpsl_month);
    if (md) return md;
    return String(a.division_scope).localeCompare(String(b.division_scope));
  });
  root.innerHTML = `
    <table class="history-table">
      <thead>
        <tr>
          <th>Month</th>
          <th>Division</th>
          <th>Owner</th>
          <th>Club</th>
          <th>Record</th>
        </tr>
      </thead>
      <tbody>
        ${rows
          .map((a) => {
            const scopeCls =
              a.division_scope === "championship" ? "scope-ch" : "scope-sl";
            const scopeLabel =
              a.division_scope === "championship" ? "Championship" : "Super League";
            const tag = ownerTagHtml({
              ownerId: a.owner_id,
              ownerTag: a.owner_tag || "—",
              link: !!a.owner_id,
              compact: true,
              showBadgeImage: false,
            });
            return `<tr>
              <td>${escapeHtml(monthLabel(a.gpsl_month))} <span style="color:#666">${escapeHtml(a.season_label || "")}</span></td>
              <td class="${scopeCls}">${scopeLabel}</td>
              <td>${tag}</td>
              <td>${escapeHtml(a.club_name || a.club_short_name || "—")}</td>
              <td>${escapeHtml(recordLine(a))}</td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>
  `;
}

async function loadAwards(seasonId) {
  let q = supabase
    .from("competition_owner_month_awards_public")
    .select("*")
    .order("season_id", { ascending: false });
  if (seasonId) q = q.eq("season_id", seasonId);
  const { data, error } = await q;
  if (error) {
    console.warn("owner of the month:", error);
    allAwards = [];
    return;
  }
  allAwards = data || [];
}

export async function initOwnerOfTheMonthPage() {
  window.CURRENT_PAGE = "owner_of_the_month";
  await initGlobal();
  await loadOwnerSupporterMap().catch(() => {});

  const season = await loadCurrentSeason(supabase);
  await loadAwards(season?.id || null);

  const months = monthsFromAwards(allAwards);
  renderMonthTabs(months);
  renderLatest();
  renderHistory();
}

initOwnerOfTheMonthPage().catch((err) => {
  console.error(err);
  const hist = document.getElementById("ootmHistory");
  if (hist) {
    hist.innerHTML = `<p class="ootm-empty" style="color:#c66">Could not load awards. Apply supabase/sql/patches/owner_of_the_month_20261022.sql in Supabase.</p>`;
  }
});
