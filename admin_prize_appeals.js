import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

let filterStatus = "pending";

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("filterPendingBtn").onclick = () => {
    filterStatus = "pending";
    loadAppeals();
  };
  document.getElementById("filterAllBtn").onclick = () => {
    filterStatus = null;
    loadAppeals();
  };
  await loadAppeals();
});

async function loadAppeals() {
  const list = document.getElementById("appealsList");
  setStatus("appealsStatus", "Loading…");
  const { data, error } = await supabase.rpc("admin_list_suspension_appeals", {
    p_status: filterStatus,
  });
  if (error) {
    list.innerHTML = `<p class="note">❌ ${error.message}</p>`;
    setStatus("appealsStatus", "", false);
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    list.innerHTML = `<p class="note">No ${filterStatus || ""} appeals.</p>`;
    setStatus("appealsStatus", "", true);
    return;
  }

  list.innerHTML = rows
    .map((a) => {
      const pending = a.status === "pending";
      return `
        <div class="challenge-admin-item">
          <div>
            <b>${a.player_name || a.player_id}</b> — ${a.club_short_name}
            <span class="challenge-admin-meta">
              ${a.status} · ${a.pending_matches ?? "?"} matches left · ban ${a.ban_matches}
              · fixture ${a.source_fixture_id ?? "—"}
              ${a.owner_note ? `<br>Owner: ${a.owner_note}` : ""}
              ${a.admin_note ? `<br>Admin: ${a.admin_note}` : ""}
            </span>
          </div>
          ${
            pending
              ? `<div class="challenge-admin-actions">
                  <button type="button" class="button appeal-approve" data-id="${a.id}">Approve</button>
                  <button type="button" class="button appeal-reject" data-id="${a.id}">Reject (DOGSO etc.)</button>
                </div>`
              : ""
          }
        </div>`;
    })
    .join("");

  list.querySelectorAll(".appeal-approve").forEach((btn) => {
    btn.onclick = () => review(Number(btn.dataset.id), true);
  });
  list.querySelectorAll(".appeal-reject").forEach((btn) => {
    btn.onclick = () => review(Number(btn.dataset.id), false);
  });
  setStatus("appealsStatus", `${rows.length} appeal(s)`, true);
}

async function review(id, approve) {
  const note = prompt(
    approve
      ? "Optional admin note for the club:"
      : "Reason for rejection (e.g. DOGSO / clear goal-scoring opportunity):"
  );
  if (note === null) return;
  setStatus("appealsStatus", "Saving…");
  const { error } = await supabase.rpc("admin_review_suspension_appeal", {
    p_appeal_id: id,
    p_approve: approve,
    p_admin_note: note || null,
  });
  if (error) {
    setStatus("appealsStatus", "❌ " + error.message, false);
    return;
  }
  await loadAppeals();
}
