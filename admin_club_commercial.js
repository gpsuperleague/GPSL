import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

const MONEY_FIELDS = {
  ccBigMin: "big_min",
  ccBigMax: "big_max",
  ccMediumMin: "medium_min",
  ccMediumMax: "medium_max",
  ccLowMin: "low_min",
  ccLowMax: "low_max",
};

const PCT_FIELDS = {
  ccLongPct: "long_deal_pct",
  ccPerfBasePct: "perf_deal_base_pct",
  ccMinValuePct: "min_value_pct",
  ccFillWeight: "merch_fill_weight",
  ccShopShare: "shop_share",
};

const TIER_LABELS = { big: "Big", medium: "Medium", low: "Small" };
const DIV_LABELS = {
  superleague: "Superleague",
  championship_a: "Championship A",
  championship_b: "Championship B",
};
const DEAL_LABELS = { long: "Long (2 seasons)", short: "Short (1 season)", performance: "Performance" };

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

async function loadSettings() {
  const { data, error } = await supabase
    .from("club_commercial_settings")
    .select("*")
    .eq("id", 1)
    .maybeSingle();
  if (error || !data) {
    setStatus("ccSettingsStatus", error?.message || "Run club_commercial_income_20261002.sql first.", false);
    return;
  }
  for (const [id, col] of Object.entries(MONEY_FIELDS)) {
    document.getElementById(id).value = Number(data[col] ?? 0);
  }
  for (const [id, col] of Object.entries(PCT_FIELDS)) {
    document.getElementById(id).value = Math.round(Number(data[col] ?? 0) * 100);
  }
  document.getElementById("ccOfferDays").value = Number(data.offer_days ?? 7);
  document.getElementById("ccEnabled").checked = !!data.enabled;
}

async function saveSettings() {
  const patch = { updated_at: new Date().toISOString() };
  for (const [id, col] of Object.entries(MONEY_FIELDS)) {
    const n = Number(document.getElementById(id).value);
    if (!Number.isFinite(n) || n < 0) {
      setStatus("ccSettingsStatus", "Band amounts must be zero or more.", false);
      return;
    }
    patch[col] = n;
  }
  for (const tier of ["big", "medium", "low"]) {
    if (patch[`${tier}_max`] < patch[`${tier}_min`]) {
      setStatus("ccSettingsStatus", `${TIER_LABELS[tier]} max must be at least the min.`, false);
      return;
    }
  }
  for (const [id, col] of Object.entries(PCT_FIELDS)) {
    const n = Number(document.getElementById(id).value);
    if (!Number.isFinite(n) || n < 0 || n > 100) {
      setStatus("ccSettingsStatus", "Percentages must be between 0 and 100.", false);
      return;
    }
    patch[col] = n / 100;
  }
  patch.offer_days = Math.max(1, Math.round(Number(document.getElementById("ccOfferDays").value) || 7));
  patch.enabled = document.getElementById("ccEnabled").checked;

  const { error } = await supabase.from("club_commercial_settings").update(patch).eq("id", 1);
  if (error) {
    setStatus("ccSettingsStatus", error.message, false);
    return;
  }
  setStatus("ccSettingsStatus", "Saved. New values apply to offers, boards and merchandising not yet paid.");
}

async function runSeasonStart() {
  if (!confirm("Run season start for every club? Boards are paid and sponsor offers sent (only once per club per season).")) return;
  setStatus("ccRunStatus", "Running…");
  const { data, error } = await supabase.rpc("admin_club_commercial_run_season_start", { p_season_id: null });
  if (error) {
    setStatus("ccRunStatus", error.message, false);
    return;
  }
  setStatus("ccRunStatus", `Season start done — ${data?.clubs ?? 0} club(s) processed, ${data?.skipped ?? 0} skipped.`);
  await loadOverview();
}

