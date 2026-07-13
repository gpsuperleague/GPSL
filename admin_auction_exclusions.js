import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function formatMoney(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `₿ ${v.toLocaleString("en-GB")}`;
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("searchBtn")?.addEventListener("click", runSearch);
  document.getElementById("reloadBtn")?.addEventListener("click", loadReserved);
  document.getElementById("searchQuery")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") runSearch();
  });
  await loadReserved();
});

async function loadReserved() {
  const { data, error } = await supabase.rpc("admin_auction_exclusion_list");
  const body = document.getElementById("reservedBody");
  if (error) {
    setStatus("listStatus", error.message + " — run auction_exclusions.sql", false);
    if (body) body.innerHTML = `<tr><td colspan="6" class="muted">Unavailable</td></tr>`;
    return;
  }
  setStatus("listStatus", `${(data || []).length} reserved.`, true);
  if (!body) return;
  if (!data?.length) {
    body.innerHTML = `<tr><td colspan="6" class="muted">No reserved players.</td></tr>`;
    return;
  }
  body.innerHTML = data
    .map(
      (r) => `
    <tr>
      <td>
        <b>${escapeHtml(r.player_name || r.player_id)}</b><br>
        <small class="muted">${escapeHtml(r.player_id)}</small>
      </td>
      <td>${escapeHtml(r.position || "—")}</td>
      <td>${escapeHtml(r.rating ?? "—")}</td>
      <td>${formatMoney(r.market_value)}</td>
      <td>${r.reserved_at ? new Date(r.reserved_at).toLocaleString("en-GB") : "—"}</td>
      <td><button type="button" class="button secondary" data-unlock="${escapeHtml(r.player_id)}">Unlock</button></td>
    </tr>`
    )
    .join("");

  body.querySelectorAll("[data-unlock]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.getAttribute("data-unlock");
      const { error: err } = await supabase.rpc("admin_auction_unexclude_player", {
        p_player_id: id,
      });
      setStatus("listStatus", err ? err.message : `Unlocked ${id}`, !err);
      await loadReserved();
    });
  });
}

async function runSearch() {
  const q = document.getElementById("searchQuery")?.value?.trim() || "";
  setStatus("searchStatus", "Searching…");
  const { data, error } = await supabase.rpc("admin_auction_search_players_for_exclusion", {
    p_query: q,
    p_limit: 25,
  });
  const wrap = document.getElementById("searchResults");
  if (error) {
    setStatus("searchStatus", error.message, false);
    if (wrap) wrap.innerHTML = "";
    return;
  }
  setStatus("searchStatus", `${(data || []).length} result(s).`, true);
  if (!wrap) return;
  if (!data?.length) {
    wrap.innerHTML = `<p class="muted">No free agents matched.</p>`;
    return;
  }
  wrap.innerHTML = `
    <table class="gpsl-table">
      <thead><tr><th>Player</th><th>Pos</th><th>OVR</th><th>MV</th><th></th></tr></thead>
      <tbody>
        ${data
          .map(
            (r) => `
          <tr>
            <td>
              <b>${escapeHtml(r.player_name)}</b><br>
              <small class="muted">${escapeHtml(r.player_id)}</small>
            </td>
            <td>${escapeHtml(r.position || "—")}</td>
            <td>${escapeHtml(r.rating ?? "—")}</td>
            <td>${formatMoney(r.market_value)}</td>
            <td>
              ${
                r.already_excluded
                  ? `<span class="muted">Reserved</span>`
                  : `<button type="button" class="button" data-reserve="${escapeHtml(r.player_id)}">Reserve</button>`
              }
            </td>
          </tr>`
          )
          .join("")}
      </tbody>
    </table>`;

  wrap.querySelectorAll("[data-reserve]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.getAttribute("data-reserve");
      const { error: err } = await supabase.rpc("admin_auction_exclude_player", {
        p_player_id: id,
      });
      setStatus("searchStatus", err ? err.message : `Reserved ${id}`, !err);
      await loadReserved();
      await runSearch();
    });
  });
}
