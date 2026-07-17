import { APP_VERSION } from "./app_version.js";

const {
  initAdminPage,
  primeAdminPageChrome,
  setStatus,
  supabase,
} = await import(`./admin_common.js?v=${APP_VERSION}`);

primeAdminPageChrome();

const GPSL_MONTHS = [
  "august",
  "september",
  "october",
  "november",
  "december",
  "january",
  "february",
  "march",
  "april",
  "may",
];

function selectedSeasonId() {
  return Number(document.getElementById("sportSeasonSelect")?.value) || null;
}

function selectedMonth() {
  return document.getElementById("sportMonthSelect")?.value?.trim().toLowerCase() || "march";
}

function monthLabel(month) {
  if (!month) return "—";
  return month.charAt(0).toUpperCase() + month.slice(1);
}

async function loadSeasons() {
  const sel = document.getElementById("sportSeasonSelect");
  if (!sel) return;

  const { data, error } = await supabase
    .from("competition_seasons")
    .select("id, label, status, is_current")
    .order("id", { ascending: false });

  if (error) {
    setStatus("sportPublishStatus", "❌ " + error.message, false);
    return;
  }

  const rows = data || [];
  sel.innerHTML = rows
    .map((s) => {
      const mark = s.is_current ? " (current)" : "";
      return `<option value="${s.id}">${s.label || `Season ${s.id}`} — ${s.status}${mark}</option>`;
    })
    .join("");

  const current = rows.find((s) => s.is_current) || rows[0];
  if (current) sel.value = String(current.id);
}

async function loadEditions() {
  const seasonId = selectedSeasonId();
  const note = document.getElementById("sportListNote");
  const tbody = document.getElementById("sportEditionBody");
  if (!tbody || !note) return;

  if (!seasonId) {
    note.textContent = "Select a season.";
    tbody.innerHTML = `<tr><td colspan="4" style="color:#888;">No season selected</td></tr>`;
    return;
  }

  note.textContent = "Loading editions…";

  let rows = [];
  const { data: tableData, error: tableErr } = await supabase
    .from("gpsl_sport_editions")
    .select("id, gpsl_month, edition_label, published_at")
    .eq("season_id", seasonId)
    .order("id", { ascending: true });

  if (!tableErr) {
    rows = tableData || [];
  } else {
    const { data: listData, error: listErr } = await supabase.rpc("gpsl_sport_list_editions");
    if (listErr) {
      note.textContent = tableErr.message || listErr.message;
      tbody.innerHTML = `<tr><td colspan="4" class="missing">${tableErr.message || listErr.message}</td></tr>`;
      return;
    }
    rows = Array.isArray(listData?.editions) ? listData.editions : [];
  }

  const byMonth = new Map();
  for (const row of rows) {
    byMonth.set(String(row.gpsl_month || "").toLowerCase(), row);
  }

  tbody.innerHTML = GPSL_MONTHS.map((month) => {
    const row = byMonth.get(month);
    if (!row) {
      return `<tr>
        <td>${monthLabel(month)}</td>
        <td class="missing">Missing</td>
        <td>—</td>
        <td>—</td>
      </tr>`;
    }
    const when = row.published_at
      ? new Date(row.published_at).toLocaleString("en-GB", { timeZone: "Europe/London" })
      : "—";
    return `<tr>
      <td>${monthLabel(month)}</td>
      <td class="ok">${row.edition_label || month}</td>
      <td>${when}</td>
      <td>#${row.id}</td>
    </tr>`;
  }).join("");

  const missing = GPSL_MONTHS.filter((m) => !byMonth.has(m)).length;
  note.textContent =
    missing > 0
      ? `${rows.length} edition(s) found · ${missing} month(s) still missing.`
      : `${rows.length} edition(s) found for this season.`;
}

async function republishSport() {
  const seasonId = selectedSeasonId();
  const month = selectedMonth();

  if (
    !confirm(
      `Republish GPSL Sport for ${monthLabel(month)}?\n\nCreates the edition if missing, or rebuilds it if it already exists.`
    )
  ) {
    return;
  }

  setStatus("sportPublishStatus", `Publishing GPSL Sport (${month})…`);

  const { data, error } = await supabase.rpc("competition_admin_regenerate_gpsl_sport", {
    p_gpsl_month: month,
    p_season_id: seasonId || null,
  });

  if (error) {
    const hint = /competition_admin_regenerate_gpsl_sport/i.test(error.message || "")
      ? " Run gpsl_sport_early_month_publish_fix.sql in Supabase first."
      : "";
    setStatus("sportPublishStatus", "❌ " + error.message + hint, false);
    return;
  }

  if (!data?.ok) {
    setStatus(
      "sportPublishStatus",
      "⚠ " + (data?.reason || data?.error || "Sport edition was not published"),
      false
    );
    return;
  }

  setStatus(
    "sportPublishStatus",
    `✅ Published ${data.edition_label || month} (edition #${data.edition_id})${
      data.created_new ? " — new edition created" : " — rebuilt"
    }. Hard-refresh GPSL Sport.`
  );
  await loadEditions();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("sportPublishBtn").onclick = republishSport;
  document.getElementById("sportRefreshBtn").onclick = loadEditions;
  document.getElementById("sportSeasonSelect").onchange = loadEditions;

  await loadSeasons();
  await loadEditions();
});
