import { supabase, initGlobal } from "./global.js";
import { GPSL_MONTH_LABELS } from "./competition.js";
import {
  FORMATION_LIST,
  FORMATION_GROUP_ORDER,
  DEFAULT_FORMATION_ID,
  getFormation,
} from "./matchday_formations.js";
import {
  pesdbPlayerCardUrl,
  pesdbPlayerUrl,
  gpslPlayerCareerUrl,
  PESDB_FALLBACK_CARD_IMG,
} from "./player_links.js";

/** Pitch / squad display order (GKs are their own section, not defenders). */
const POS_ORDER = [
  "GK",
  "LB",
  "CB",
  "RB",
  "DMF",
  "LMF",
  "CMF",
  "RMF",
  "AMF",
  "LWF",
  "SS",
  "RWF",
  "CF",
];

const POOL_SECTIONS = [
  { id: "gk", label: "Goalkeepers", group: "gk", positions: ["GK"] },
  { id: "def", label: "Defenders", group: "def", positions: ["LB", "CB", "RB"] },
  { id: "mid", label: "Midfielders", group: "mid", positions: ["DMF", "LMF", "CMF", "RMF", "AMF"] },
  { id: "fwd", label: "Forwards", group: "fwd", positions: ["LWF", "SS", "RWF", "CF"] },
];

let state = {
  isAdmin: false,
  payload: null,
  poolByGroup: {},
  poolOpen: {},
  formationId: DEFAULT_FORMATION_ID,
  slotMap: {},
  benchOrder: [],
  cardContext: null, // { playerId, canSign }
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
  if (p === "CB1" || p === "CB2" || p === "CB3") return "CB";
  return p;
}

function posRank(pos) {
  const p = normalizePos(pos);
  const i = POS_ORDER.indexOf(p);
  return i < 0 ? 99 : i;
}

function sortPlayersByPos(list) {
  return [...(list || [])].sort((a, b) => {
    const d = posRank(a.position) - posRank(b.position);
    if (d) return d;
    return String(a.player_name || "").localeCompare(String(b.player_name || ""));
  });
}

