import { supabase, initGlobal } from "./global.js";
import { GPSL_MONTH_LABELS } from "./competition.js";
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
  benchOrder: [], // player_id[] priority 1..n
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

function moneyNum(n) {
  const v = Number(n ?? 0);
  if (!Number.isFinite(v)) return "—";
  return v.toLocaleString("en-GB", { maximumFractionDigits: 0 });
}

function money(n) {
  return `₿\u00A0${moneyNum(n)}`;
}

function monthLabel(id) {
  if (!id) return "—";
  return GPSL_MONTH_LABELS?.[id] || String(id);
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

function editingOpen(data = state.payload) {
  return data?.editing_open !== false;
}

function patchMissingHint(err) {
  const m = String(err?.message || err || "");
  if (/gpfl_|column .* does not exist|Could not find the function/i.test(m)) {
    return (
      m +
      " — run gpfl_v2_core_20260818.sql then gpfl_v2_scoring_transfers_20260818.sql in Supabase."
    );
  }
  return m;
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
    setStatus(patchMissingHint(error), false);
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

function renderDeadlineBanner(data) {
  const el = document.getElementById("gpflDeadlineBanner");
  if (!el) return;
  if (!data?.gpfl_season_id) {
    el.hidden = true;
    return;
  }
  const open = data.editing_open !== false;
  const month = monthLabel(data.target_month);
  const mode = data.settings?.deadline_mode || "month_unlock";
  el.hidden = false;
  el.className = `gpfl-deadline ${open ? "gpfl-deadline--open" : "gpfl-deadline--locked"}`;
  if (mode === "none") {
    el.textContent = `Editing always open (deadline mode: none). Target month: ${month}.`;
  } else if (open) {
    el.textContent = `Transfers & XI open for ${month}. Locks when that GPSL month goes live.`;
  } else {
    el.textContent = `Deadline passed — ${month} is live. Squad changes reopen when the month locks.`;
  }
}

function slotCounts(data) {
  const s = data?.settings || {};
  const caps = {
    gk: Number(s.slot_gk ?? 2),
    def: Number(s.slot_def ?? 5),
    mid: Number(s.slot_mid ?? 5),
    fwd: Number(s.slot_fwd ?? 3),
  };
  const have = { gk: 0, def: 0, mid: 0, fwd: 0 };
  for (const p of data?.squad || []) {
    if (p.slot_status !== "active") continue;
    const g = String(p.position_group || "").toLowerCase();
    if (have[g] != null) have[g] += 1;
  }
  return { caps, have };
}

function setEditLocked(locked) {
  document.querySelectorAll(
    "#gpflConfirmBtn, #gpflSaveXiBtn, #gpflFormation, #gpflCaptain, .gpfl-add, .gpfl-rm, .gpfl-chip-btn, .gpfl-bench-move, .gpfl-slot, .gpfl-pitch-pick"
  ).forEach((el) => {
    if (el.classList?.contains("gpfl-chip-btn") && el.dataset.chip === "info") return;
    el.disabled = locked;
  });
}

function renderEntryStats(data) {
  const e = data.entry || {};
  const s = data.settings || {};
  const el = document.getElementById("gpflEntryStats");
  if (!el) return;
  const squad = data.squad || [];
  const active = squad.filter((p) => p.slot_status === "active");
  const needs = squad.filter((p) => p.slot_status === "needs_replace").length;
  const cap = Number(data.season?.budget_snapshot ?? s.budget ?? 0);
  const spent = active.reduce((sum, p) => sum + Number(p.purchase_price || 0), 0);
  const remaining =
    Number.isFinite(cap) && cap > 0 ? Math.max(0, cap - spent) : Number(e.budget_remaining ?? 0);
  const { caps, have } = slotCounts(data);
  const size = Number(s.squad_size ?? 15);
  const hitPts = Number(data.transfer_hit_points ?? s.transfer_hit_points ?? -4);
  const prov = data.provisional || {};
  const confirmBtn = document.getElementById("gpflConfirmBtn");
  if (confirmBtn) {
    const xiReady =
      active.filter((p) => p.is_starter).length === Number(s.starters ?? 11) &&
      active.some((p) => p.is_captain) &&
      Boolean(e.formation_id);
    const ready = active.length >= size && needs === 0 && xiReady;
    confirmBtn.disabled = !ready || !editingOpen(data);
    confirmBtn.title = !editingOpen(data)
      ? "Editing locked until month ends"
      : ready
        ? "Lock your 15-man squad for scoring"
        : `Need ${size} players, saved formation XI + captain (have ${active.length})`;
    confirmBtn.textContent = ready
      ? "Confirm squad"
      : `Confirm squad (${active.length}/${size})`;
  }
  el.innerHTML = `
    <div class="gpfl-stat">Bank left <b>${money(remaining)}</b></div>
    <div class="gpfl-stat">Spent on squad <b>${money(spent)}</b></div>
    <div class="gpfl-stat">Season budget <b>${money(cap)}</b></div>
    <div class="gpfl-stat">Status <b>${esc(e.status)}</b></div>
    <div class="gpfl-stat">Formation <b>${esc(e.formation_id || "—")}</b></div>
    <div class="gpfl-stat">Points <b>${esc(e.total_points ?? 0)}</b></div>
    <div class="gpfl-stat">Provisional <b>${esc(prov.points ?? 0)}</b>${
      prov.month ? ` <span class="gpfl-muted">(${esc(monthLabel(prov.month))})</span>` : ""
    }</div>
    <div class="gpfl-stat">Free transfers <b>${esc(e.free_transfers_remaining ?? 0)}</b></div>
    <div class="gpfl-stat">Hit cost <b>${esc(hitPts)} pts</b></div>
    <div class="gpfl-stat">Hits taken <b>${esc(e.transfer_hits_season ?? 0)}</b></div>
    <div class="gpfl-stat">Squad <b>${active.length}/${esc(size)}</b></div>
    <div class="gpfl-stat">Slots <b>GK ${have.gk}/${caps.gk} · DEF ${have.def}/${caps.def} · MID ${have.mid}/${caps.mid} · FWD ${have.fwd}/${caps.fwd}</b></div>
    ${needs ? `<div class="gpfl-stat">FA to replace <b>${needs}</b></div>` : ""}
  `;
  setEditLocked(!editingOpen(data));
}

function renderChips(data) {
  const root = document.getElementById("gpflChips");
  const panel = document.getElementById("gpflChipsPanel");
  if (!root) return;
  const chips = data?.chips;
  if (!chips?.enabled) {
    if (panel) panel.hidden = true;
    root.innerHTML = `<p class="gpfl-muted">Chips disabled by admin.</p>`;
    return;
  }
  if (panel) panel.hidden = false;
  const open = editingOpen(data);
  const defs = [
    ["wildcard", "Wildcard", "Unlimited free transfers this window"],
    ["triple_captain", "Triple Captain", "Captain scores ×3 this month"],
    ["bench_boost", "Bench Boost", "Bench also scores this month"],
  ];
  root.innerHTML = defs
    .map(([id, label, tip]) => {
      const meta = chips[id] || {};
      const enabled = meta.enabled !== false;
      const available = meta.available !== false;
      const active = chips.active === id;
      let stateLabel = !enabled
        ? "Off"
        : active
          ? `Active · ${monthLabel(chips.active_month)}`
          : available
            ? "Available"
            : "Used";
      const canPlay = open && enabled && available && !chips.active;
      return `<div class="gpfl-chip ${active ? "gpfl-chip--active" : ""} ${!available || !enabled ? "gpfl-chip--used" : ""}">
        <div class="gpfl-chip-name">${esc(label)}</div>
        <div class="gpfl-chip-tip">${esc(tip)}</div>
        <div class="gpfl-chip-state">${esc(stateLabel)}</div>
        <button type="button" class="gpfl-btn gpfl-chip-btn" data-chip="${id}" ${
          canPlay ? "" : "disabled"
        }>Play</button>
      </div>`;
    })
    .join("");

  root.querySelectorAll(".gpfl-chip-btn").forEach((btn) => {
    btn.onclick = async () => {
      const chip = btn.dataset.chip;
      if (!confirm(`Play ${chip.replace(/_/g, " ")} for ${monthLabel(data.target_month)}?`)) return;
      setStatus("Playing chip…");
      const { data: next, error } = await supabase.rpc("gpfl_play_chip", { p_chip: chip });
      if (error) return setStatus(patchMissingHint(error), false);
      if (next) state.payload = next;
      await refresh();
      setStatus("Chip played.");
    };
  });
}

function seedSlotMapFromSquad(squad) {
  const next = {};
  for (const p of squad || []) {
    if (p.slot_status === "active" && p.pitch_slot && p.is_starter) {
      next[p.pitch_slot] = p.player_id;
    }
  }
  return next;
}

function seedBenchFromSquad(squad, slotMap) {
  const starters = new Set(Object.values(slotMap || {}).filter(Boolean));
  const bench = (squad || [])
    .filter((p) => p.slot_status === "active" && !starters.has(p.player_id) && !p.is_starter)
    .sort((a, b) => (a.bench_order ?? 99) - (b.bench_order ?? 99));
  // Also include non-starters that still have is_starter false but weren't in pitch map
  const extras = (squad || []).filter(
    (p) =>
      p.slot_status === "active" &&
      !starters.has(p.player_id) &&
      !bench.some((b) => b.player_id === p.player_id)
  );
  return [...bench, ...extras]
    .sort((a, b) => (a.bench_order ?? 99) - (b.bench_order ?? 99))
    .map((p) => p.player_id);
}

function fillFormationSelect(data) {
  const sel = document.getElementById("gpflFormation");
  if (!sel) return;
  const current = data?.entry?.formation_id || state.formationId || DEFAULT_FORMATION_ID;
  state.formationId = current;
  sel.onchange = null;

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
  sel.value = current;
  sel.disabled = !editingOpen(data);

  sel.onchange = () => {
    const next = sel.value;
    if (next === state.formationId) return;
    state.formationId = next;
    state.slotMap = {};
    state.benchOrder = seedBenchFromSquad(state.payload?.squad, {});
    renderPitchAndXi(state.payload);
  };
}

function playerById(squad, id) {
  return (squad || []).find((p) => p.player_id === id);
}

function renderBench(data) {
  const root = document.getElementById("gpflBench");
  if (!root) return;
  const squad = (data?.squad || []).filter((p) => p.slot_status === "active");
  const starters = new Set(Object.values(state.slotMap).filter(Boolean));
  let order = state.benchOrder.filter((id) => !starters.has(id));
  const missing = squad
    .filter((p) => !starters.has(p.player_id) && !order.includes(p.player_id))
    .map((p) => p.player_id);
  order = [...order, ...missing];
  state.benchOrder = order;

  if (!order.length) {
    root.innerHTML = `<p class="gpfl-muted">Fill the XI — remaining players become the ordered bench.</p>`;
    return;
  }

  root.innerHTML = `<ol class="gpfl-bench-list">
    ${order
      .map((id, i) => {
        const p = playerById(squad, id);
        if (!p) return "";
        return `<li class="gpfl-bench-item">
          <span class="gpfl-bench-rank">${i + 1}</span>
          <button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(id)}">${esc(
            p.player_name || id
          )}</button>
          <span class="gpfl-muted">${esc(p.position || p.position_group || "")}</span>
          <span class="gpfl-bench-actions">
            <button type="button" class="gpfl-btn gpfl-bench-move" data-dir="-1" data-id="${esc(id)}" ${
              i === 0 || !editingOpen(data) ? "disabled" : ""
            }>↑</button>
            <button type="button" class="gpfl-btn gpfl-bench-move" data-dir="1" data-id="${esc(id)}" ${
              i === order.length - 1 || !editingOpen(data) ? "disabled" : ""
            }>↓</button>
          </span>
        </li>`;
      })
      .join("")}
  </ol>`;

  root.querySelectorAll(".gpfl-bench-move").forEach((btn) => {
    btn.onclick = () => {
      const id = btn.dataset.id;
      const dir = Number(btn.dataset.dir);
      const idx = state.benchOrder.indexOf(id);
      const j = idx + dir;
      if (idx < 0 || j < 0 || j >= state.benchOrder.length) return;
      const next = [...state.benchOrder];
      [next[idx], next[j]] = [next[j], next[idx]];
      state.benchOrder = next;
      renderBench(state.payload);
    };
  });
  root.querySelectorAll(".gpfl-card-link").forEach((btn) => {
    btn.onclick = () => openPlayerCard(btn.dataset.id);
  });
}

