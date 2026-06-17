import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

let overview = [];

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("reloadBtn").onclick = loadOverview;
  document.getElementById("selectAllBtn").onclick = () => toggleAll(true);
  document.getElementById("clearSelBtn").onclick = () => toggleAll(false);
  document.getElementById("drawBtn").onclick = drawSelected;

  await loadOverview();
});

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function loadOverview() {
  setStatus("pageStatus", "Loading…");
  const { data, error } = await supabase.rpc("competition_admin_one_of_our_own_overview");
  if (error) {
    setStatus("pageStatus", "❌ " + error.message + " — run patches/one_of_our_own_draw.sql", false);
    return;
  }
  overview = Array.isArray(data) ? data : [];
  renderRows();
  const pending = overview.filter((c) => !c.already_drawn).length;
  setStatus("pageStatus", `${overview.length} club(s) — ${pending} without a draw yet.`, true);
}

function renderRows() {
  const tbody = document.getElementById("clubRows");
  if (!overview.length) {
    tbody.innerHTML = `<tr><td colspan="5" class="note">No clubs found.</td></tr>`;
    return;
  }

  tbody.innerHTML = overview
    .map((c) => {
      const eligible = Number(c.eligible_count || 0);
      if (c.already_drawn) {
        const player = escapeHtml(c.drawn_player_name || c.drawn_player_id || "—");
        const fee = formatMoney(Number(c.drawn_fee || 0));
        return `<tr class="drawn">
          <td></td>
          <td>${escapeHtml(c.club || c.short_name)}</td>
          <td>${escapeHtml(c.nation || "—")}</td>
          <td>${eligible}</td>
          <td><span class="ooo-badge">${player} · ${fee}</span></td>
        </tr>`;
      }
      const disabled = eligible < 1 ? "disabled" : "";
      const countClass = eligible < 1 ? "ooo-count-0" : "";
      return `<tr>
        <td><input type="checkbox" class="ooo-cb" value="${escapeHtml(c.short_name)}" ${disabled}></td>
        <td>${escapeHtml(c.club || c.short_name)}</td>
        <td>${escapeHtml(c.nation || "—")}</td>
        <td class="${countClass}">${eligible}</td>
        <td><span class="ooo-badge none">Not drawn</span></td>
      </tr>`;
    })
    .join("");
}

function toggleAll(checked) {
  document.querySelectorAll(".ooo-cb").forEach((cb) => {
    if (!cb.disabled) cb.checked = checked;
  });
}

function selectedClubs() {
  return Array.from(document.querySelectorAll(".ooo-cb"))
    .filter((cb) => cb.checked && !cb.disabled)
    .map((cb) => cb.value);
}

async function drawSelected() {
  const clubs = selectedClubs();
  if (!clubs.length) {
    setStatus("pageStatus", "Select at least one club (only clubs with eligible players can be picked).", false);
    return;
  }
  if (
    !confirm(
      `Draw a homegrown star for ${clubs.length} club(s)?\n\n` +
        "Each gets a random free agent (79+, matching nationality), signed as a transfer and charged the market value. This cannot be undone and each club can only ever be drawn once."
    )
  ) {
    return;
  }

  setStatus("pageStatus", "Drawing…");
  document.getElementById("drawBtn").disabled = true;

  const { data, error } = await supabase.rpc("competition_admin_draw_one_of_our_own", {
    p_club_short_names: clubs,
  });

  document.getElementById("drawBtn").disabled = false;

  if (error) {
    setStatus("pageStatus", "❌ " + error.message, false);
    return;
  }

  renderResults(data);
  setStatus("pageStatus", `✅ Drew ${data?.drawn ?? 0} player(s).`, true);
  await loadOverview();
}

function renderResults(data) {
  const root = document.getElementById("drawResults");
  const results = Array.isArray(data?.results) ? data.results : [];
  if (!results.length) {
    root.innerHTML = "";
    return;
  }

  const labelFor = (r) => {
    switch (r.status) {
      case "drawn":
        return `✅ <b>${escapeHtml(r.club)}</b> drew ${escapeHtml(r.player_name || r.player_id)} (${escapeHtml(r.nation || "")}) for ${formatMoney(Number(r.fee || 0))}`;
      case "skipped_already":
        return `↪︎ <b>${escapeHtml(r.club)}</b> already has its One of our Own (skipped)`;
      case "no_eligible_player":
        return `⚠️ <b>${escapeHtml(r.club)}</b> — no eligible free agent (${escapeHtml(r.nation || "")}, 79+)`;
      case "club_not_found":
        return `⚠️ <b>${escapeHtml(r.club)}</b> — club not found`;
      case "error":
        return `❌ <b>${escapeHtml(r.club)}</b> — ${escapeHtml(r.message || "error")}`;
      default:
        return `<b>${escapeHtml(r.club)}</b> — ${escapeHtml(r.status)}`;
    }
  };

  root.innerHTML =
    `<h2 style="font-size:15px;color:#ffaa22;margin:14px 0 6px;">Draw results</h2>` +
    results.map((r) => `<div class="row">${labelFor(r)}</div>`).join("");
}
