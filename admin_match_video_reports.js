import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { DIVISION_LABELS, CUP_LABELS } from "./competition.js";

primeAdminPageChrome();

let filterStatus = "open";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;
  document.getElementById("filterOpenBtn").onclick = () => {
    filterStatus = "open";
    loadReports();
  };
  document.getElementById("filterApprovedBtn").onclick = () => {
    filterStatus = "approved";
    loadReports();
  };
  document.getElementById("filterRejectedBtn").onclick = () => {
    filterStatus = "rejected";
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

function fixtureLabel(r) {
  const ha = `${r.home_club_short_name} vs ${r.away_club_short_name}`;
  if (r.competition_type === "cup") {
    const cup = CUP_LABELS[r.cup_code] || r.cup_code || "Cup";
    return `${cup} · ${ha}`;
  }
  const div = DIVISION_LABELS[r.division] || r.division || "League";
  return r.matchday != null ? `${div} MD${r.matchday} · ${ha}` : `${div} · ${ha}`;
}

function breachesHtml(r) {
  const list = Array.isArray(r.breaches) ? r.breaches : [];
  if (!list.length) {
    return r.note
      ? `<div class="mvr-breach"><b>${escapeHtml(r.breach_tariff_code || "Breach")}</b><br>${escapeHtml(
          r.note
        )}</div>`
      : `<p class="note">No breach details.</p>`;
  }
  return list
    .map(
      (b) => `
      <div class="mvr-breach">
        <b>${escapeHtml(b.label || b.code)}</b>
        <div class="mvr-note">${escapeHtml(b.note || "—")}</div>
      </div>`
    )
    .join("");
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
    list.innerHTML = `<p class="note">No ${
      filterStatus === "all" ? "" : filterStatus + " "
    }reports.</p>`;
    setStatus("reportsStatus", "", true);
    return;
  }

  list.innerHTML = rows
    .map((r) => {
      const status = r.status || "open";
      const pill = `<span class="status-pill status-${escapeHtml(status)}">${escapeHtml(
        status
      )}</span>`;
      const video = r.video_url
        ? `<a href="${escapeHtml(r.video_url)}" target="_blank" rel="noopener noreferrer">Open video</a>`
        : "No URL";
      const count = r.breach_count ?? (Array.isArray(r.breaches) ? r.breaches.length : 0);
      const openActions =
        status === "open"
          ? `
        <label>Staff note (optional)
          <textarea data-note="${r.id}" maxlength="500" placeholder="Optional review note"></textarea>
        </label>
        <div class="mvr-actions">
          <button type="button" class="button" data-approve="${r.id}">OK / Approve</button>
          <button type="button" class="button secondary" data-reject="${r.id}">Reject</button>
        </div>
        <p class="note" style="margin:8px 0 0">
          Approve applies a fine for each listed breach and credits the reporter ₿2,000 Building Society.
          Reject closes this match side forever (no re-report).
        </p>`
          : `<p class="note" style="margin:0">Resolved ${
              r.reviewed_at ? new Date(r.reviewed_at).toLocaleString("en-GB") : ""
            }${r.reward_ledger_id ? " · reporter rewarded ₿2,000" : ""}${
              r.review_note ? ` · ${escapeHtml(r.review_note)}` : ""
            }</p>`;

      return `
        <article class="mvr-card" data-id="${r.id}">
          <h3>${count} breach${count === 1 ? "" : "es"} ${pill}</h3>
          <div class="mvr-meta">
            #${r.id} · ${escapeHtml(fixtureLabel(r))} · ${escapeHtml(r.side)} ·
            accused <b>${escapeHtml(r.accused_club_short_name)}</b> ·
            reporter ${escapeHtml(r.reporter_club_short_name || "—")} ·
            ${new Date(r.created_at).toLocaleString("en-GB")}<br>
            ${video}
          </div>
          <div class="mvr-breaches">${breachesHtml(r)}</div>
          ${openActions}
        </article>`;
    })
    .join("");

  list.querySelectorAll("[data-approve]").forEach((btn) => {
    btn.onclick = () => resolveReport(Number(btn.getAttribute("data-approve")), "approve");
  });
  list.querySelectorAll("[data-reject]").forEach((btn) => {
    btn.onclick = () => resolveReport(Number(btn.getAttribute("data-reject")), "reject");
  });
  setStatus("reportsStatus", `${rows.length} report(s)`, true);
}

async function resolveReport(id, action) {
  const card = document.querySelector(`.mvr-card[data-id="${id}"]`);
  const note = card?.querySelector(`[data-note="${id}"]`)?.value || null;
  if (
    action === "reject" &&
    !confirm("Reject this report? This match side can never be reported again.")
  ) {
    return;
  }
  if (
    action === "approve" &&
    !confirm(
      "Approve this report? Fines will be applied for each breach and the reporter gets ₿2,000 Building Society."
    )
  ) {
    return;
  }
  setStatus(
    "reportsStatus",
    `${action === "approve" ? "Approving" : "Rejecting"} #${id}…`
  );
  const { data, error } = await supabase.rpc("admin_match_video_resolve_breach_report", {
    p_report_id: id,
    p_action: action,
    p_tariff_code: null,
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
    action === "approve"
      ? `Approved #${id}${data.reward_ledger_id ? " · reporter +₿2,000 BS" : ""}`
      : `Rejected #${id}`,
    true
  );
  await loadReports();
}