function renderPitch(data) {
  const root = document.getElementById("gpflPitch");
  if (!root) return;
  const squad = (data?.squad || []).filter((p) => p.slot_status === "active");
  const formation = getFormation(state.formationId);
  if (!formation) {
    root.innerHTML = `<p class="gpfl-muted">Unknown formation.</p>`;
    return;
  }
  if (!Object.keys(state.slotMap).length) {
    state.slotMap = seedSlotMapFromSquad(squad);
  }
  const used = new Set(Object.values(state.slotMap).filter(Boolean));
  const open = editingOpen(data);

  root.innerHTML = formation.slots
    .map((slot) => {
      const selected = state.slotMap[slot.id] || "";
      const pl = playerById(squad, selected);
      const eligible = squad.filter(
        (p) => posFitsSlot(p.position, slot.label) || p.player_id === selected
      );
      const opts = [
        `<option value="">${esc(slot.label)}</option>`,
        ...eligible.map((p) => {
          const taken = used.has(p.player_id) && state.slotMap[slot.id] !== p.player_id;
          return `<option value="${esc(p.player_id)}" ${
            selected === p.player_id ? "selected" : ""
          } ${taken ? "disabled" : ""}>${esc(p.player_name)}${taken ? " · XI" : ""}</option>`;
        }),
      ];
      const isCap =
        selected &&
        (document.getElementById("gpflCaptain")?.value === selected || pl?.is_captain);
      return `<div class="gpfl-pitch-slot ${selected ? "filled" : ""} ${isCap ? "captain" : ""}"
        style="left:${slot.x}%;top:${slot.y}%;">
        <div class="gpfl-pitch-pos">${esc(slot.label)}</div>
        ${
          pl
            ? `<button type="button" class="gpfl-pitch-name gpfl-card-link" data-id="${esc(
                selected
              )}">${esc(pl.player_name)}</button>`
            : `<div class="gpfl-pitch-name empty">Empty</div>`
        }
        <select class="gpfl-pitch-pick" data-slot="${esc(slot.id)}" ${open ? "" : "disabled"}>
          ${opts.join("")}
        </select>
      </div>`;
    })
    .join("");

  root.querySelectorAll(".gpfl-pitch-pick").forEach((sel) => {
    const slotId = sel.dataset.slot;
    if (state.slotMap[slotId]) sel.value = state.slotMap[slotId];
    sel.onchange = () => {
      const pid = sel.value || "";
      if (pid) {
        for (const [k, v] of Object.entries(state.slotMap)) {
          if (v === pid && k !== slotId) delete state.slotMap[k];
        }
        state.slotMap[slotId] = pid;
      } else {
        delete state.slotMap[slotId];
      }
      state.benchOrder = seedBenchFromSquad(squad, state.slotMap);
      renderPitchAndXi(state.payload);
    };
  });
  root.querySelectorAll(".gpfl-card-link").forEach((btn) => {
    btn.onclick = () => openPlayerCard(btn.dataset.id);
  });
}

function renderXiDropdowns(data) {
  const root = document.getElementById("gpflXi");
  const capSel = document.getElementById("gpflCaptain");
  if (!root) return;
  const squad = (data?.squad || []).filter((p) => p.slot_status === "active");
  const formation = getFormation(state.formationId);
  if (!formation) {
    root.innerHTML = "";
    return;
  }
  const used = new Set(Object.values(state.slotMap).filter(Boolean));
  const prevCap = capSel?.value || "";
  const open = editingOpen(data);

  const rows = formation.slots
    .map((slot) => {
      const required = slot.label;
      const selected = state.slotMap[slot.id] || "";
      const eligible = squad.filter(
        (p) => posFitsSlot(p.position, required) || p.player_id === selected
      );
      const options = [
        `<option value="">— pick ${esc(required)} —</option>`,
        ...eligible.map((p) => {
          const taken = used.has(p.player_id) && state.slotMap[slot.id] !== p.player_id;
          return `<option value="${esc(p.player_id)}" ${
            selected === p.player_id ? "selected" : ""
          } ${taken ? "disabled" : ""}>${esc(p.player_name)} (${esc(p.position || "?")})${
            taken ? " · in XI" : ""
          }</option>`;
        }),
      ];
      return `<tr>
        <td><b>${esc(slot.id)}</b></td>
        <td>${esc(required)}</td>
        <td><select class="gpfl-slot" data-slot="${esc(slot.id)}" ${open ? "" : "disabled"}
          style="width:100%;min-width:160px;background:#111820;border:1px solid #445;color:#eee;padding:6px;border-radius:4px;">${options.join(
            ""
          )}</select></td>
      </tr>`;
    })
    .join("");

  root.innerHTML = `<table class="gpfl-table">
    <thead><tr><th>Slot</th><th>Needs</th><th>Player</th></tr></thead>
    <tbody>${rows}</tbody>
  </table>`;

  root.querySelectorAll(".gpfl-slot").forEach((sel) => {
    const slotId = sel.dataset.slot;
    if (state.slotMap[slotId]) sel.value = state.slotMap[slotId];
    sel.onchange = () => {
      const pid = sel.value || "";
      if (pid) {
        for (const [k, v] of Object.entries(state.slotMap)) {
          if (v === pid && k !== slotId) delete state.slotMap[k];
        }
        state.slotMap[slotId] = pid;
      } else {
        delete state.slotMap[slotId];
      }
      state.benchOrder = seedBenchFromSquad(squad, state.slotMap);
      renderPitchAndXi(state.payload);
    };
  });

  const starterIds = formation.slots.map((s) => state.slotMap[s.id]).filter(Boolean);
  const starters = squad.filter((p) => starterIds.includes(p.player_id));
  const savedCap = squad.find((p) => p.is_captain)?.player_id || "";
  if (capSel) {
    capSel.disabled = !open;
    capSel.innerHTML =
      `<option value="">— captain —</option>` +
      starters
        .map((p) => `<option value="${esc(p.player_id)}">${esc(p.player_name)}</option>`)
        .join("");
    const prefer =
      (prevCap && starterIds.includes(prevCap) && prevCap) ||
      (savedCap && starterIds.includes(savedCap) && savedCap) ||
      (starters[0] && starters[0].player_id) ||
      "";
    if (prefer) capSel.value = prefer;
    capSel.onchange = () => renderPitch(state.payload);
  }
}

function renderPitchAndXi(data) {
  renderPitch(data);
  renderXiDropdowns(data);
  renderBench(data);
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
      const role = p.is_starter
        ? p.pitch_slot || "XI"
        : p.bench_order
          ? `B${p.bench_order}`
          : "Bench";
      return `<tr class="${fa ? "needs-replace" : ""}">
        <td>
          <button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(p.player_id)}">${esc(
            p.player_name || p.player_id
          )}</button>
          ${fa ? `<span class="gpfl-badge gpfl-badge--fa">FA — replace</span>` : ""}
          ${p.is_captain ? `<span class="gpfl-badge gpfl-badge--c">C</span>` : ""}
          <span class="gpfl-badge">${esc(role)}</span>
        </td>
        <td>${esc(p.position || p.position_group || "—")}</td>
        <td>${esc(p.club_name || p.club_short_name || "—")}</td>
        <td class="num">${p.month_points != null ? esc(p.month_points) : "—"}</td>
        <td class="num">${moneyNum(p.purchase_price)}</td>
        <td><button type="button" class="gpfl-btn gpfl-rm" data-id="${esc(p.player_id)}" ${
          editingOpen(data) ? "" : "disabled"
        }>${fa ? "Clear" : "Sell"}</button></td>
      </tr>`;
    })
    .join("");
  root.innerHTML = `<table class="gpfl-table">
    <thead><tr><th>Player</th><th>Pos</th><th>Club</th><th class="num">Mo pts</th><th class="num">Paid (₿)</th><th></th></tr></thead>
    <tbody>${rows}</tbody>
  </table>`;

  root.querySelectorAll(".gpfl-rm").forEach((btn) => {
    btn.onclick = async () => {
      setStatus("Removing…");
      const { data: next, error } = await supabase.rpc("gpfl_remove_player", {
        p_player_id: btn.dataset.id,
      });
      if (error) return setStatus(patchMissingHint(error), false);
      if (next) state.payload = next;
      await refresh();
      setStatus("Removed.");
    };
  });
  root.querySelectorAll(".gpfl-card-link").forEach((btn) => {
    btn.onclick = () => openPlayerCard(btn.dataset.id);
  });
}

function fdrClass(fdr) {
  const n = Number(fdr) || 3;
  return `gpfl-fdr gpfl-fdr--${Math.min(5, Math.max(1, n))}`;
}

async function openPlayerCard(playerId) {
  const dlg = document.getElementById("gpflCardDialog");
  const body = document.getElementById("gpflCardBody");
  const title = document.getElementById("gpflCardTitle");
  if (!dlg || !body) return;
  title.textContent = "Loading…";
  body.innerHTML = `<p class="gpfl-muted">Fetching card…</p>`;
  dlg.showModal();
  const { data, error } = await supabase.rpc("gpfl_player_card", { p_player_id: playerId });
  if (error || !data?.ok) {
    title.textContent = "Player";
    body.innerHTML = `<p class="gpfl-muted">${esc(patchMissingHint(error || data?.reason))}</p>`;
    return;
  }
  title.textContent = data.player_name || playerId;
  const form = (data.form || [])
    .map(
      (f) =>
        `<span class="gpfl-form-chip">${esc(monthLabel(f.gpsl_month))}: <b>${esc(f.points)}</b></span>`
    )
    .join("") || `<span class="gpfl-muted">No scored months yet</span>`;
  const fixtures = (data.next_fixtures || [])
    .map((fx) => {
      const ha = fx.is_home ? "H" : "A";
      return `<tr>
        <td>${esc(monthLabel(fx.gpsl_month))} MD${esc(fx.matchday)}</td>
        <td>${esc(ha)} ${esc(fx.opponent_name || fx.opponent_short_name)}</td>
        <td><span class="${fdrClass(fx.fdr)}" title="Fixture difficulty">${esc(fx.fdr ?? "—")}</span></td>
      </tr>`;
    })
    .join("");
  body.innerHTML = `
    <div class="gpfl-card-meta">
      <div><span class="gpfl-muted">Club</span><b>${esc(data.club_name || data.club_short_name || "—")}</b></div>
      <div><span class="gpfl-muted">Pos</span><b>${esc(data.position || data.position_group)}</b></div>
      <div><span class="gpfl-muted">Price</span><b>${money(data.price)}</b></div>
      <div><span class="gpfl-muted">Owned by</span><b>${esc(data.ownership_pct ?? 0)}%</b></div>
      <div><span class="gpfl-muted">Total pts</span><b>${esc(data.total_points ?? 0)}</b></div>
      <div><span class="gpfl-muted">Apps</span><b>${esc(data.apps ?? 0)}</b></div>
      <div><span class="gpfl-muted">G / A</span><b>${esc(data.goals ?? 0)} / ${esc(data.assists ?? 0)}</b></div>
      <div><span class="gpfl-muted">POTM</span><b>${esc(data.potm ?? 0)}</b></div>
    </div>
    <h3 class="gpfl-subhead">Form (recent months)</h3>
    <div class="gpfl-form-row">${form}</div>
    <h3 class="gpfl-subhead">Next fixtures · FDR (1 easy → 5 hard)</h3>
    ${
      fixtures
        ? `<table class="gpfl-table"><thead><tr><th>When</th><th>Opp</th><th>FDR</th></tr></thead><tbody>${fixtures}</tbody></table>`
        : `<p class="gpfl-muted">No upcoming fixtures.</p>`
    }
  `;
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
    root.innerHTML = `<p class="gpfl-muted">${esc(patchMissingHint(error))}</p>`;
    return;
  }
  const players = data?.players || [];
  state.pool = players;
  if (!players.length) {
    root.innerHTML = `<p class="gpfl-muted">No players (open season / refresh pool as admin).</p>`;
    return;
  }
  const open = editingOpen(state.payload);
  root.innerHTML = `<p class="gpfl-muted" style="margin:0 0 8px;">${esc(data.total)} in filter · showing ${players.length}</p>
    <table class="gpfl-table">
      <thead><tr><th>Player</th><th>Club</th><th>Own%</th><th>Pts</th><th>Pos</th><th class="num">Price (₿)</th><th></th></tr></thead>
      <tbody>
        ${players
          .map(
            (p) => `<tr>
              <td><button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(
                p.player_id
              )}">${esc(p.player_name)}</button></td>
              <td>${esc(p.club_name || p.club_short_name)}</td>
              <td class="num">${esc(p.ownership_pct ?? "—")}</td>
              <td class="num">${esc(p.total_points ?? 0)}</td>
              <td>${esc(p.position || p.position_group)}</td>
              <td class="num">${moneyNum(p.price)}</td>
              <td><button type="button" class="gpfl-btn gpfl-add" data-id="${esc(p.player_id)}" ${
                open ? "" : "disabled"
              }>Add</button></td>
            </tr>`
          )
          .join("")}
      </tbody>
    </table>`;

  root.querySelectorAll(".gpfl-add").forEach((btn) => {
    btn.onclick = async () => {
      const { caps, have } = slotCounts(state.payload || {});
      const row = state.pool.find((p) => p.player_id === btn.dataset.id);
      const g = String(row?.position_group || "").toLowerCase();
      if (g && caps[g] != null && have[g] >= caps[g]) {
        setStatus(
          `No ${g.toUpperCase()} slots left (${have[g]}/${caps[g]}). Sell one or pick another position.`,
          false
        );
        return;
      }
      const free = Number(state.payload?.entry?.free_transfers_remaining ?? 0);
      const status = state.payload?.entry?.status;
      const hit = Number(state.payload?.transfer_hit_points ?? -4);
      if (status === "active" && free <= 0) {
        if (
          !confirm(
            `No free transfers left. This transfer costs ${hit} points. Continue?`
          )
        ) {
          return;
        }
      }
      setStatus("Adding…");
      const { data: next, error: err } = await supabase.rpc("gpfl_add_player", {
        p_player_id: btn.dataset.id,
      });
      if (err) return setStatus(patchMissingHint(err), false);
      if (next) state.payload = next;
      await refresh();
      setStatus("Added.");
    };
  });
  root.querySelectorAll(".gpfl-card-link").forEach((btn) => {
    btn.onclick = () => openPlayerCard(btn.dataset.id);
  });
}

function renderMonthScores(data) {
  const root = document.getElementById("gpflMonthScores");
  if (!root) return;
  const rows = data?.month_points || [];
  if (!rows.length) {
    root.innerHTML = `<p class="gpfl-muted">No month scores yet. Provisional updates as results come in; finalise on Score month.</p>`;
    return;
  }
  root.innerHTML = `<table class="gpfl-table">
    <thead><tr><th>Month</th><th class="num">Pts</th><th class="num">Hits</th><th>Chip</th><th>Status</th></tr></thead>
    <tbody>
      ${rows
        .map(
          (r) => `<tr>
            <td>${esc(monthLabel(r.gpsl_month))}</td>
            <td class="num">${esc(r.points ?? 0)}</td>
            <td class="num">${esc(r.hit_points ?? 0)}</td>
            <td>${esc(r.chip_used ? String(r.chip_used).replace(/_/g, " ") : "—")}</td>
            <td>${r.is_provisional ? '<span class="gpfl-badge">provisional</span>' : "final"}</td>
          </tr>`
        )
        .join("")}
    </tbody>
  </table>`;
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

function fillMonthSelects() {
  const entries = Object.entries(GPSL_MONTH_LABELS || {}).filter(([k]) => k !== "playoffs");
  const html = entries
    .map(([id, label]) => `<option value="${esc(id)}">${esc(label)}</option>`)
    .join("");
  const score = document.getElementById("gpflScoreMonth");
  const content = document.getElementById("gpflContentMonth");
  if (score) score.innerHTML = html;
  if (content) {
    content.innerHTML = html;
    const target = state.payload?.target_month;
    if (target && entries.some(([id]) => id === target)) content.value = target;
  }
}

async function loadContent() {
  const month = document.getElementById("gpflContentMonth")?.value || null;
  const dreamRoot = document.getElementById("gpflDreamTeam");
  const xferRoot = document.getElementById("gpflTopTransfers");
  if (!dreamRoot || !xferRoot) return;

  dreamRoot.innerHTML = `<p class="gpfl-muted">Loading…</p>`;
  xferRoot.innerHTML = `<p class="gpfl-muted">Loading…</p>`;

  const [dream, xfer] = await Promise.all([
    supabase.rpc("gpfl_dream_team", { p_gpsl_month: month }),
    supabase.rpc("gpfl_top_transfers", { p_gpsl_month: month, p_limit: 10 }),
  ]);

  if (dream.error) {
    dreamRoot.innerHTML = `<p class="gpfl-muted">${esc(patchMissingHint(dream.error))}</p>`;
  } else if (!dream.data?.ok || !(dream.data.players || []).length) {
    dreamRoot.innerHTML = `<p class="gpfl-muted">No dream team yet for ${esc(
      monthLabel(month)
    )} (needs scored fixtures).</p>`;
  } else {
    const players = dream.data.players || [];
    dreamRoot.innerHTML = `<p class="gpfl-muted" style="margin:0 0 8px;">Total ${esc(
      dream.data.total_points
    )} pts · ${esc(dream.data.shape || "4-4-2")}</p>
      <table class="gpfl-table">
        <thead><tr><th>Player</th><th>Pos</th><th>Own%</th><th class="num">Pts</th></tr></thead>
        <tbody>
          ${players
            .map(
              (p) => `<tr>
                <td><button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(
                  p.player_id
                )}">${esc(p.player_name)}</button>
                <div class="gpfl-muted" style="font-size:11px;">${esc(p.club_name || "")}</div></td>
                <td>${esc(p.position || p.position_group)}</td>
                <td class="num">${esc(p.ownership_pct ?? "—")}</td>
                <td class="num">${esc(p.points)}</td>
              </tr>`
            )
            .join("")}
        </tbody>
      </table>`;
    dreamRoot.querySelectorAll(".gpfl-card-link").forEach((btn) => {
      btn.onclick = () => openPlayerCard(btn.dataset.id);
    });
  }

  if (xfer.error) {
    xferRoot.innerHTML = `<p class="gpfl-muted">${esc(patchMissingHint(xfer.error))}</p>`;
  } else {
    const tin = xfer.data?.transfers_in || [];
    const tout = xfer.data?.transfers_out || [];
    const block = (title, rows) =>
      `<h4 class="gpfl-subhead" style="margin-top:8px;">${title}</h4>` +
      (rows.length
        ? `<table class="gpfl-table"><thead><tr><th>Player</th><th class="num">Count</th></tr></thead><tbody>
            ${rows
              .map(
                (r) => `<tr>
                  <td><button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(
                    r.player_id
                  )}">${esc(r.player_name || r.player_id)}</button></td>
                  <td class="num">${esc(r.transfers ?? 0)}</td>
                </tr>`
              )
              .join("")}
          </tbody></table>`
        : `<p class="gpfl-muted">None yet.</p>`);
    xferRoot.innerHTML = block("In", tin) + block("Out", tout);
    xferRoot.querySelectorAll(".gpfl-card-link").forEach((btn) => {
      btn.onclick = () => openPlayerCard(btn.dataset.id);
    });
  }
}

async function refresh() {
  const data = await loadEntry();
  if (!data) return;
  renderGate(data);
  renderDeadlineBanner(data);
  fillMonthSelects();
  if (data.joined) {
    state.formationId = data.entry?.formation_id || state.formationId || DEFAULT_FORMATION_ID;
    const fromServer = seedSlotMapFromSquad(data.squad);
    state.slotMap = Object.keys(fromServer).length ? fromServer : state.slotMap;
    state.benchOrder = seedBenchFromSquad(data.squad, state.slotMap);
    renderEntryStats(data);
    renderChips(data);
    fillFormationSelect(data);
    renderPitchAndXi(data);
    renderSquad(data);
    renderMonthScores(data);
    renderPosTabs();
    await loadPool();
    await loadBoard();
  }
  await loadContent();
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
    const active = (state.payload?.squad || []).filter((p) => p.slot_status === "active");
    const need = Number(state.payload?.settings?.squad_size ?? 15);
    if (active.length < need) {
      setStatus(
        `Confirm needs a full ${need}-man squad — you have ${active.length}. Keep using Add until you reach ${need}.`,
        false
      );
      return;
    }
    setStatus("Confirming…");
    const { error } = await supabase.rpc("gpfl_confirm_squad");
    if (error) return setStatus(patchMissingHint(error), false);
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
    const starters = new Set(Object.values(slotMap));
    const benchIds = state.benchOrder.filter((id) => id && !starters.has(id));
    setStatus("Saving formation XI + bench…");
    const { data, error } = await supabase.rpc("gpfl_set_xi", {
      p_formation_id: formationId,
      p_slot_map: slotMap,
      p_captain_id: cap,
      p_bench_ids: benchIds,
    });
    if (error) return setStatus(patchMissingHint(error), false);
    state.formationId = formationId;
    state.slotMap = { ...slotMap };
    state.benchOrder = benchIds;
    if (data) state.payload = data;
    await refresh();
    setStatus("Formation XI + bench saved.");
  });

  document.getElementById("gpflSearchBtn")?.addEventListener("click", () => loadPool());
  document.getElementById("gpflSearch")?.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") loadPool();
  });
  document.getElementById("gpflDivFilter")?.addEventListener("change", () => loadPool());
  document.getElementById("gpflContentRefresh")?.addEventListener("click", () => loadContent());
  document.getElementById("gpflContentMonth")?.addEventListener("change", () => loadContent());

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

  document.getElementById("gpflRebaseBudgetBtn")?.addEventListener("click", async () => {
    setStatus("Rebasing GPFL banks…");
    const { data, error } = await supabase.rpc("gpfl_rebase_entry_budgets", {
      p_gpfl_season_id: null,
    });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus(
      `Rebased ${data?.entries_updated ?? 0} entries to ₿${Number(data?.budget_cap || 0).toLocaleString("en-GB")}.`
    );
  });

  document.getElementById("gpflRefreshProvBtn")?.addEventListener("click", async () => {
    const month =
      document.getElementById("gpflScoreMonth")?.value ||
      state.payload?.target_month ||
      null;
    setStatus(`Refreshing provisional (${month})…`);
    const { data, error } = await supabase.rpc("gpfl_refresh_provisional", {
      p_gpsl_month: month,
      p_gpfl_season_id: null,
    });
    if (error) return setStatus(patchMissingHint(error), false);
    await refresh();
    setStatus(`Provisional updated for ${monthLabel(month)} (${data?.entries_updated ?? 0} entries).`);
  });

  document.getElementById("gpflScoreBtn")?.addEventListener("click", async () => {
    const month = document.getElementById("gpflScoreMonth")?.value;
    setStatus(`Scoring ${month}…`);
    const { data, error } = await supabase.rpc("gpfl_score_month", {
      p_gpsl_month: month,
      p_gpfl_season_id: null,
    });
    if (error) return setStatus(patchMissingHint(error), false);
    await refresh();
    setStatus(`Scored ${month}: ${data?.entries_scored ?? 0} entries.`);
  });
}

async function main() {
  await initGlobal();
  state.isAdmin = await resolveAdmin();
  const adminPanel = document.getElementById("gpflAdminPanel");
  if (adminPanel) adminPanel.hidden = !state.isAdmin;
  fillMonthSelects();
  wire();
  await refresh();
}

main().catch((err) => setStatus(err?.message || String(err), false));