/** GPFL position flex — which native positions can fill a pitch slot. */
function posFitsSlot(playerPos, requiredPos) {
  const p = normalizePos(playerPos);
  const s = normalizePos(requiredPos);
  if (!p || !s) return false;
  if (p === s) return true;

  // GK only as GK
  if (p === "GK" || s === "GK") return false;

  // Attackers: RWF / LWF / CF / SS ↔ any of those
  const attack = new Set(["RWF", "LWF", "CF", "SS"]);
  if (attack.has(p) && attack.has(s)) return true;

  // Advanced mids: LMF / RMF / CMF / AMF ↔ any of those
  const mid = new Set(["LMF", "RMF", "CMF", "AMF"]);
  if (mid.has(p) && mid.has(s)) return true;

  // Full-backs + CB: LB / RB / CB ↔ any of those
  const back = new Set(["LB", "RB", "CB"]);
  if (back.has(p) && back.has(s)) return true;

  // DMF ↔ CB (and DMF exact already handled)
  if (p === "DMF" && s === "CB") return true;
  if (p === "CB" && s === "DMF") return true;

  // Wide mids can also cover full-back
  if ((p === "LMF" || p === "RMF") && (s === "LB" || s === "RB")) return true;

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

function playerById(squad, id) {
  return (squad || []).find((p) => p.player_id === id);
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
  document
    .querySelectorAll(
      "#gpflConfirmBtn, #gpflSaveXiBtn, #gpflFormation, #gpflCaptain, .gpfl-rm, .gpfl-chip-btn, .gpfl-bench-move, .gpfl-pitch-pick, .gpfl-sign-btn"
    )
    .forEach((el) => {
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
    <div class="gpfl-stat">Budget <b>${money(remaining)}</b></div>
    <div class="gpfl-stat">Points <b>${esc(e.total_points ?? 0)}</b></div>
    ${
      prov.month || Number(prov.points) > 0
        ? `<div class="gpfl-stat">Provisional <b>${esc(prov.points ?? 0)}</b></div>`
        : ""
    }
    <div class="gpfl-stat">Free transfers <b>${esc(e.free_transfers_remaining ?? 0)}</b></div>
    <div class="gpfl-stat">Hit cost <b>${esc(hitPts)}</b></div>
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
    root.innerHTML = "";
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
      const stateLabel = !enabled
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

/**
 * Prefer saved pitch_slot; otherwise seat is_starter players into matching empty slots.
 */
function hydrateSlotMap(squad, formationId) {
  const formation = getFormation(formationId);
  const next = {};
  const active = (squad || []).filter((p) => p.slot_status === "active");

  for (const p of active) {
    if (p.pitch_slot && p.is_starter) next[p.pitch_slot] = p.player_id;
  }

  const used = new Set(Object.values(next));
  const starters = active.filter((p) => p.is_starter && !used.has(p.player_id));

  for (const slot of formation.slots) {
    if (next[slot.id]) continue;
    const idx = starters.findIndex((p) => posFitsSlot(p.position, slot.label));
    if (idx < 0) continue;
    next[slot.id] = starters[idx].player_id;
    used.add(starters[idx].player_id);
    starters.splice(idx, 1);
  }
  return next;
}

function seedBenchFromSquad(squad, slotMap) {
  const starters = new Set(Object.values(slotMap || {}).filter(Boolean));
  return (squad || [])
    .filter((p) => p.slot_status === "active" && !starters.has(p.player_id))
    .sort(
      (a, b) =>
        (a.bench_order ?? 99) - (b.bench_order ?? 99) ||
        posRank(a.position) - posRank(b.position) ||
        String(a.player_name || "").localeCompare(String(b.player_name || ""))
    )
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
    state.slotMap = hydrateSlotMap(state.payload?.squad, next);
    state.benchOrder = seedBenchFromSquad(state.payload?.squad, state.slotMap);
    renderPitchBench(state.payload);
  };
}

function renderPitchBench(data) {
  const pitchRoot = document.getElementById("gpflPitch");
  const benchRoot = document.getElementById("gpflBench");
  const capSel = document.getElementById("gpflCaptain");
  if (!pitchRoot || !benchRoot) return;

  const squad = (data?.squad || []).filter((p) => p.slot_status === "active");
  const formation = getFormation(state.formationId);
  const open = editingOpen(data);

  if (!Object.keys(state.slotMap).length) {
    state.slotMap = hydrateSlotMap(squad, state.formationId);
  }

  const used = new Set(Object.values(state.slotMap).filter(Boolean));
  const prevCap = capSel?.value || "";

  pitchRoot.innerHTML = formation.slots
    .map((slot) => {
      const selected = state.slotMap[slot.id] || "";
      const eligible = sortPlayersByPos(
        squad.filter((p) => posFitsSlot(p.position, slot.label) || p.player_id === selected)
      );
      const options = [
        `<option value="">— ${esc(slot.label)} —</option>`,
        ...eligible.map((p) => {
          const taken = used.has(p.player_id) && state.slotMap[slot.id] !== p.player_id;
          return `<option value="${esc(p.player_id)}" ${
            selected === p.player_id ? "selected" : ""
          } ${taken ? "disabled" : ""}>${esc(p.player_name)} (${esc(normalizePos(p.position))})${
            taken ? " · used" : ""
          }</option>`;
        }),
      ];
      const isCap = selected && (prevCap === selected || playerById(squad, selected)?.is_captain);
      const thumb = selected
        ? `<img class="gpfl-pitch-thumb" src="${pesdbPlayerCardUrl(selected)}" alt="" loading="lazy" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">`
        : `<div class="gpfl-pitch-thumb gpfl-pitch-thumb--empty"></div>`;
      return `<div class="gpfl-pitch-slot ${selected ? "filled" : ""} ${isCap ? "captain" : ""}"
        style="left:${slot.x}%;top:${slot.y}%;">
        <div class="gpfl-pitch-pos">${esc(slot.label)}</div>
        ${thumb}
        <select class="gpfl-pitch-pick" data-slot="${esc(slot.id)}" title="${esc(slot.label)}" ${
          open ? "" : "disabled"
        }>${options.join("")}</select>
      </div>`;
    })
    .join("");

  pitchRoot.querySelectorAll(".gpfl-pitch-pick").forEach((sel) => {
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
      renderPitchBench(state.payload);
    };
  });

  // Captain options from current XI
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
    capSel.onchange = () => renderPitchBench(state.payload);
  }

  // Bench
  let order = state.benchOrder.filter((id) => !starterIds.includes(id));
  const missing = squad
    .filter((p) => !starterIds.includes(p.player_id) && !order.includes(p.player_id))
    .map((p) => p.player_id);
  order = [...order, ...missing];
  state.benchOrder = order;

  if (!order.length) {
    benchRoot.innerHTML = `<p class="gpfl-muted">Players not in the XI appear here as ordered subs.</p>`;
    return;
  }

  benchRoot.innerHTML = `<ol class="gpfl-bench-list">
    ${order
      .map((id, i) => {
        const p = playerById(squad, id);
        if (!p) return "";
        return `<li class="gpfl-bench-item">
          <span class="gpfl-bench-rank">${i + 1}</span>
          <img class="gpfl-bench-thumb" src="${pesdbPlayerCardUrl(id)}" alt="" loading="lazy" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">
          <div class="gpfl-bench-meta">
            <button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(id)}">${esc(
              p.player_name || id
            )}</button>
            <span class="gpfl-muted">${esc(normalizePos(p.position) || p.position_group || "")}</span>
          </div>
          <span class="gpfl-bench-actions">
            <button type="button" class="gpfl-btn gpfl-bench-move" data-dir="-1" data-id="${esc(id)}" ${
              i === 0 || !open ? "disabled" : ""
            }>↑</button>
            <button type="button" class="gpfl-btn gpfl-bench-move" data-dir="1" data-id="${esc(id)}" ${
              i === order.length - 1 || !open ? "disabled" : ""
            }>↓</button>
          </span>
        </li>`;
      })
      .join("")}
  </ol>`;

  benchRoot.querySelectorAll(".gpfl-bench-move").forEach((btn) => {
    btn.onclick = () => {
      const id = btn.dataset.id;
      const dir = Number(btn.dataset.dir);
      const idx = state.benchOrder.indexOf(id);
      const j = idx + dir;
      if (idx < 0 || j < 0 || j >= state.benchOrder.length) return;
      const next = [...state.benchOrder];
      [next[idx], next[j]] = [next[j], next[idx]];
      state.benchOrder = next;
      renderPitchBench(state.payload);
    };
  });
  benchRoot.querySelectorAll(".gpfl-card-link").forEach((btn) => {
    btn.onclick = () => openPlayerCard(btn.dataset.id, { canSign: false });
  });
}

