import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney, DIVISION_LABELS, CUP_LABELS } from "./competition.js";

primeAdminPageChrome();

let filterStatus = "open";
let tariffs = [];

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;
  await loadTariffs();
  document.getElementById("filterOpenBtn").onclick = () => {
    filterStatus = "open";
    loadReports();
  };
  document.getElementById("filterAllBtn").onclick = () => {
    filterStatus = "all";
    loadReports();
  };
  await loadReports();
});

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadTariffs() {
  const { data, error } = await supabase
    .from("competition_fine_tariffs_public")
    .select("code, label, category, amount")
    .eq("direction", "fine")
    .order("sort_order", { ascending: true });
  if (error) {
    console.warn("loadTariffs", error);
    tariffs = [];
    return;
  }
  tariffs = (data || []).filter((t) =>
    ["matchday", "squad", "manager", "other"].includes(t.category)
  );
}

function fixtureLabel(r) {
  const ha = `${r.home_club_short_name} vs ${r.away_club_short_name}`;
  if (r.competition_type === "cup") {
    const cup = CUP_LABELS[r.cup_code] || r.cup_code || "Cup";
    return `${cup} · ${ha}`;
  }
  const div = DIVISION_LABELS[r.division] || r.division || "League";
  return r.matchday != null ? `${div} MD${r.matchday} · ${ha}` : `${div} · ${ha}`;
}

function tariffOptions(selected) {
  return (
    `<option value="">Keep reported tariff</option>` +
    tariffs
      .map(
        (t) =>
          `<option value="${escapeHtml(t.code)}" ${
            t.code === selected ? "selected" : ""
          }>${escapeHtml(t.label)} (${escapeHtml(t.category)})</option>`
      )
      .join("")
  );
}

async function loadReports() {
  const list = document.getElementById("reportsList");
  setStatus("reportsStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_match_video_list_breach_reports", {
    p_status: filterStatus,
    p_limit: 150,
  });
  if (error) {
    setStatus("reportsStatus", error.message, false);
    list.innerHTML = "";
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    list.innerHTML = `<p class="note">No ${filterStatus === "all" ? "" : filterStatus + " "}reports.</p>`;
    setStatus("reportsStatus", "", true);
    return;
  }

  list.innerHTML = rows
    .map((r) => {
      const pill = `<span class="status-pill status-${escapeHtml(r.status)}">${escapeHtml(
        r.status
      )}</span>`;
      const video = r.video_url
        ? `<a href="${escapeHtml(r.video_url)}" target="_blank" rel="noopener noreferrer">Open video</a>`
        : "No URL";
      const openActions =
        r.status === "open"
          ? `
        <label>Uphold with tariff
          <select data-tariff="${r.id}">${tariffOptions(r.breach_tariff_code)}</select>
        </label>
        <label>Staff note
          <textarea data-note="${r.id}" maxlength="500" placeholder="Optional"></textarea>
        </label>
        <div class="mvr-actions">
          <button type="button" class="button" data-uphold="${r.id}">Uphold + fine</button>
          <button type="button" class="button secondary" data-dismiss="${r.id}">Dismiss</button>
        </div>`
          : `<p class="note" style="margin:0">Resolved ${
              r.reviewed_at ? new Date(r.reviewed_at).toLocaleString("en-GB") : ""
            }${r.upheld_tariff_code ? ` · fine ${escapeHtml(r.upheld_tariff_code)}` : ""}${
              r.reward_ledger_id ? " · reporter rewarded ₿2,000" : ""
            }</p>`;

      return `
        <article class="mvr-card" data-id="${r.id}">
          <h3>${escapeHtml(r.breach_label || r.breach_tariff_code)} ${pill}</h3>
          <div class="mvr-meta">
            #${r.id} · ${escapeHtml(fixtureLabel(r))} · ${escapeHtml(r.side)} ·
            accused <b>${escapeHtml(r.accused_club_short_name)}</b> ·
            reporter ${escapeHtml(r.reporter_club_short_name || "—")} ·
            ${new Date(r.created_at).toLocaleString("en-GB")}<br>
            Suggested fine: ${
              r.breach_amount != null ? formatMoney(r.breach_amount) : "—"
            } · ${video}
          </div>
          ${r.note ? `<p class="mvr-note">${escapeHtml(r.note)}</p>` : ""}
          ${openActions}
        </article>`;
    })
    .join("");

  list.querySelectorAll("[data-uphold]").forEach((btn) => {
    btn.onclick = () => resolveReport(Number(btn.getAttribute("data-uphold")), "uphold");
  });
  list.querySelectorAll("[data-dismiss]").forEach((btn) => {
    btn.onclick = () => resolveReport(Number(btn.getAttribute("data-dismiss")), "dismiss");
  });
  setStatus("reportsStatus", `${rows.length} report(s)`, true);
}

async function resolveReport(id, action) {
  const card = document.querySelector(`.mvr-card[data-id="${id}"]`);
  const tariff = card?.querySelector(`[data-tariff="${id}"]`)?.value || null;
  const note = card?.querySelector(`[data-note="${id}"]`)?.value || null;
  setStatus("reportsStatus", `${action === "uphold" ? "Upholding" : "Dismissing"} #${id}…`);
  const { data, error } = await supabase.rpc("admin_match_video_resolve_breach_report", {
    p_report_id: id,
    p_action: action,
    p_tariff_code: action === "uphold" ? tariff || null : null,
    p_review_note: note,
    p_amount_override: null,
  });
  if (error) {
    setStatus("reportsStatus", error.message, false);
    return;
  }
  if (!data?.ok) {
    setStatus("reportsStatus", data?.reason || "Failed", false);
    return;
  }
  setStatus(
    "reportsStatus",
    action === "uphold"
      ? `Upheld #${id}${data.reward_ledger_id ? " · reporter +₿2,000 BS" : ""}`
      : `Dismissed #${id}`,
    true
  );
  await loadReports();
}
