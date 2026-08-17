import { supabase, initGlobal } from "./global.js";
import { formatMoney, GPSL_MONTH_LABELS } from "./competition.js";

let state = {
  isAdmin: false,
  payload: null,
  posGroup: "fwd",
  pool: [],
};

function setStatus(msg, ok = true) {
  const el = document.getElementById("gpflStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("err", !ok);
}

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function money(n) {
  return formatMoney(n ?? 0);
}

async function resolveAdmin() {
  try {
    const { data, error } = await supabase.rpc("is_gpsl_admin");
    if (!error) return Boolean(data);
  } catch (_) {
    /* ignore */
  }
  return false;
}

async function loadEntry() {
  const { data, error } = await supabase.rpc("gpfl_my_entry");
  if (error) {
    setStatus(
      error.message.includes("gpfl_")
        ? "Run supabase/sql/patches/gpfl_fantasy_league_20260817.sql first."
        : error.message,
      false
    );
    return null;
  }
  state.payload = data;
  return data;
}

function renderGate(data) {
  const gate = document.getElementById("gpflGate");
  const play = document.getElementById("gpflPlay");
  if (!data?.enabled) {
    gate.hidden = false;
    play.hidden = true;
    document.getElementById("gpflGateMsg").textContent =
      "GPFL is currently disabled by admin.";
    document.getElementById("gpflJoinBtn").disabled = true;
    return;
  }
  if (!data.gpfl_season_id) {
    gate.hidden = false;
    play.hidden = true;
    document.getElementById("gpflGateMsg").textContent = state.isAdmin
      ? "No GPFL season yet — use Admin → Open / refresh GPFL season."
      : "No GPFL season open yet. Check back when admin opens it. Playing is optional.";
    document.getElementById("gpflJoinBtn").disabled = true;
    return;
  }
  if (!data.joined) {
    gate.hidden = false;
    play.hidden = true;
    document.getElementById("gpflGateMsg").textContent =
      "Optional side-game. Join only if you want a fantasy squad this season.";
    document.getElementById("gpflJoinBtn").disabled = false;
    return;
  }
  gate.hidden = true;
  play.hidden = false;
}

function renderEntryStats(data) {
  const e = data.entry || {};
  const s = data.settings || {};
  const el = document.getElementById("gpflEntryStats");
  if (!el) return;
  const needs = (data.squad || []).filter((p) => p.slot_status === "needs_replace").length;
  el.innerHTML = `
    <div class="gpfl-stat">Status <b>${esc(e.status)}</b></div>
    <div class="gpfl-stat">GPFL budget <b>${money(e.budget_remaining)}</b> / ${money(s.budget ?? data.season?.budget_snapshot)}</div>
    <div class="gpfl-stat">Points <b>${esc(e.total_points ?? 0)}</b></div>
    <div class="gpfl-stat">Free transfers <b>${esc(e.free_transfers_remaining ?? 0)}</b></div>
    <div class="gpfl-stat">Squad <b>${(data.squad || []).filter((p) => p.slot_status === "active").length}/${esc(s.squad_size ?? 15)}</b></div>
    ${needs ? `<div class="gpfl-stat">FA to replace <b>${needs}</b></div>` : ""}
  `;
}

function renderSquad(data) {
  const root = document.getElementById("gpflSquad");
  const squad = data.squad || [];
  if (!squad.length) {
    root.innerHTML = `<p class="gpfl-muted">Empty squad — pick players from the pool.</p>`;
    return;
  }
  const rows = squad
    .map((p) => {
      const fa = p.slot_status === "needs_replace";
      return `<tr class="${fa ? "needs-replace" : ""}">
        <td><input type="checkbox" class="gpfl-starter" data-id="${esc(p.player_id)}" ${p.is_starter ? "checked" : ""} ${fa ? "disabled" : ""}></td>
        <td><input type="radio" name="gpflCap" class="gpfl-cap" value="${esc(p.player_id)}" ${p.is_captain ? "checked" : ""} ${fa || !p.is_starter ? "disabled" : ""}></td>
        <td>${esc(p.player_name || p.player_id)}
          ${fa ? `<span class="gpfl-badge gpfl-badge--fa">FA — replace</span>` : ""}
          ${p.is_captain ? `<span class="gpfl-badge gpfl-badge--c">C</span>` : ""}
        </td>
        <td>${esc(p.club_short_name || "—")}</td>
        <td>${esc((p.position_group || "").toUpperCase())}</td>
        <td class="num">${money(p.purchase_price)}</td>
        <td><button type="button" class="gpfl-btn gpfl-rm" data-id="${esc(p.player_id)}">${fa ? "Clear" : "Sell"}</button></td>
      </tr>`;
    })
    .join("");
  root.innerHTML = `<table class="gpfl-table">
    <thead><tr><th>XI</th><th>C</th><th>Player</th><th>Club</th><th>Pos</th><th class="num">Paid</th><th></th></tr></thead>
    <tbody>${rows}</tbody>
  </table>`;

  root.querySelectorAll(".gpfl-rm").forEach((btn) => {
    btn.onclick = async () => {
      setStatus("Removing…");
      const { error } = await supabase.rpc("gpfl_remove_player", { p_player_id: btn.dataset.id });
      if (error) return setStatus(error.message, false);
      await refresh();
      setStatus("Removed.");
    };
  });

  root.querySelectorAll(".gpfl-starter").forEach((cb) => {
    cb.onchange = () => {
      const id = cb.dataset.id;
      const radio = root.querySelector(`.gpfl-cap[value="${id.replace(/"/g, "")}"]`);
      if (radio) radio.disabled = !cb.checked;
      if (!cb.checked && radio) radio.checked = false;
    };
  });
}

function renderPosTabs() {
  const tabs = document.getElementById("gpflPosTabs");
  const groups = [
    ["gk", "GK"],
    ["def", "DEF"],
    ["mid", "MID"],
    ["fwd", "FWD"],
  ];
  tabs.innerHTML = groups
    .map(
      ([id, label]) =>
        `<button type="button" class="gpfl-tab ${state.posGroup === id ? "active" : ""}" data-g="${id}">${label}</button>`
    )
    .join("");
  tabs.querySelectorAll(".gpfl-tab").forEach((b) => {
    b.onclick = () => {
      state.posGroup = b.dataset.g;
      renderPosTabs();
      loadPool();
    };
  });
}

async function loadPool() {
  const search = document.getElementById("gpflSearch")?.value || null;
  const div = document.getElementById("gpflDivFilter")?.value || null;
  const { data, error } = await supabase.rpc("gpfl_list_players", {
    p_position_group: state.posGroup,
    p_division: div || null,
    p_club: null,
    p_search: search,
    p_max_price: null,
    p_limit: 60,
    p_offset: 0,
  });
  const root = document.getElementById("gpflPool");
  if (error) {
    root.innerHTML = `<p class="gpfl-muted">${esc(error.message)}</p>`;
    return;
  }
  const players = data?.players || [];
  state.pool = players;
  if (!players.length) {
    root.innerHTML = `<p class="gpfl-muted">No players (open season / refresh pool as admin).</p>`;
    return;
  }
  root.innerHTML = `<p class="gpfl-muted" style="margin:0 0 8px;">${esc(data.total)} in filter · showing ${players.length}</p>
    <table class="gpfl-table">
      <thead><tr><th>Player</th><th>Club</th><th>Div</th><th>Pos</th><th class="num">GPFL price</th><th></th></tr></thead>
      <tbody>
        ${players
          .map(
            (p) => `<tr>
              <td>${esc(p.player_name)}</td>
              <td>${esc(p.club_short_name)}</td>
              <td>${esc(p.division || "")}</td>
              <td>${esc(p.position || p.position_group)}</td>
              <td class="num">${money(p.price)}</td>
              <td><button type="button" class="gpfl-btn gpfl-add" data-id="${esc(p.player_id)}">Add</button></td>
            </tr>`
          )
          .join("")}
      </tbody>
    </table>`;

  root.querySelectorAll(".gpfl-add").forEach((btn) => {
    btn.onclick = async () => {
      setStatus("Adding…");
      const { error: err } = await supabase.rpc("gpfl_add_player", { p_player_id: btn.dataset.id });
      if (err) return setStatus(err.message, false);
      await refresh();
      setStatus("Added.");
    };
  });
}

async function loadBoard() {
  const root = document.getElementById("gpflBoard");
  const { data, error } = await supabase.rpc("gpfl_leaderboard", { p_limit: 60 });
  if (error) {
    root.innerHTML = `<p class="gpfl-muted">${esc(error.message)}</p>`;
    return;
  }
  const rows = data?.rows || [];
  if (!rows.length) {
    root.innerHTML = `<p class="gpfl-muted">No entries yet.</p>`;
    return;
  }
  root.innerHTML = `<table class="gpfl-table">
    <thead><tr><th>#</th><th>Team</th><th>Club</th><th class="num">Pts</th></tr></thead>
    <tbody>
      ${rows
        .map(
          (r) => `<tr ${r.is_me ? 'style="background:rgba(60,120,180,0.15)"' : ""}>
            <td>${esc(r.rank)}</td>
            <td>${esc(r.team_name || "—")}${r.is_me ? ' <span class="gpfl-badge">you</span>' : ""}</td>
            <td>${esc(r.club_short_name || "—")}</td>
            <td class="num">${esc(r.total_points ?? 0)}</td>
          </tr>`
        )
        .join("")}
    </tbody>
  </table>`;
}

function fillScoreMonths() {
  const sel = document.getElementById("gpflScoreMonth");
  if (!sel) return;
  const entries = Object.entries(GPSL_MONTH_LABELS || {}).filter(([k]) => k !== "playoffs");
  sel.innerHTML = entries
    .map(([id, label]) => `<option value="${esc(id)}">${esc(label)}</option>`)
    .join("");
}

async function refresh() {
  const data = await loadEntry();
  if (!data) return;
  renderGate(data);
  if (data.joined) {
    renderEntryStats(data);
    renderSquad(data);
    renderPosTabs();
    await loadPool();
    await loadBoard();
  }
}

function wire() {
  document.getElementById("gpflJoinBtn")?.addEventListener("click", async () => {
    const name = document.getElementById("gpflTeamName")?.value || null;
    setStatus("Joining…");
    const { error } = await supabase.rpc("gpfl_join", { p_team_name: name });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus("Joined GPFL.");
  });

  document.getElementById("gpflWithdrawBtn")?.addEventListener("click", async () => {
    if (!confirm("Withdraw from GPFL this season?")) return;
    const { error } = await supabase.rpc("gpfl_withdraw");
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus("Withdrawn.");
  });

  document.getElementById("gpflConfirmBtn")?.addEventListener("click", async () => {
    setStatus("Confirming…");
    const { error } = await supabase.rpc("gpfl_confirm_squad");
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus("Squad confirmed.");
  });

  document.getElementById("gpflSaveXiBtn")?.addEventListener("click", async () => {
    const starters = [...document.querySelectorAll(".gpfl-starter:checked")].map((el) => el.dataset.id);
    const cap = document.querySelector(".gpfl-cap:checked")?.value || null;
    setStatus("Saving XI…");
    const { error } = await supabase.rpc("gpfl_set_xi", {
      p_starter_ids: starters,
      p_captain_id: cap,
    });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus("XI saved.");
  });

  document.getElementById("gpflSearchBtn")?.addEventListener("click", () => loadPool());
  document.getElementById("gpflSearch")?.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") loadPool();
  });
  document.getElementById("gpflDivFilter")?.addEventListener("change", () => loadPool());

  document.getElementById("gpflOpenSeasonBtn")?.addEventListener("click", async () => {
    setStatus("Opening GPFL season…");
    const { data, error } = await supabase.rpc("admin_gpfl_open_season", {
      p_competition_season_id: null,
      p_refresh_prices: false,
    });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus(`GPFL season ready (${data?.price_rows_touched ?? "?"} price rows).`);
  });

  document.getElementById("gpflSyncFaBtn")?.addEventListener("click", async () => {
    const { data, error } = await supabase.rpc("gpfl_sync_free_agents", { p_gpfl_season_id: null });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus(`Synced FA slots (${data?.refunded_slots ?? 0} refunds).`);
  });

  document.getElementById("gpflScoreBtn")?.addEventListener("click", async () => {
    const month = document.getElementById("gpflScoreMonth")?.value;
    setStatus(`Scoring ${month}…`);
    const { data, error } = await supabase.rpc("gpfl_score_month", {
      p_gpsl_month: month,
      p_gpfl_season_id: null,
    });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus(`Scored ${month}: ${data?.entries_scored ?? 0} entries.`);
  });
}

async function main() {
  await initGlobal();
  state.isAdmin = await resolveAdmin();
  const adminPanel = document.getElementById("gpflAdminPanel");
  if (adminPanel) adminPanel.hidden = !state.isAdmin;
  fillScoreMonths();
  wire();
  await refresh();
}

main().catch((err) => setStatus(err?.message || String(err), false));