async function runEos() {
  if (!confirm("Post merchandising and performance-deal bonuses now? Close Finances normally does this — only run early if needed.")) return;
  setStatus("ccRunStatus", "Posting…");
  const { data, error } = await supabase.rpc("admin_club_commercial_post_eos", { p_season_id: null });
  if (error) {
    setStatus("ccRunStatus", error.message, false);
    return;
  }
  setStatus(
    "ccRunStatus",
    `End of season posted — merchandising for ${data?.merch_clubs ?? 0} club(s), ${data?.performance_bonuses ?? 0} performance bonus(es).`
  );
  await loadOverview();
}

async function loadOverview() {
  const wrap = document.getElementById("ccOverview");
  setStatus("ccOverviewStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_club_commercial_overview", { p_season_id: null });
  if (error) {
    setStatus("ccOverviewStatus", error.message, false);
    wrap.innerHTML = "";
    return;
  }
  setStatus("ccOverviewStatus", "");

  const { data: season } = await supabase
    .from("competition_seasons")
    .select("label")
    .eq("id", data?.season_id)
    .maybeSingle();
  document.getElementById("ccSeasonLabel").textContent = season?.label || `season ${data?.season_id ?? "—"}`;

  const rows = Array.isArray(data?.rows) ? data.rows : [];
  if (!rows.length) {
    wrap.innerHTML = `<p class="note">No clubs registered for this season.</p>`;
    return;
  }

  let tSponsor = 0;
  let tBoards = 0;
  let tMerch = 0;
  const body = rows
    .map((r) => {
      const sponsorPaid = Number(r.sponsor_paid) || 0;
      const boards = Number(r.boards_total) || 0;
      const merch = Number(r.merch_total) || 0;
      tSponsor += sponsorPaid;
      tBoards += boards;
      tMerch += merch;
      const sponsorCell = r.sponsor
        ? `${esc(r.sponsor)} <span class="comm-auto">${esc(DEAL_LABELS[r.deal_kind] || r.deal_kind)}${
            r.auto_selected ? " · auto" : ""
          }</span>`
        : Number(r.offers_pending) > 0
          ? `<span class="comm-pending">${r.offers_pending} offer(s) pending</span>`
          : "—";
      return `<tr>
        <td>${esc(r.club_name || r.club)}${r.owned ? "" : ` <span class="comm-auto">vacant</span>`}</td>
        <td>${esc(DIV_LABELS[r.division] || r.division)}</td>
        <td>${esc(TIER_LABELS[r.tier] || r.tier)}</td>
        <td>${sponsorCell}</td>
        <td class="num">${formatMoney(sponsorPaid)}</td>
        <td class="num">${formatMoney(boards)}</td>
        <td class="num">${merch ? formatMoney(merch) : "—"}</td>
        <td class="num">${formatMoney(sponsorPaid + boards + merch)}</td>
      </tr>`;
    })
    .join("");

  wrap.innerHTML = `<table class="comm-table">
    <thead><tr>
      <th>Club</th><th>Division</th><th>Tier</th><th>Main sponsor</th>
      <th class="num">Sponsor paid</th><th class="num">Boards</th><th class="num">Merch</th><th class="num">Total</th>
    </tr></thead>
    <tbody>${body}</tbody>
    <tfoot><tr>
      <td colspan="4">Central Bank total</td>
      <td class="num">${formatMoney(tSponsor)}</td>
      <td class="num">${formatMoney(tBoards)}</td>
      <td class="num">${formatMoney(tMerch)}</td>
      <td class="num">${formatMoney(tSponsor + tBoards + tMerch)}</td>
    </tr></tfoot>
  </table>`;
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("ccSaveBtn").onclick = saveSettings;
  document.getElementById("ccRunStartBtn").onclick = runSeasonStart;
  document.getElementById("ccRunEosBtn").onclick = runEos;
  document.getElementById("ccRefreshBtn").onclick = loadOverview;
  await loadSettings();
  await loadOverview();
});