function renderSquad(data) {
  const root = document.getElementById("gpflSquad");
  const squad = data.squad || [];
  if (!squad.length) {
    root.innerHTML = `<p class="gpfl-muted">Empty squad — expand the pool and sign players.</p>`;
    return;
  }

  const sections = [
    { id: "gk", label: "Goalkeepers", group: "gk" },
    { id: "def", label: "Defenders", group: "def" },
    { id: "mid", label: "Midfielders", group: "mid" },
    { id: "fwd", label: "Forwards", group: "fwd" },
  ];

  const open = editingOpen(data);
  const blocks = sections
    .map((sec) => {
      const rows = sortPlayersByPos(
        squad.filter((p) => String(p.position_group || "").toLowerCase() === sec.group)
      );
      if (!rows.length) {
        return `<div class="gpfl-squad-sec"><h3 class="gpfl-subhead">${esc(sec.label)}</h3>
          <p class="gpfl-muted">None yet.</p></div>`;
      }
      return `<div class="gpfl-squad-sec">
        <h3 class="gpfl-subhead">${esc(sec.label)} <span class="gpfl-muted">(${rows.length})</span></h3>
        <table class="gpfl-table">
          <thead><tr><th></th><th>Player</th><th>Pos</th><th>Club</th><th class="num">Paid</th><th></th></tr></thead>
          <tbody>
            ${rows
              .map((p) => {
                const fa = p.slot_status === "needs_replace";
                const role = p.is_starter
                  ? p.pitch_slot || "XI"
                  : p.bench_order
                    ? `B${p.bench_order}`
                    : "Bench";
                return `<tr class="${fa ? "needs-replace" : ""}">
                  <td><img class="gpfl-mini-thumb" src="${pesdbPlayerCardUrl(p.player_id)}" alt="" loading="lazy" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'"></td>
                  <td>
                    <button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(
                      p.player_id
                    )}">${esc(p.player_name || p.player_id)}</button>
                    ${fa ? `<span class="gpfl-badge gpfl-badge--fa">FA</span>` : ""}
                    ${p.is_captain ? `<span class="gpfl-badge gpfl-badge--c">C</span>` : ""}
                    <span class="gpfl-badge">${esc(role)}</span>
                  </td>
                  <td>${esc(normalizePos(p.position) || "—")}</td>
                  <td>${esc(p.club_name || p.club_short_name || "—")}</td>
                  <td class="num">${moneyNum(p.purchase_price)}</td>
                  <td><button type="button" class="gpfl-btn gpfl-rm" data-id="${esc(p.player_id)}" ${
                    open ? "" : "disabled"
                  }>${fa ? "Clear" : "Sell"}</button></td>
                </tr>`;
              })
              .join("")}
          </tbody>
        </table>
      </div>`;
    })
    .join("");

  root.innerHTML = blocks;

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
    btn.onclick = () => openPlayerCard(btn.dataset.id, { canSign: false });
  });
}

