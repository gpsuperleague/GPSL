import { supabase } from "./supabase_client.js";

export async function loadWaitingListPublic() {
  const { data, error } = await supabase.rpc("waiting_list_public");
  if (error) throw error;
  return data;
}

export async function initWaitingListPage() {
  const body = document.getElementById("wlBody");
  const myCard = document.getElementById("wlMyCard");
  const myPos = document.getElementById("wlMyPos");
  const mySummary = document.getElementById("wlMySummary");

  try {
    const { data: self } = await supabase.rpc("owner_registry_get_self");
    const list = await loadWaitingListPublic();
    const rows = list?.rows || [];

    body.innerHTML = "";
    for (const row of rows) {
      const tr = document.createElement("tr");
      if (self?.is_member && row.position === list?.my_position) {
        tr.className = "wl-you";
      }
      const statusExtra =
        row.status === "on_absence"
          ? ' <span class="wl-status-absence">(absence)</span>'
          : "";
      tr.innerHTML =
        `<td>${row.position}</td>` +
        `<td>${escapeHtml(row.owner_tag || "—")}${statusExtra}</td>` +
        `<td></td>`;
      body.appendChild(tr);
    }

    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="3" style="color:#666">No one on the waiting list.</td></tr>';
    }

    if (self?.is_member && list?.my_position) {
      myCard.hidden = false;
      myPos.textContent = `#${list.my_position} of ${list.total || rows.length}`;
      mySummary.textContent =
        list.my_position === 1
          ? "You are next in line when a club slot opens."
          : `${list.my_position - 1} member(s) ahead of you.`;
    }
  } catch (err) {
    console.error(err);
    body.innerHTML =
      '<tr><td colspan="3" style="color:#c66">Could not load waiting list.</td></tr>';
  }
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
