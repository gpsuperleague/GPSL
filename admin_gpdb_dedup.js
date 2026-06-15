import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

const CONFIRM_TEXT = "DEDUP PLAYERS";

function renderSummary(result) {
  const grid = document.getElementById("previewGrid");
  if (!grid || !result) return;

  grid.hidden = false;
  grid.innerHTML = `
    <div><span>${result.duplicate_groups ?? 0}</span> duplicate groups</div>
    <div><span>${result.players_to_remove ?? 0}</span> rows to remove</div>
    <div><span>${result.blocked_groups ?? 0}</span> blocked groups</div>
    <div><span>${result.refs_to_remap ?? 0}</span> drops with references</div>
    <div><span>${result.deleted ?? 0}</span> deleted (apply only)</div>
  `;
}

function renderAuditTable(rows) {
  const wrap = document.getElementById("previewTableWrap");
  const tbody = document.getElementById("previewBody");
  if (!wrap || !tbody) return;

  if (!rows?.length) {
    wrap.hidden = true;
    tbody.innerHTML = "";
    return;
  }

  wrap.hidden = false;
  const show = rows.slice(0, 200);
  tbody.innerHTML = show
    .map((r) => {
      const blocked = r.blocked_reason
        ? `<span class="tag-blocked">${r.blocked_reason}</span>`
        : r.drop_in_use
          ? `<span class="tag-warn">remap refs</span>`
          : `<span class="tag-ok">ok</span>`;
      const refs = r.drop_refs && Object.keys(r.drop_refs).length
        ? Object.entries(r.drop_refs)
            .map(([k, v]) => `${k}:${v}`)
            .join(", ")
        : "—";
      return `
        <tr>
          <td>${r.dup_key}<br><small>${r.group_size} cards</small></td>
          <td>
            <b>${escapeHtml(r.keep_name || "")}</b><br>
            ${r.keep_konami_id} · OVR ${r.keep_rating ?? "—"}
            ${r.keep_club ? `<br><small>${escapeHtml(r.keep_club)}</small>` : ""}
          </td>
          <td>
            ${escapeHtml(r.drop_name || "")}<br>
            ${r.drop_konami_id} · OVR ${r.drop_rating ?? "—"}
            ${r.drop_club ? `<br><small>${escapeHtml(r.drop_club)}</small>` : ""}
          </td>
          <td><small>${escapeHtml(refs)}</small></td>
          <td>${blocked}</td>
        </tr>`;
    })
    .join("");

  if (rows.length > show.length) {
    tbody.innerHTML += `<tr><td colspan="5" style="color:#888;padding:12px;">Showing first ${show.length} of ${rows.length} rows.</td></tr>`;
  }
}

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

async function loadAuditRows() {
  const { data, error } = await supabase.rpc("gpdb_player_duplicate_audit");
  if (error) throw error;
  return data || [];
}

async function runPreview() {
  setStatus("previewStatus", "Loading…", true);
  try {
    const [auditRows, { data: result, error }] = await Promise.all([
      loadAuditRows(),
      supabase.rpc("gpdb_player_deduplicate", { p_dry_run: true }),
    ]);
    if (error) throw error;
    renderSummary(result);
    renderAuditTable(auditRows);
    setStatus(
      "previewStatus",
      result?.players_to_remove
        ? `Preview ready — ${result.players_to_remove} duplicate row(s) would be removed.`
        : "No duplicate groups found (Name + Nation).",
      true
    );
  } catch (err) {
    console.error("gpdb dedup preview:", err);
    setStatus(
      "previewStatus",
      err.message || "Preview failed. Run patches/gpdb_player_deduplication.sql in Supabase.",
      false
    );
  }
}

async function runApply() {
  const confirm = document.getElementById("confirmInput")?.value?.trim();
  if (confirm !== CONFIRM_TEXT) {
    setStatus("applyStatus", `Type ${CONFIRM_TEXT} exactly to confirm.`, false);
    return;
  }

  if (
    !window.confirm(
      "Remove all duplicate GPDB player rows? References will be remapped to the kept card. This cannot be undone easily."
    )
  ) {
    return;
  }

  setStatus("applyStatus", "Applying…", true);
  try {
    const { data: result, error } = await supabase.rpc("gpdb_player_deduplicate", {
      p_dry_run: false,
    });
    if (error) throw error;

    const auditRows = await loadAuditRows();
    renderSummary(result);
    renderAuditTable(auditRows);

    setStatus(
      "applyStatus",
      `Done — removed ${result?.deleted ?? 0} duplicate row(s). ${result?.blocked_groups ?? 0} group(s) skipped (multiple clubs).`,
      true
    );
    document.getElementById("confirmInput").value = "";
  } catch (err) {
    console.error("gpdb dedup apply:", err);
    setStatus("applyStatus", err.message || "Apply failed.", false);
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  const user = await initAdminPage();
  if (!user) return;

  document.getElementById("previewBtn")?.addEventListener("click", runPreview);
  document.getElementById("applyBtn")?.addEventListener("click", runApply);
});