function fdrClass(fdr) {
  const n = Number(fdr) || 3;
  return `gpfl-fdr gpfl-fdr--${Math.min(5, Math.max(1, n))}`;
}

function renderPoolShell() {
  const root = document.getElementById("gpflPool");
  if (!root) return;
  root.innerHTML = POOL_SECTIONS.map((sec) => {
    const open = Boolean(state.poolOpen[sec.id]);
    const cached = state.poolByGroup[sec.id];
    return `<details class="gpfl-acc" data-sec="${esc(sec.id)}" ${open ? "open" : ""}>
      <summary>
        <span class="gpfl-acc-label">${esc(sec.label)}</span>
        <span class="gpfl-acc-pos gpfl-muted">${esc(sec.positions.join(" · "))}</span>
      </summary>
      <div class="gpfl-acc-body" id="gpflPoolBody-${esc(sec.id)}">
        ${
          cached
            ? renderPoolRowsHtml(sec, cached)
            : `<p class="gpfl-muted">Loading…</p>`
        }
      </div>
    </details>`;
  }).join("");

  root.querySelectorAll("details.gpfl-acc").forEach((det) => {
    det.addEventListener("toggle", async () => {
      const id = det.dataset.sec;
      state.poolOpen[id] = det.open;
      if (det.open) await ensurePoolGroup(id);
    });
  });
  wirePoolRows(root);
}

