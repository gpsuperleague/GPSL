import { supabase, initGlobal } from "./global.js";
import { formatMoney, GPSL_MONTH_LABELS } from "./competition.js";
import {
  FORMATION_LIST,
  FORMATION_GROUP_ORDER,
  DEFAULT_FORMATION_ID,
  getFormation,
} from "./matchday_formations.js";

let state = {
  isAdmin: false,
  payload: null,
  posGroup: "fwd",
  pool: [],
  formationId: DEFAULT_FORMATION_ID,
  slotMap: {}, // slot_id -> player_id
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

function normalizePos(pos) {
  const p = String(pos || "").trim().toUpperCase();
  if (p === "LW") return "LWF";
  if (p === "RW") return "RWF";
  if (p === "LM") return "LMF";
  if (p === "RM") return "RMF";
  if (p === "WG") return "LWF";
  return p;
}

/** GPFL flex: LMF↔LWF, RMF↔RWF, CF↔SS; else exact. */
function posFitsSlot(playerPos, requiredPos) {
  const p = normalizePos(playerPos);
  const s = normalizePos(requiredPos);
  if (!p || !s) return false;
  if (p === s) return true;
  if ((p === "LMF" || p === "LWF") && (s === "LMF" || s === "LWF")) return true;
  if ((p === "RMF" || p === "RWF") && (s === "RMF" || s === "RWF")) return true;
  if ((p === "CF" || p === "SS") && (s === "CF" || s === "SS")) return true;
  return false;
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
  const cap = Number(data.season?.budget_snapshot ?? s.budget ?? 0);
  const remaining = Number(e.budget_remaining ?? 0);
  const spent = Math.max(0, cap - remaining);
  el.innerHTML = `
    <div class="gpfl-stat">Bank left <b>${money(remaining)}</b></div>
    <div class="gpfl-stat">Spent on squad <b>${money(spent)}</b></div>
    <div class="gpfl-stat">Season budget <b>${money(cap)}</b></div>
    <div class="gpfl-stat">Status <b>${esc(e.status)}</b></div>
    <div class="gpfl-stat">Formation <b>${esc(e.formation_id || "—")}</b></div>
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
        <td>${esc(p.player_name || p.player_id)}
          ${fa ? `<span class="gpfl-badge gpfl-badge--fa">FA — replace</span>` : ""}
          ${p.is_captain ? `<span class="gpfl-badge gpfl-badge--c">C</span>` : ""}
          ${p.pitch_slot ? `<span class="gpfl-badge">${esc(p.pitch_slot)}</span>` : ""}
        </td>
        <td>${esc(p.position || p.position_group || "—")}</td>
        <td>${esc(p.club_name || p.club_short_name || "—")}</td>
        <td>${esc(p.owner_name || "—")}</td>
        <td class="num">${money(p.purchase_price)}</td>
        <td><button type="button" class="gpfl-btn gpfl-rm" data-id="${esc(p.player_id)}">${fa ? "Clear" : "Sell"}</button></td>
      </tr>`;
    })
    .join("");
  root.innerHTML = `<table class="gpfl-table">
    <thead><tr><th>Player</th><th>Pos</th><th>Club</th><th>Owner</th><th class="num">Paid</th><th></th></tr></thead>
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
}

function fillFormationSelect(data) {
  const sel = document.getElementById("gpflFormation");
  if (!sel) return;
  const current = data?.entry?.formation_id || state.formationId || DEFAULT_FORMATION_ID;
  state.formationId = current;
  const opts = [];
  for (const group of FORMATION_GROUP_ORDER) {
    const list = FORMATION_LIST.filter((f) => f.group === group);
    if (!list.length) continue;
    opts.push(`<optgroup label="${esc(group)}">`);
    for (const f of list) {
      opts.push(
        `<option value="${esc(f.id)}" ${f.id === current ? "selected" : ""}>${esc(f.name)}</option>`
      );
    }
    opts.push(`</optgroup>`);
  }
  sel.innerHTML = opts.join("");
  sel.onchange = () => {
    state.formationId = sel.value;
    state.slotMap = {};
    renderXi(state.payload);
  };
}

function renderXi(data) {
  const root = document.getElementById("gpflXi");
  const capSel = document.getElementById("gpflCaptain");
  if (!root) return;
  const squad = (data?.squad || []).filter((p) => p.slot_status === "active");
  const formation = getFormation(state.formationId);
  if (!formation) {
    root.innerHTML = `<p class="gpfl-muted">Unknown formation.</p>`;
    return;
  }

  if (!Object.keys(state.slotMap).length) {
    for (const p of squad) {
      if (p.pitch_slot && p.is_starter) state.slotMap[p.pitch_slot] = p.player_id;
    }
  }

  const used = new Set(Object.values(state.slotMap).filter(Boolean));

  const rows = formation.slots
    .map((slot) => {
      const required = slot.label;
      const selected = state.slotMap[slot.id] || "";
      const eligible = squad.filter((p) => posFitsSlot(p.position, required));
      const options = [
        `<option value="">— pick ${esc(required)} —</option>`,
        ...eligible.map((p) => {
          const taken = used.has(p.player_id) && state.slotMap[slot.id] !== p.player_id;
          return `<option value="${esc(p.player_id)}" ${
            selected === p.player_id ? "selected" : ""
          } ${taken ? "disabled" : ""}>${esc(p.player_name)} (${esc(p.position)})${
            taken ? " · in XI" : ""
          }</option>`;
        }),
      ];
      return `<tr>
        <td><b>${esc(slot.id)}</b></td>
        <td>${esc(required)}</td>
        <td><select class="gpfl-slot" data-slot="${esc(slot.id)}" style="width:100%;min-width:160px;background:#111820;border:1px solid #445;color:#eee;padding:6px;border-radius:4px;">${options.join("")}</select></td>
      </tr>`;
    })
    .join("");

  root.innerHTML = `<table class="gpfl-table">
    <thead><tr><th>Slot</th><th>Needs</th><th>Player</th></tr></thead>
    <tbody>${rows}</tbody>
  </table>`;

  root.querySelectorAll(".gpfl-slot").forEach((sel) => {
    sel.onchange = () => {
      const slotId = sel.dataset.slot;
      const pid = sel.value || "";
      if (pid) {
        for (const [k, v] of Object.entries(state.slotMap)) {
          if (v === pid && k !== slotId) delete state.slotMap[k];
        }
        state.slotMap[slotId] = pid;
      } else {
        delete state.slotMap[slotId];
      }
      renderXi(state.payload);
    };
  });

  const starterIds = formation.slots.map((s) => state.slotMap[s.id]).filter(Boolean);
  const starters = squad.filter((p) => starterIds.includes(p.player_id));
  const savedCap = squad.find((p) => p.is_captain)?.player_id || "";
  if (capSel) {
    const prefer = savedCap && starterIds.includes(savedCap) ? savedCap : capSel.value;
    capSel.innerHTML =
      `<option value="">— captain —</option>` +
      starters
        .map(
          (p) =>
            `<option value="${esc(p.player_id)}">${esc(p.player_name)}</option>`
        )
        .join("");
    if (prefer && starterIds.includes(prefer)) capSel.value = prefer;
    else if (starters.length) capSel.value = starters[0].player_id;
  }
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
      <thead><tr><th>Player</th><th>Club</th><th>Owner</th><th>Div</th><th>Pos</th><th class="num">GPFL price</th><th></th></tr></thead>
      <tbody>
        ${players
          .map(
            (p) => `<tr>
              <td>${esc(p.player_name)}</td>
              <td>${esc(p.club_name || p.club_short_name)}</td>
              <td>${esc(p.owner_name || "Vacant")}</td>
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
    state.formationId = data.entry?.formation_id || state.formationId || DEFAULT_FORMATION_ID;
    state.slotMap = {};
    for (const p of data.squad || []) {
      if (p.pitch_slot && p.is_starter) state.slotMap[p.pitch_slot] = p.player_id;
    }
    renderEntryStats(data);
    fillFormationSelect(data);
    renderXi(data);
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
    const formationId =
      document.getElementById("gpflFormation")?.value || state.formationId;
    const formation = getFormation(formationId);
    const slotMap = {};
    for (const slot of formation.slots) {
      const pid = state.slotMap[slot.id];
      if (!pid) {
        setStatus(`Fill ${slot.id} (${slot.label}) before saving.`, false);
        return;
      }
      slotMap[slot.id] = pid;
    }
    const cap = document.getElementById("gpflCaptain")?.value || null;
    if (!cap) {
      setStatus("Pick a captain from the XI.", false);
      return;
    }
    setStatus("Saving formation XI…");
    const { error } = await supabase.rpc("gpfl_set_xi", {
      p_formation_id: formationId,
      p_slot_map: slotMap,
      p_captain_id: cap,
    });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus("Formation XI saved.");
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