function renderPoolRowsHtml(sec, payload) {
  let players = payload?.players || [];
  const q = String(document.getElementById("gpflSearch")?.value || "")
    .trim()
    .toLowerCase();
  if (q) {
    players = players.filter((p) =>
      [p.player_name, p.club_name, p.club_short_name, p.owner_name, p.position]
        .join(" ")
        .toLowerCase()
        .includes(q)
    );
  }
  players = [...players].sort(
    (a, b) =>
      Number(b.price ?? 0) - Number(a.price ?? 0) ||
      posRank(a.position) - posRank(b.position) ||
      String(a.player_name || "").localeCompare(String(b.player_name || ""))
  );

  // Sub-group by exact position within section (keep price order within each)
  const byPos = {};
  for (const pos of sec.positions) byPos[pos] = [];
  const other = [];
  for (const p of players) {
    const pos = normalizePos(p.position);
    if (byPos[pos]) byPos[pos].push(p);
    else other.push(p);
  }

  const chunks = [...sec.positions, ...(other.length ? ["OTHER"] : [])]
    .map((pos) => {
      const list = pos === "OTHER" ? other : byPos[pos] || [];
      if (!list.length) return "";
      return `<div class="gpfl-pool-pos">
        <div class="gpfl-pool-pos-label">${esc(pos === "OTHER" ? "Other" : pos)} · ${list.length}</div>
        <ul class="gpfl-pool-list">
          ${list
            .map(
              (p) => `<li>
                <button type="button" class="gpfl-pool-row" data-id="${esc(p.player_id)}" data-sign="1">
                  <img src="${pesdbPlayerCardUrl(p.player_id)}" alt="" loading="lazy" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">
                  <span class="gpfl-pool-row-main">
                    <b>${esc(p.player_name)}</b>
                    <span class="gpfl-muted">${esc(p.club_name || p.club_short_name || "")} · ${esc(
                      p.owner_name || "—"
                    )}</span>
                  </span>
                  <span class="gpfl-pool-row-meta">
                    <span>${esc(p.ownership_pct ?? "—")}%</span>
                    <span>${moneyNum(p.price)}</span>
                  </span>
                </button>
              </li>`
            )
            .join("")}
        </ul>
      </div>`;
    })
    .join("");

  if (!chunks) {
    return `<p class="gpfl-muted">No players in this group${q ? " for this filter" : ""}.</p>`;
  }
  return `<p class="gpfl-muted" style="margin:0 0 8px;">${esc(payload.total ?? players.length)} in group · click a player for profile &amp; sign</p>${chunks}`;
}

function wirePoolRows(root) {
  root.querySelectorAll(".gpfl-pool-row").forEach((btn) => {
    btn.onclick = () =>
      openPlayerCard(btn.dataset.id, { canSign: btn.dataset.sign === "1" && editingOpen() });
  });
}

async function ensurePoolGroup(secId) {
  const sec = POOL_SECTIONS.find((s) => s.id === secId);
  if (!sec) return;
  const body = document.getElementById(`gpflPoolBody-${secId}`);
  if (!body) return;

  const div = document.getElementById("gpflDivFilter")?.value || null;
  body.innerHTML = `<p class="gpfl-muted">Loading…</p>`;

  const { data, error } = await supabase.rpc("gpfl_list_players", {
    p_position_group: sec.group,
    p_division: div || null,
    p_club: null,
    p_search: null,
    p_max_price: null,
    p_limit: 200,
    p_offset: 0,
  });

  if (error) {
    body.innerHTML = `<p class="gpfl-muted">${esc(patchMissingHint(error))}</p>`;
    return;
  }
  state.poolByGroup[secId] = data;
  body.innerHTML = renderPoolRowsHtml(sec, data);
  wirePoolRows(body);
}

function refreshOpenPoolBodies() {
  for (const sec of POOL_SECTIONS) {
    if (!state.poolOpen[sec.id]) continue;
    const body = document.getElementById(`gpflPoolBody-${sec.id}`);
    const cached = state.poolByGroup[sec.id];
    if (body && cached) {
      body.innerHTML = renderPoolRowsHtml(sec, cached);
      wirePoolRows(body);
    }
  }
}

async function openPlayerCard(playerId, { canSign = false } = {}) {
  const dlg = document.getElementById("gpflCardDialog");
  const body = document.getElementById("gpflCardBody");
  const title = document.getElementById("gpflCardTitle");
  if (!dlg || !body) return;
  state.cardContext = { playerId, canSign };
  title.textContent = "Loading…";
  body.innerHTML = `<p class="gpfl-muted">Fetching profile…</p>`;
  dlg.showModal();

  const [cardRes, careerRes] = await Promise.all([
    supabase.rpc("gpfl_player_card", { p_player_id: playerId }),
    supabase.rpc("competition_player_career_bundle", { p_player_id: playerId }),
  ]);

  const data = cardRes.data;
  if (cardRes.error || !data?.ok) {
    title.textContent = "Player";
    body.innerHTML = `<p class="gpfl-muted">${esc(
      patchMissingHint(cardRes.error || data?.reason)
    )}</p>`;
    return;
  }

  title.textContent = data.player_name || playerId;
  const career = careerRes.data || {};
  const stints = career.stints || [];
  const transfers = career.transfers || [];
  const totals = career.totals || {};

  const form = (data.form || [])
    .map(
      (f) =>
        `<span class="gpfl-form-chip">${esc(monthLabel(f.gpsl_month))}: <b>${esc(f.points)}</b></span>`
    )
    .join("") || `<span class="gpfl-muted">No scored GPFL months yet</span>`;

  const fixtures = (data.next_fixtures || [])
    .map((fx) => {
      const ha = fx.is_home ? "H" : "A";
      return `<tr>
        <td>${esc(monthLabel(fx.gpsl_month))} MD${esc(fx.matchday)}</td>
        <td>${esc(ha)} ${esc(fx.opponent_name || fx.opponent_short_name)}</td>
        <td><span class="${fdrClass(fx.fdr)}">${esc(fx.fdr ?? "—")}</span></td>
      </tr>`;
    })
    .join("");

  const stintRows = stints.length
    ? stints
        .map(
          (s) => `<tr>
            <td>${esc(s.season_label || "—")}</td>
            <td>${esc(s.club_name || s.club_short_name || "—")}</td>
            <td class="num">${esc(s.appearances ?? 0)}</td>
            <td class="num">${esc(s.goals ?? 0)}</td>
            <td class="num">${esc(s.assists ?? 0)}</td>
            <td class="num">${esc(s.avg_rating ?? "—")}</td>
            <td class="num">${esc(s.potm_awards ?? 0)}</td>
          </tr>`
        )
        .join("")
    : "";

  const xferRows = transfers.length
    ? transfers
        .slice(0, 12)
        .map(
          (t) => `<tr>
            <td>${esc(t.season_label || "—")}</td>
            <td>${esc(t.seller_club_short_name || "—")} → ${esc(
              t.buyer_club_short_name || t.foreign_buyer_name || "—"
            )}</td>
            <td class="num">${moneyNum(t.fee)}</td>
          </tr>`
        )
        .join("")
    : "";

  const alreadyIn = (state.payload?.squad || []).some(
    (p) => p.player_id === playerId && p.slot_status === "active"
  );
  const showSign = canSign && editingOpen() && !alreadyIn;

  body.innerHTML = `
    <div class="gpfl-card-hero">
      <a href="${pesdbPlayerUrl(playerId)}" target="_blank" rel="noopener" title="PESDB card">
        <img class="gpfl-card-pic" src="${pesdbPlayerCardUrl(playerId)}" alt="" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">
      </a>
      <div class="gpfl-card-meta">
        <div><span class="gpfl-muted">Club</span><b>${esc(data.club_name || data.club_short_name || "—")}</b></div>
        <div><span class="gpfl-muted">Pos</span><b>${esc(normalizePos(data.position) || data.position_group)}</b></div>
        <div><span class="gpfl-muted">GPFL price</span><b>${money(data.price)}</b></div>
        <div><span class="gpfl-muted">Owned by</span><b>${esc(data.ownership_pct ?? 0)}%</b></div>
        <div><span class="gpfl-muted">GPFL pts</span><b>${esc(data.total_points ?? 0)}</b></div>
        <div><span class="gpfl-muted">Apps / G / A</span><b>${esc(data.apps ?? 0)} / ${esc(
          data.goals ?? 0
        )} / ${esc(data.assists ?? 0)}</b></div>
        <div><span class="gpfl-muted">Career apps</span><b>${esc(totals.appearances ?? 0)}</b></div>
        <div><span class="gpfl-muted">Career G/A</span><b>${esc(totals.goals ?? 0)} / ${esc(
          totals.assists ?? 0
        )}</b></div>
      </div>
    </div>
    <div class="gpfl-card-actions">
      ${
        showSign
          ? `<button type="button" class="gpfl-btn gpfl-btn--gold gpfl-sign-btn" data-id="${esc(
              playerId
            )}">Sign to squad</button>`
          : alreadyIn
            ? `<span class="gpfl-badge">In your squad</span>`
            : ""
      }
      <a class="gpfl-btn" href="${gpslPlayerCareerUrl(playerId)}" target="_blank" rel="noopener">Full GPSL career</a>
      <a class="gpfl-btn" href="${pesdbPlayerUrl(playerId)}" target="_blank" rel="noopener">PESDB</a>
    </div>
    <h3 class="gpfl-subhead">GPFL form</h3>
    <div class="gpfl-form-row">${form}</div>
    <h3 class="gpfl-subhead">Next fixtures · FDR</h3>
    ${
      fixtures
        ? `<table class="gpfl-table"><thead><tr><th>When</th><th>Opp</th><th>FDR</th></tr></thead><tbody>${fixtures}</tbody></table>`
        : `<p class="gpfl-muted">No upcoming fixtures.</p>`
    }
    <h3 class="gpfl-subhead">GPSL club history (by season)</h3>
    ${
      stintRows
        ? `<table class="gpfl-table">
            <thead><tr><th>Season</th><th>Club</th><th class="num">Apps</th><th class="num">G</th><th class="num">A</th><th class="num">Avg</th><th class="num">POTM</th></tr></thead>
            <tbody>${stintRows}</tbody>
          </table>
          <p class="gpfl-muted" style="margin-top:6px;">Stats while at each GPSL club / owner spell.</p>`
        : `<p class="gpfl-muted">No GPSL match history yet.</p>`
    }
    ${
      xferRows
        ? `<h3 class="gpfl-subhead">Transfer history</h3>
           <table class="gpfl-table">
             <thead><tr><th>Season</th><th>Move</th><th class="num">Fee</th></tr></thead>
             <tbody>${xferRows}</tbody>
           </table>`
        : ""
    }
  `;

  body.querySelector(".gpfl-sign-btn")?.addEventListener("click", async () => {
    await signPlayer(playerId);
    dlg.close();
  });
}

async function signPlayer(playerId) {
  const { caps, have } = slotCounts(state.payload || {});
  const poolHit = Object.values(state.poolByGroup)
    .flatMap((g) => g?.players || [])
    .find((p) => p.player_id === playerId);
  const g = String(poolHit?.position_group || "").toLowerCase();
  if (g && caps[g] != null && have[g] >= caps[g]) {
    setStatus(
      `No ${g.toUpperCase()} slots left (${have[g]}/${caps[g]}). Sell one first.`,
      false
    );
    return;
  }
  const free = Number(state.payload?.entry?.free_transfers_remaining ?? 0);
  const status = state.payload?.entry?.status;
  const hit = Number(state.payload?.transfer_hit_points ?? -4);
  if (status === "active" && free <= 0) {
    if (!confirm(`No free transfers left. This transfer costs ${hit} points. Continue?`)) {
      return;
    }
  }
  setStatus("Signing…");
  const { data: next, error } = await supabase.rpc("gpfl_add_player", {
    p_player_id: playerId,
  });
  if (error) return setStatus(patchMissingHint(error), false);
  if (next) state.payload = next;
  state.poolByGroup = {};
  await refresh();
  setStatus("Signed.");
}

function renderMonthScores(data) {
  const root = document.getElementById("gpflMonthScores");
  if (!root) return;
  const rows = data?.month_points || [];
  if (!rows.length) {
    root.innerHTML = `<p class="gpfl-muted">No month scores yet.</p>`;
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
    dreamRoot.innerHTML = `<p class="gpfl-muted">No dream team yet for ${esc(monthLabel(month))}.</p>`;
  } else {
    const players = dream.data.players || [];
    dreamRoot.innerHTML = `<p class="gpfl-muted" style="margin:0 0 8px;">Total ${esc(
      dream.data.total_points
    )} pts</p>
      <table class="gpfl-table">
        <thead><tr><th></th><th>Player</th><th>Pos</th><th>Own%</th><th class="num">Pts</th></tr></thead>
        <tbody>
          ${players
            .map(
              (p) => `<tr>
                <td><img class="gpfl-mini-thumb" src="${pesdbPlayerCardUrl(p.player_id)}" alt="" loading="lazy" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'"></td>
                <td><button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(
                  p.player_id
                )}">${esc(p.player_name)}</button></td>
                <td>${esc(normalizePos(p.position) || p.position_group)}</td>
                <td class="num">${esc(p.ownership_pct ?? "—")}</td>
                <td class="num">${esc(p.points)}</td>
              </tr>`
            )
            .join("")}
        </tbody>
      </table>`;
    dreamRoot.querySelectorAll(".gpfl-card-link").forEach((btn) => {
      btn.onclick = () => openPlayerCard(btn.dataset.id, { canSign: false });
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
      btn.onclick = () => openPlayerCard(btn.dataset.id, { canSign: false });
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
    state.slotMap = hydrateSlotMap(data.squad, state.formationId);
    state.benchOrder = seedBenchFromSquad(data.squad, state.slotMap);
    renderEntryStats(data);
    renderChips(data);
    fillFormationSelect(data);
    renderPitchBench(data);
    renderSquad(data);
    renderMonthScores(data);
    renderPoolShell();
    // Prefetch nothing — accordion loads on open
    for (const id of Object.keys(state.poolOpen)) {
      if (state.poolOpen[id]) await ensurePoolGroup(id);
    }
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
      setStatus(`Confirm needs a full ${need}-man squad — you have ${active.length}.`, false);
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
        setStatus(`Fill ${slot.label} (${slot.id}) before saving.`, false);
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
    setStatus("Saving pitch XI + bench…");
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
    setStatus("Pitch XI + bench saved.");
  });

  let searchTimer = null;
  document.getElementById("gpflSearch")?.addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => refreshOpenPoolBodies(), 200);
  });
  document.getElementById("gpflDivFilter")?.addEventListener("change", async () => {
    state.poolByGroup = {};
    for (const id of Object.keys(state.poolOpen)) {
      if (state.poolOpen[id]) await ensurePoolGroup(id);
    }
  });
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

  document.getElementById("gpflResetSeasonBtn")?.addEventListener("click", async () => {
    const typed = prompt(
      "This deletes ALL GPFL entries, squads, transfers and month scores for the current season.\nPrices stay. Type RESET GPFL to confirm:"
    );
    if (typed == null) return;
    if (String(typed).trim().toUpperCase() !== "RESET GPFL") {
      setStatus("Reset cancelled — confirmation text did not match.", false);
      return;
    }
    setStatus("Resetting GPFL entries…");
    const { data, error } = await supabase.rpc("admin_gpfl_reset_season", {
      p_gpfl_season_id: null,
      p_confirm: "RESET GPFL",
    });
    if (error) {
      return setStatus(
        patchMissingHint(error) ||
          "Reset failed — run supabase/sql/patches/gpfl_admin_reset_season_20260818.sql first.",
        false
      );
    }
    state.poolByGroup = {};
    await refresh();
    setStatus(
      `GPFL reset: ${data?.entries_deleted ?? 0} entries removed. Owners must join again.`
    );
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
