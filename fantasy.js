import { supabase, initGlobal } from "./global.js";
import { GPSL_MONTH_LABELS, formatMoney } from "./competition.js";
import {
  pesdbPlayerCardUrl,
  pesdbPlayerUrl,
  gpslPlayerCareerUrl,
  PESDB_FALLBACK_CARD_IMG,
} from "./player_links.js";
import { initGpslInfoTips, tipAttrs } from "./gpsl_info_tips.js";
import { GPFL_TIPS } from "./fantasy_info_tips.js?v=20260823-even-ladder";
import { ownerProfileHref } from "./owner_badge.js";

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
  {
    id: "mid",
    label: "Midfielders",
    group: "mid",
    positions: ["DMF", "LMF", "CMF", "RMF", "AMF", "LWF", "RWF"],
  },
  { id: "fwd", label: "Forwards", group: "fwd", positions: ["SS", "CF"] },
];

const XI_RULES = {
  // y% matches pitch markings: halfway≈2%, penalty top≈65%, goal≈97%
  gk: { min: 1, max: 1, label: "GK", y: 90 },
  def: { min: 3, max: 5, label: "DEF", y: 65 },
  mid: { min: 2, max: 5, label: "MID", y: 36 },
  fwd: { min: 1, max: 3, label: "FWD", y: 10 },
};

const BANK_ORDER = ["fwd", "mid", "def", "gk"]; // paint top → bottom

let state = {
  isAdmin: false,
  payload: null,
  poolByGroup: {},
  poolOpen: {},
  banks: { gk: [], def: [], mid: [], fwd: [] },
  banksTouched: false,
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

/** Clickable owner name → owner_profile.html (falls back to plain text). */
function ownerLinkHtml(ownerId, label, { stopPool = false } = {}) {
  const name = esc(label || "—");
  const href = ownerProfileHref(ownerId);
  if (!href) return name;
  const stop = stopPool ? ' data-owner-link="1"' : "";
  return `<a class="gpsl-link gpfl-owner-link" href="${esc(href)}"${stop}>${name}</a>`;
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

function statusLabel(status) {
  const s = String(status || "").toLowerCase();
  if (s === "building") return "Building";
  if (s === "active") return "Active";
  if (s === "withdrawn") return "Withdrawn";
  return s ? s.replace(/_/g, " ") : "—";
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

/** Squad bank from card position (DMF/LWF/RWF → mid). */
function cardBankGroup(pos) {
  const p = normalizePos(pos);
  if (p === "GK") return "gk";
  if (p === "LB" || p === "CB" || p === "RB" || p === "LWB" || p === "RWB") return "def";
  if (p === "SS" || p === "CF") return "fwd";
  if (
    p === "DMF" ||
    p === "CMF" ||
    p === "AMF" ||
    p === "LMF" ||
    p === "RMF" ||
    p === "LWF" ||
    p === "RWF"
  ) {
    return "mid";
  }
  return "mid";
}

function playerBankGroup(p) {
  const g = String(p?.position_group || "").toLowerCase();
  if (g === "gk" || g === "def" || g === "mid" || g === "fwd") return g;
  return cardBankGroup(p?.position);
}

function emptyBanks() {
  return { gk: [], def: [], mid: [], fwd: [] };
}

function starterIdsFromBanks(banks = state.banks) {
  return new Set(
    ["gk", "def", "mid", "fwd"].flatMap((g) => banks?.[g] || []).filter(Boolean)
  );
}

function bankCounts(banks = state.banks) {
  return {
    gk: (banks.gk || []).length,
    def: (banks.def || []).length,
    mid: (banks.mid || []).length,
    fwd: (banks.fwd || []).length,
  };
}

function xiShapeLabel(banks = state.banks) {
  const c = bankCounts(banks);
  const total = c.gk + c.def + c.mid + c.fwd;
  return `${c.gk}-${c.def}-${c.mid}-${c.fwd} (${total}/11)`;
}

function xiBanksValid(banks = state.banks) {
  const c = bankCounts(banks);
  return (
    c.gk === 1 &&
    c.def >= 3 &&
    c.def <= 5 &&
    c.mid >= 2 &&
    c.mid <= 5 &&
    c.fwd >= 1 &&
    c.fwd <= 3 &&
    c.gk + c.def + c.mid + c.fwd === 11
  );
}

/** Left–right balance on a bank line (1–5). */
function lineXPercents(n) {
  const count = Math.max(0, Math.min(5, Number(n) || 0));
  if (count <= 0) return [];
  if (count === 1) return [50];
  if (count === 2) return [34, 66];
  if (count === 3) return [25, 50, 75];
  if (count === 4) return [16, 38, 62, 84];
  return [12, 31, 50, 69, 88];
}

function sortIdsByPos(squad, ids) {
  const byId = new Map((squad || []).map((p) => [p.player_id, p]));
  return [...(ids || [])]
    .filter((id) => byId.has(id))
    .sort((a, b) => {
      const pa = byId.get(a);
      const pb = byId.get(b);
      const d = posRank(pa.position) - posRank(pb.position);
      if (d) return d;
      return String(pa.player_name || "").localeCompare(String(pb.player_name || ""));
    });
}

function hydrateBanks(squad, serverBanks) {
  const next = emptyBanks();
  const active = (squad || []).filter((p) => p.slot_status === "active");
  const byId = new Map(active.map((p) => [p.player_id, p]));

  const fromServer = serverBanks && typeof serverBanks === "object";
  if (fromServer) {
    for (const g of ["gk", "def", "mid", "fwd"]) {
      const ids = Array.isArray(serverBanks[g]) ? serverBanks[g] : [];
      next[g] = sortIdsByPos(
        active,
        ids.filter((id) => byId.has(id) && playerBankGroup(byId.get(id)) === g)
      );
    }
  }

  // Fallback: saved starters with bank pitch_slot / group
  const used = starterIdsFromBanks(next);
  if ([...used].length === 0) {
    for (const g of ["gk", "def", "mid", "fwd"]) {
      const tagged = active
        .filter(
          (p) =>
            p.is_starter &&
            playerBankGroup(p) === g &&
            String(p.pitch_slot || "").startsWith(`${g}_`)
        )
        .sort((a, b) => String(a.pitch_slot).localeCompare(String(b.pitch_slot)));
      if (tagged.length) {
        next[g] = tagged.map((p) => p.player_id);
      } else {
        next[g] = sortPlayersByPos(
          active.filter((p) => p.is_starter && playerBankGroup(p) === g)
        ).map((p) => p.player_id);
      }
    }
  }

  // Cap to max per bank
  for (const g of ["gk", "def", "mid", "fwd"]) {
    next[g] = next[g].slice(0, XI_RULES[g].max);
  }
  return next;
}

function mergeBanks(squad, serverBanks, localBanks, keepLocal) {
  const fromServer = hydrateBanks(squad, serverBanks);
  if (!keepLocal) return fromServer;
  const active = new Set(
    (squad || []).filter((p) => p.slot_status === "active").map((p) => p.player_id)
  );
  const merged = emptyBanks();
  const used = new Set();
  for (const g of ["gk", "def", "mid", "fwd"]) {
    const preferred = (localBanks?.[g] || []).filter((id) => active.has(id) && !used.has(id));
    const fallback = (fromServer[g] || []).filter((id) => active.has(id) && !used.has(id));
    const ids = [];
    for (const id of [...preferred, ...fallback]) {
      if (ids.length >= XI_RULES[g].max) break;
      if (used.has(id)) continue;
      ids.push(id);
      used.add(id);
    }
    merged[g] = sortIdsByPos(
      (squad || []).filter((p) => p.slot_status === "active"),
      ids
    );
  }
  return merged;
}

function seedBenchFromSquad(squad, banks) {
  const starters = starterIdsFromBanks(banks);
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

function mergeBenchOrder(squad, banks, prevBench) {
  const starters = starterIdsFromBanks(banks);
  const activeIds = new Set(
    (squad || []).filter((p) => p.slot_status === "active").map((p) => p.player_id)
  );
  const order = (prevBench || []).filter((id) => activeIds.has(id) && !starters.has(id));
  for (const id of seedBenchFromSquad(squad, banks)) {
    if (!order.includes(id)) order.push(id);
  }
  return order;
}

function removeFromBanks(playerId, banks = state.banks) {
  const next = emptyBanks();
  for (const g of ["gk", "def", "mid", "fwd"]) {
    next[g] = (banks[g] || []).filter((id) => id !== playerId);
  }
  return next;
}

function addToBank(playerId, group, squad, banks = state.banks) {
  const g = String(group || "").toLowerCase();
  if (!XI_RULES[g]) return { ok: false, reason: "Unknown bank" };
  const p = (squad || []).find((x) => x.player_id === playerId);
  if (!p || p.slot_status !== "active") return { ok: false, reason: "Not in squad" };
  if (playerBankGroup(p) !== g) {
    return { ok: false, reason: `${normalizePos(p.position) || "Player"} belongs on the ${playerBankGroup(p).toUpperCase()} line` };
  }
  let next = removeFromBanks(playerId, banks);
  if ((next[g] || []).length >= XI_RULES[g].max) {
    return { ok: false, reason: `${XI_RULES[g].label} line is full (max ${XI_RULES[g].max})` };
  }
  next[g] = sortIdsByPos(squad, [...(next[g] || []), playerId]);
  return { ok: true, banks: next };
}

function editingOpen(data = state.payload) {
  return data?.editing_open !== false;
}

/** Pitch XI editable whenever transfers/building are allowed (same as server assert). */
function canEditPitch(data = state.payload) {
  return canTransfer(data);
}

function setPitchDragging(on) {
  document.getElementById("gpflPitchBoard")?.classList.toggle("is-dragging", Boolean(on));
}

function readDragPlayerId(ev) {
  const dt = ev.dataTransfer;
  if (!dt) return "";
  return (
    dt.getData("text/plain") ||
    dt.getData("text") ||
    dt.getData("text/gpfl-player") ||
    ""
  ).trim();
}

function writeDragPlayerId(ev, playerId) {
  const dt = ev.dataTransfer;
  if (!dt) return;
  const id = String(playerId || "");
  // text/plain is required for reliable HTML5 DnD across Chromium/Firefox
  dt.setData("text/plain", id);
  dt.setData("text", id);
  try {
    dt.setData("text/gpfl-player", id);
  } catch (_) {
    /* ignore */
  }
  dt.effectAllowed = "move";
}

function placePlayerOnBank(playerId, group, { silent = false } = {}) {
  const squad = (state.payload?.squad || []).filter((p) => p.slot_status === "active");
  const res = addToBank(playerId, group, squad, state.banks);
  if (!res.ok) {
    if (!silent) setStatus(res.reason, false);
    return false;
  }
  state.banks = res.banks;
  state.banksTouched = true;
  state.benchOrder = mergeBenchOrder(squad, state.banks, state.benchOrder);
  renderPitchBench(state.payload);
  renderSquad(state.payload);
  if (!silent) setStatus(`Placed on ${XI_RULES[group]?.label || group} line.`);
  return true;
}

/** Initial squad build (and FA replaces) stay open even if the month deadline has locked. */
function canTransfer(data = state.payload) {
  if (!data?.joined) return false;
  const status = data?.entry?.status;
  if (status === "building") return true;
  if ((data?.squad || []).some((p) => p.slot_status === "needs_replace")) return true;
  return editingOpen(data);
}

function patchMissingHint(err) {
  const m = String(err?.message || err || "");
  if (/gpfl_set_xi|gpfl_assert_xi_banks|xi_banks/i.test(m)) {
    return m + " — run supabase/sql/patches/gpfl_banks_positions_20260823.sql in Supabase.";
  }
  if (/gpfl_prizes_board/i.test(m)) {
    return m + " — run supabase/sql/patches/gpfl_prizes_board_20260822.sql in Supabase.";
  }
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
      "#gpflConfirmBtn, #gpflSaveXiBtn, #gpflCaptain, .gpfl-rm, .gpfl-chip-btn, .gpfl-bench-move, .gpfl-pitch-off, .gpfl-sign-btn, .gpfl-pool-sign"
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
      String(e.formation_id || "") === "banks";
    const ready = active.length >= size && needs === 0 && xiReady;
    confirmBtn.disabled = !ready || !canTransfer(data);
    confirmBtn.title = !canTransfer(data)
      ? "Editing locked until month ends"
      : ready
        ? "Lock your 15-man squad for scoring"
        : `Need ${size} players, saved bank XI + captain (have ${active.length})`;
    confirmBtn.textContent = ready
      ? "Confirm squad"
      : `Confirm squad (${active.length}/${size})`;
  }
  el.innerHTML = `
    <div class="gpfl-stat"${tipAttrs(GPFL_TIPS.points)}>Total Points <b>${esc(e.total_points ?? 0)}</b></div>
    ${
      prov.month || Number(prov.points) > 0
        ? `<div class="gpfl-stat"${tipAttrs(GPFL_TIPS.provisional)}>Provisional <b>${esc(prov.points ?? 0)}</b></div>`
        : ""
    }
    <div class="gpfl-stat"${tipAttrs(GPFL_TIPS.status)}>Status <b>${esc(statusLabel(e.status))}</b></div>
    <div class="gpfl-stat"${tipAttrs(GPFL_TIPS.freeTransfers)}>Free transfers <b>${esc(e.free_transfers_remaining ?? 0)}</b></div>
    <div class="gpfl-stat"${tipAttrs(GPFL_TIPS.hitCost)}>Hit cost <b>${esc(hitPts)}</b></div>
    ${needs ? `<div class="gpfl-stat"${tipAttrs(GPFL_TIPS.faReplace)}>FA to replace <b>${needs}</b></div>` : ""}
  `;

  const capsEl = document.getElementById("gpflSignCaps");
  if (capsEl) {
    capsEl.innerHTML = `
      <div class="gpfl-stat"${tipAttrs(GPFL_TIPS.squadSize)}>Squad <b>${active.length}/${esc(size)}</b></div>
      <div class="gpfl-stat"${tipAttrs(GPFL_TIPS.slots)}>Slots <b>GK ${have.gk}/${caps.gk} · DEF ${have.def}/${caps.def} · MID ${have.mid}/${caps.mid} · FWD ${have.fwd}/${caps.fwd}</b></div>
      <div class="gpfl-stat"${tipAttrs(GPFL_TIPS.budget)}>Budget <b>${money(remaining)}</b></div>
    `;
  }
  setEditLocked(!canTransfer(data));
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
  const open = canTransfer(data);
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
      return `<div class="gpfl-chip ${active ? "gpfl-chip--active" : ""} ${!available || !enabled ? "gpfl-chip--used" : ""}"${tipAttrs(tip)}>
        <div class="gpfl-chip-name">${esc(label)}</div>
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

/** Half-pitch y% — halfway at top, goal at bottom. */
function bankTopPct(group) {
  return XI_RULES[group]?.y ?? 50;
}

function updateXiShapeHud(banks = state.banks) {
  const el = document.getElementById("gpflXiShape");
  if (!el) return;
  const ok = xiBanksValid(banks);
  el.textContent = `Shape ${xiShapeLabel(banks)}${ok ? "" : " · need GK 1 · DEF 3–5 · MID 2–5 · FWD 1–3"}`;
  el.classList.toggle("gpfl-xi-shape--bad", !ok);
}

function renderPitchBench(data) {
  const pitchRoot = document.getElementById("gpflPitchSlots");
  const benchRoot = document.getElementById("gpflBench");
  const capSel = document.getElementById("gpflCaptain");
  const pitchBoard = document.getElementById("gpflPitchBoard");
  if (!pitchRoot || !benchRoot) return;

  const squad = (data?.squad || []).filter((p) => p.slot_status === "active");
  const open = canEditPitch(data);
  const byId = new Map(squad.map((p) => [p.player_id, p]));

  for (const g of ["gk", "def", "mid", "fwd"]) {
    state.banks[g] = sortIdsByPos(squad, state.banks[g] || []);
  }
  state.benchOrder = mergeBenchOrder(squad, state.banks, state.benchOrder);
  updateXiShapeHud(state.banks);

  const starters = starterIdsFromBanks(state.banks);
  const prevCap = capSel?.value || "";
  const capId =
    (prevCap && starters.has(prevCap) && prevCap) ||
    squad.find((p) => p.is_captain && starters.has(p.player_id))?.player_id ||
    [...starters][0] ||
    "";

  pitchRoot.innerHTML = "";

  for (const g of BANK_ORDER) {
    const rule = XI_RULES[g];
    const zone = document.createElement("div");
    zone.className = `gpfl-bank-zone gpfl-bank-zone--${g}`;
    zone.dataset.bank = g;
    // Center the drop band on the player line
    zone.style.top = `${Math.max(1, rule.y - 8)}%`;
    zone.innerHTML = `<span class="gpfl-bank-zone-label">${esc(rule.label)} · ${
      (state.banks[g] || []).length
    }/${rule.max}</span>`;
    if (open) {
      zone.addEventListener("dragover", (ev) => {
        ev.preventDefault();
        ev.dataTransfer.dropEffect = "move";
        zone.classList.add("drag-over");
      });
      zone.addEventListener("dragleave", (ev) => {
        if (ev.target === zone) zone.classList.remove("drag-over");
      });
      zone.addEventListener("drop", (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        zone.classList.remove("drag-over");
        setPitchDragging(false);
        const pid = readDragPlayerId(ev);
        if (pid) placePlayerOnBank(pid, g);
      });
    }
    pitchRoot.appendChild(zone);
  }

  for (const g of BANK_ORDER) {
    const ids = state.banks[g] || [];
    const xs = lineXPercents(ids.length);
    ids.forEach((pid, i) => {
      const p = byId.get(pid);
      if (!p) return;
      const isCap = pid === capId;
      const wrap = document.createElement("div");
      wrap.className = `gpfl-pitch-slot filled${isCap ? " captain" : ""}`;
      wrap.style.left = `${xs[i] ?? 50}%`;
      wrap.style.top = `${bankTopPct(g)}%`;
      wrap.draggable = open;
      wrap.dataset.playerId = pid;
      wrap.dataset.bank = g;
      wrap.innerHTML = `
        <div class="gpfl-pitch-pos">${esc(XI_RULES[g].label)}${isCap ? " · C" : ""}</div>
        <img class="gpfl-pitch-thumb" src="${pesdbPlayerCardUrl(pid)}" alt="" loading="lazy" draggable="false" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">
        <div class="gpfl-pitch-name">${esc(p.player_name || pid)}</div>
        ${
          open
            ? `<button type="button" class="gpfl-pitch-off" data-id="${esc(pid)}" title="Send to bench">×</button>`
            : ""
        }
      `;
      if (open) {
        wrap.addEventListener("dragstart", (ev) => {
          writeDragPlayerId(ev, pid);
          wrap.classList.add("dragging");
          setPitchDragging(true);
        });
        wrap.addEventListener("dragend", () => {
          wrap.classList.remove("dragging");
          setPitchDragging(false);
        });
      }
      pitchRoot.appendChild(wrap);
    });
  }

  // Whole-pitch fallback drop (hit-test by Y → nearest bank)
  if (pitchBoard && open) {
    pitchBoard.ondragover = (ev) => {
      ev.preventDefault();
      ev.dataTransfer.dropEffect = "move";
    };
    pitchBoard.ondrop = (ev) => {
      if (ev.target?.closest?.(".gpfl-bank-zone")) return;
      ev.preventDefault();
      setPitchDragging(false);
      const pid = readDragPlayerId(ev);
      if (!pid) return;
      const p = byId.get(pid) || (state.payload?.squad || []).find((x) => x.player_id === pid);
      const g = p ? playerBankGroup(p) : null;
      if (g) placePlayerOnBank(pid, g);
    };
  }

  pitchRoot.querySelectorAll(".gpfl-pitch-off").forEach((btn) => {
    btn.onclick = (ev) => {
      ev.stopPropagation();
      state.banks = removeFromBanks(btn.dataset.id, state.banks);
      state.banksTouched = true;
      state.benchOrder = mergeBenchOrder(squad, state.banks, state.benchOrder);
      renderPitchBench(state.payload);
      renderSquad(state.payload);
    };
  });

  if (capSel) {
    const starterPlayers = sortPlayersByPos(
      [...starters].map((id) => byId.get(id)).filter(Boolean)
    );
    capSel.innerHTML =
      `<option value="">— captain —</option>` +
      starterPlayers
        .map(
          (p) =>
            `<option value="${esc(p.player_id)}" ${
              p.player_id === capId ? "selected" : ""
            }>${esc(p.player_name || p.player_id)}</option>`
        )
        .join("");
    capSel.disabled = !open || !starterPlayers.length;
    if (capId) capSel.value = capId;
    capSel.onchange = () => renderPitchBench(state.payload);
  }

  const benchIds = state.benchOrder.filter((id) => byId.has(id) && !starters.has(id));
  if (!benchIds.length) {
    benchRoot.innerHTML = `<p class="gpfl-muted">${
      squad.length
        ? open
          ? "Drag squad players onto their bank line (or use To pitch)."
          : "Pitch editing locked while the month is live."
        : "Sign players first."
    }</p>`;
  } else {
    benchRoot.innerHTML = `<ol class="gpfl-bench-list">
    ${benchIds
      .map((id, i) => {
        const p = byId.get(id);
        if (!p) return "";
        const bank = playerBankGroup(p);
        return `<li class="gpfl-bench-item" draggable="${open ? "true" : "false"}" data-id="${esc(
          id
        )}" data-bank="${esc(bank)}">
          <span class="gpfl-bench-rank">${i + 1}</span>
          <img class="gpfl-bench-thumb" src="${pesdbPlayerCardUrl(id)}" alt="" loading="lazy" draggable="false" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">
          <div class="gpfl-bench-meta">
            <button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(id)}">${esc(
              p.player_name || id
            )}</button>
            <span class="gpfl-muted">${esc(bank.toUpperCase())}</span>
            ${
              open
                ? `<button type="button" class="gpfl-btn gpfl-squad-add-pitch" data-id="${esc(
                    id
                  )}" data-bank="${esc(bank)}">To pitch</button>`
                : ""
            }
          </div>
          <span class="gpfl-bench-actions">
            <button type="button" class="gpfl-btn gpfl-bench-move" data-dir="-1" data-id="${esc(id)}" ${
              i === 0 || !open ? "disabled" : ""
            }>↑</button>
            <button type="button" class="gpfl-btn gpfl-bench-move" data-dir="1" data-id="${esc(id)}" ${
              i === benchIds.length - 1 || !open ? "disabled" : ""
            }>↓</button>
          </span>
        </li>`;
      })
      .join("")}
  </ol>`;
  }

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
  benchRoot.querySelectorAll(".gpfl-bench-item").forEach((row) => {
    if (!open) return;
    row.addEventListener("dragstart", (ev) => {
      writeDragPlayerId(ev, row.dataset.id);
      row.classList.add("dragging");
      setPitchDragging(true);
    });
    row.addEventListener("dragend", () => {
      row.classList.remove("dragging");
      setPitchDragging(false);
    });
  });
  benchRoot.querySelectorAll(".gpfl-squad-add-pitch").forEach((btn) => {
    btn.onclick = (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      placePlayerOnBank(btn.dataset.id, btn.dataset.bank);
    };
  });
  benchRoot.querySelectorAll(".gpfl-card-link").forEach((btn) => {
    btn.onclick = () => openPlayerCard(btn.dataset.id, { canSign: false });
  });
}

function renderSquad(data) {
  const root = document.getElementById("gpflSquad");
  if (!root) return;

  const titleEl = document.getElementById("gpflSquadTitle");
  if (titleEl) {
    const team = String(data?.entry?.team_name || "").trim() || "Your";
    titleEl.textContent = `${team} Squad`;
  }

  const squad = data.squad || [];
  if (!squad.length) {
    root.innerHTML = `<p class="gpfl-muted">Empty squad — expand Squad Building and sign players.</p>`;
    return;
  }

  const sections = [
    { id: "gk", label: "Goalkeepers", group: "gk" },
    { id: "def", label: "Defenders", group: "def" },
    { id: "mid", label: "Midfielders", group: "mid" },
    { id: "fwd", label: "Forwards", group: "fwd" },
  ];

  const pitchOpen = canEditPitch(data);
  const starters = starterIdsFromBanks(state.banks);

  root.innerHTML = sections
    .map((sec) => {
      const rows = sortPlayersByPos(squad.filter((p) => playerBankGroup(p) === sec.group));
      const body = !rows.length
        ? `<p class="gpfl-muted gpfl-squad-empty">None yet.</p>`
        : `<ul class="gpfl-squad-list">
            ${rows
              .map((p) => {
                const fa = p.slot_status === "needs_replace";
                const onPitch = starters.has(p.player_id);
                const role = onPitch
                  ? `XI · ${sec.group.toUpperCase()}`
                  : p.bench_order
                    ? `B${p.bench_order}`
                    : "Bench";
                const pos = normalizePos(p.position) || "—";
                const dmf = pos === "DMF" ? " · CS as DEF" : "";
                return `<li class="gpfl-squad-card${fa ? " needs-replace" : ""}${
                  onPitch ? " on-pitch" : ""
                }" draggable="${pitchOpen && p.slot_status === "active" ? "true" : "false"}" data-id="${esc(
                  p.player_id
                )}" data-bank="${esc(sec.group)}">
                  <img class="gpfl-mini-thumb" src="${pesdbPlayerCardUrl(p.player_id)}" alt="" loading="lazy" draggable="false" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">
                  <div class="gpfl-squad-card-main">
                    <button type="button" class="gpfl-link gpfl-card-link" data-id="${esc(
                      p.player_id
                    )}">${esc(p.player_name || p.player_id)}</button>
                    <div class="gpfl-squad-card-meta">
                      <span>${esc(p.club_short_name || p.club_name || "—")}</span>
                      <span>${moneyNum(p.purchase_price)}</span>
                      ${pos === "DMF" ? `<span class="gpfl-muted">${esc(dmf.trim())}</span>` : ""}
                    </div>
                    <div class="gpfl-squad-card-badges">
                      ${fa ? `<span class="gpfl-badge gpfl-badge--fa">FA</span>` : ""}
                      ${p.is_captain ? `<span class="gpfl-badge gpfl-badge--c">C</span>` : ""}
                      <span class="gpfl-badge">${esc(role)}</span>
                    </div>
                    ${
                      pitchOpen && p.slot_status === "active" && !onPitch
                        ? `<button type="button" class="gpfl-btn gpfl-squad-add-pitch" data-id="${esc(
                            p.player_id
                          )}" data-bank="${esc(sec.group)}">To pitch</button>`
                        : pitchOpen && onPitch
                          ? `<div class="gpfl-muted" style="font-size:11px;margin-top:4px;">On pitch — drag to move / × to bench</div>`
                          : ""
                    }
                  </div>
                  <button type="button" class="gpfl-btn gpfl-rm" data-id="${esc(p.player_id)}" ${
                    canTransfer(data) ? "" : "disabled"
                  }>${fa ? "Clear" : "Sell"}</button>
                </li>`;
              })
              .join("")}
          </ul>`;

      return `<div class="gpfl-squad-sec" data-group="${esc(sec.id)}">
        <h3 class="gpfl-subhead">${esc(sec.label)} <span class="gpfl-muted">(${rows.length})</span></h3>
        ${body}
      </div>`;
    })
    .join("");

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
  root.querySelectorAll(".gpfl-squad-add-pitch").forEach((btn) => {
    btn.onclick = (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      placePlayerOnBank(btn.dataset.id, btn.dataset.bank);
    };
  });
  root.querySelectorAll(".gpfl-squad-card[draggable='true']").forEach((card) => {
    card.addEventListener("dragstart", (ev) => {
      // Don't start a drag from the Sell / name / To pitch controls
      if (ev.target?.closest?.("button")) {
        ev.preventDefault();
        return;
      }
      writeDragPlayerId(ev, card.dataset.id);
      card.classList.add("dragging");
      setPitchDragging(true);
    });
    card.addEventListener("dragend", () => {
      card.classList.remove("dragging");
      setPitchDragging(false);
    });
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
      [p.player_name, p.club_name, p.club_short_name, p.owner_name]
        .join(" ")
        .toLowerCase()
        .includes(q)
    );
  }
  // Category only — sort by price (dear first), then name
  players = [...players].sort(
    (a, b) =>
      Number(b.price ?? 0) - Number(a.price ?? 0) ||
      String(a.player_name || "").localeCompare(String(b.player_name || ""))
  );

  if (!players.length) {
    return `<p class="gpfl-muted">No players in this group${q ? " for this filter" : ""}.</p>`;
  }

  const list = `<ul class="gpfl-pool-list">
    ${players
      .map((p) => {
        const inSquad = (state.payload?.squad || []).some(
          (s) => s.player_id === p.player_id && s.slot_status === "active"
        );
        const allowSign = canTransfer() && !inSquad;
        return `<li>
          <div class="gpfl-pool-row-wrap">
            <button type="button" class="gpfl-pool-row" data-id="${esc(p.player_id)}" data-sign="1">
              <img src="${pesdbPlayerCardUrl(p.player_id)}" alt="" loading="lazy" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">
              <span class="gpfl-pool-row-main">
                <b>${esc(p.player_name)}</b>
                <span class="gpfl-muted">${esc(p.club_name || p.club_short_name || "")} · ${ownerLinkHtml(
                  p.owner_id,
                  p.owner_name || "—",
                  { stopPool: true }
                )}</span>
              </span>
              <span class="gpfl-pool-row-meta">
                <span>${esc(p.ownership_pct ?? "—")}%</span>
                <span>${moneyNum(p.price)}</span>
              </span>
            </button>
            ${
              inSquad
                ? `<span class="gpfl-badge">In squad</span>`
                : `<button type="button" class="gpfl-btn gpfl-btn--gold gpfl-pool-sign" data-id="${esc(
                    p.player_id
                  )}" ${allowSign ? "" : "disabled"} title="${
                    allowSign ? "Sign to GPFL squad" : "Transfers locked or unavailable"
                  }">Sign</button>`
            }
          </div>
        </li>`;
      })
      .join("")}
  </ul>`;

  return `<p class="gpfl-muted" style="margin:0 0 8px;">${esc(
    payload.total ?? players.length
  )} ${esc(sec.label.toLowerCase())} · sorted dear → cheap · click a player for profile &amp; sign</p>${list}`;
}

function wirePoolRows(root) {
  root.querySelectorAll("[data-owner-link]").forEach((a) => {
    a.onclick = (ev) => ev.stopPropagation();
  });
  root.querySelectorAll(".gpfl-pool-row").forEach((btn) => {
    btn.onclick = (ev) => {
      // Don't open card when clicking Sign or an owner profile link
      if (ev.target.closest?.(".gpfl-pool-sign, [data-owner-link]")) return;
      openPlayerCard(btn.dataset.id, { canSign: true });
    };
  });
  root.querySelectorAll(".gpfl-pool-sign").forEach((btn) => {
    btn.onclick = async (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      if (!canTransfer()) {
        setStatus(
          "Transfers locked while the GPSL month is live. Finish your initial squad before confirming, or wait until the month locks.",
          false
        );
        return;
      }
      await signPlayer(btn.dataset.id);
    };
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
  const allowSign = canSign && canTransfer() && !alreadyIn;
  const lockedOut = canSign && !alreadyIn && !canTransfer();

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
        allowSign
          ? `<button type="button" class="gpfl-btn gpfl-btn--gold gpfl-sign-btn" data-id="${esc(
              playerId
            )}">Sign to GPFL squad · ${money(data.price)}</button>`
          : alreadyIn
            ? `<span class="gpfl-badge">In your squad</span>`
            : lockedOut
              ? `<span class="gpfl-muted">Transfers locked while the GPSL month is live.</span>`
              : canSign
                ? `<button type="button" class="gpfl-btn gpfl-btn--gold gpfl-sign-btn" data-id="${esc(
                    playerId
                  )}" disabled>Sign unavailable</button>`
                : ""
      }
      <a class="gpfl-btn" href="${gpslPlayerCareerUrl(playerId)}" target="_blank" rel="noopener">Full GPSL career</a>
      <a class="gpfl-btn" href="${pesdbPlayerUrl(playerId)}" target="_blank" rel="noopener">PESDB</a>
    </div>
    <h3 class="gpfl-subhead">GPFL form</h3>
    <div class="gpfl-form-row">${form}</div>
    <h3 class="gpfl-subhead"${tipAttrs(GPFL_TIPS.fdr)}>Next fixtures · FDR</h3>
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
    <thead><tr><th>#</th><th>Team</th><th>Owner</th><th class="num">Pts</th></tr></thead>
    <tbody>
      ${rows
        .map(
          (r) => `<tr ${r.is_me ? 'style="background:rgba(60,120,180,0.15)"' : ""}>
            <td>${esc(r.rank)}</td>
            <td>${esc(r.team_name || "—")}${r.is_me ? ' <span class="gpfl-badge">you</span>' : ""}</td>
            <td>${ownerLinkHtml(
              r.owner_id,
              r.owner_name || r.owner_tag || r.club_short_name || "—"
            )}</td>
            <td class="num">${esc(r.total_points ?? 0)}</td>
          </tr>`
        )
        .join("")}
    </tbody>
  </table>`;
}

function placeLabel(n) {
  const p = Number(n);
  if (p === 1) return "1st";
  if (p === 2) return "2nd";
  if (p === 3) return "3rd";
  return `${p}th`;
}

function prizeRowsHtml(rows) {
  const list = (rows || []).filter((r) => Number(r.amount) > 0);
  if (!list.length) {
    return `<p class="gpfl-muted">No prizes set for this scope.</p>`;
  }
  return `<table class="gpfl-table">
    <thead><tr><th>Place</th><th class="num">Prize</th></tr></thead>
    <tbody>
      ${list
        .map(
          (r) => `<tr>
            <td>${esc(placeLabel(r.place))}</td>
            <td class="num">${esc(formatMoney(r.amount))}</td>
          </tr>`
        )
        .join("")}
    </tbody>
  </table>`;
}

async function loadPrizesBoard() {
  const root = document.getElementById("gpflPrizes");
  if (!root) return;

  root.innerHTML = `<p class="gpfl-muted">Loading…</p>`;
  const { data, error } = await supabase.rpc("gpfl_prizes_board");
  if (error) {
    root.innerHTML = `<p class="gpfl-muted">${esc(patchMissingHint(error))}</p>`;
    return;
  }

  if (!data?.enabled) {
    root.innerHTML = `<p class="gpfl-muted">Cash prizes are currently disabled.</p>`;
    return;
  }

  const payouts = data?.payouts || [];
  const seasonPaid = payouts.filter((p) => p.scope === "season");
  const monthPaid = payouts.filter((p) => p.scope === "month");

  const winnersBlock = (title, rows) => {
    if (!rows.length) return "";
    return `<h3 class="gpfl-subhead" style="margin-top:12px;">${title}</h3>
      <table class="gpfl-table">
        <thead><tr><th>Place</th><th>Winner</th><th class="num">Paid</th></tr></thead>
        <tbody>
          ${rows
            .map(
              (p) => `<tr ${p.is_me ? 'style="background:rgba(60,120,180,0.15)"' : ""}>
                <td>${esc(placeLabel(p.place))}${
                  p.gpsl_month ? ` · ${esc(monthLabel(p.gpsl_month))}` : ""
                }</td>
                <td>${ownerLinkHtml(p.owner_id, p.owner_name || p.owner_tag || "—")}${
                  p.team_name ? ` <span class="gpfl-muted">(${esc(p.team_name)})</span>` : ""
                }${p.is_me ? ' <span class="gpfl-badge">you</span>' : ""}</td>
                <td class="num">${esc(formatMoney(p.amount))}</td>
              </tr>`
            )
            .join("")}
        </tbody>
      </table>`;
  };

  root.innerHTML = `
    <div class="gpfl-grid-2">
      <div>
        <h3 class="gpfl-subhead">Season top 3</h3>
        ${prizeRowsHtml(data.season)}
      </div>
      <div>
        <h3 class="gpfl-subhead">Each month top 3</h3>
        ${prizeRowsHtml(data.month)}
      </div>
    </div>
    ${
      seasonPaid.length || monthPaid.length
        ? winnersBlock("Paid winners", [...seasonPaid, ...monthPaid])
        : `<p class="gpfl-muted" style="margin-top:12px;">No prizes paid yet this season.</p>`
    }
  `;
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

async function loadOwnerBankStat() {
  const el = document.getElementById("gpflHeroStats");
  if (!el) return;
  const { data, error } = await supabase.rpc("owner_wallet_get_self");
  if (error) {
    el.innerHTML = "";
    return;
  }
  el.innerHTML = `
    <div class="gpfl-stat">Owner bank <b>${formatMoney(data?.balance ?? 0)}</b></div>
    <div class="gpfl-stat"><a href="owners_bank.html" style="color:#9cf;text-decoration:none">Statement →</a></div>
  `;
}

async function refresh() {
  const data = await loadEntry();
  if (!data) return;
  await loadOwnerBankStat();
  renderGate(data);
  renderDeadlineBanner(data);
  fillMonthSelects();
  if (data.joined) {
    const prevBanks = {
      gk: [...(state.banks.gk || [])],
      def: [...(state.banks.def || [])],
      mid: [...(state.banks.mid || [])],
      fwd: [...(state.banks.fwd || [])],
    };
    const prevBench = [...state.benchOrder];

    state.banks = mergeBanks(
      data.squad,
      data.xi_banks,
      prevBanks,
      state.banksTouched
    );
    state.benchOrder = mergeBenchOrder(data.squad, state.banks, prevBench);

    renderEntryStats(data);
    renderChips(data);
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
  await loadPrizesBoard();
  await loadContent();
}

function setGpflTab(tab) {
  const id = tab === "standings" ? "standings" : "squad";
  document.querySelectorAll(".gpfl-tab").forEach((btn) => {
    const on = btn.dataset.gpflTab === id;
    btn.classList.toggle("active", on);
    btn.setAttribute("aria-selected", on ? "true" : "false");
  });
  document.querySelectorAll(".gpfl-tab-panel").forEach((panel) => {
    const on = panel.dataset.gpflPanel === id;
    panel.classList.toggle("active", on);
    panel.hidden = !on;
  });
  try {
    const url = new URL(location.href);
    if (id === "squad") url.searchParams.delete("tab");
    else url.searchParams.set("tab", id);
    history.replaceState(null, "", url);
  } catch {
    /* ignore */
  }
}

function wire() {
  document.querySelectorAll(".gpfl-tab").forEach((btn) => {
    btn.addEventListener("click", () => setGpflTab(btn.dataset.gpflTab));
  });
  const qTab = new URLSearchParams(location.search).get("tab");
  if (qTab === "standings") setGpflTab("standings");

  document.getElementById("gpflJoinBtn")?.addEventListener("click", async () => {
    const name = document.getElementById("gpflTeamName")?.value || null;
    setStatus("Joining…");
    const { error } = await supabase.rpc("gpfl_join", { p_team_name: name });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus("Joined GPFL.");
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

  document.getElementById("gpflSaveXiBtn")?.addEventListener("click", saveXi);

  async function saveXi() {
    if (!xiBanksValid(state.banks)) {
      setStatus(
        `XI must be GK 1 · DEF 3–5 · MID 2–5 · FWD 1–3 (11 total). Current: ${xiShapeLabel(state.banks)}.`,
        false
      );
      return;
    }
    const cap = document.getElementById("gpflCaptain")?.value || null;
    if (!cap) {
      setStatus("Pick a captain from the XI.", false);
      return;
    }
    const lineup = {
      gk: [...(state.banks.gk || [])],
      def: [...(state.banks.def || [])],
      mid: [...(state.banks.mid || [])],
      fwd: [...(state.banks.fwd || [])],
    };
    const starters = starterIdsFromBanks(lineup);
    if (!starters.has(cap)) {
      setStatus("Captain must be one of the 11 on the pitch.", false);
      return;
    }
    const benchIds = state.benchOrder.filter((id) => id && !starters.has(id));
    setStatus("Saving pitch XI + bench…");
    const { data, error } = await supabase.rpc("gpfl_set_xi", {
      p_lineup: lineup,
      p_captain_id: cap,
      p_bench_ids: benchIds,
    });
    if (error) return setStatus(patchMissingHint(error), false);
    state.banksTouched = false;
    state.banks = { ...lineup };
    state.benchOrder = benchIds;
    if (data) state.payload = data;
    await refresh();
    setStatus("Pitch XI + bench saved.");
  }

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
      p_refresh_prices: true,
    });
    if (error) return setStatus(error.message, false);
    await refresh();
    setStatus(
      `GPFL season ready (${data?.price_rows_touched ?? "?"} rows · ${
        data?.pricing || data?.reprice?.pricing || "prices"
      } · floor ₿${Number(
        data?.price_floor ?? data?.reprice?.price_floor ?? 0
      ).toLocaleString("en-GB")}–₿${Number(
        data?.price_ceiling ?? data?.reprice?.price_ceiling ?? 0
      ).toLocaleString("en-GB")} · FWD ${
        data?.reprice?.by_group?.fwd
          ? `₿${Number(data.reprice.by_group.fwd.min).toLocaleString("en-GB")}–₿${Number(
              data.reprice.by_group.fwd.max
            ).toLocaleString("en-GB")}`
          : "?"
      }).`
    );
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
  initGpslInfoTips();
  state.isAdmin = await resolveAdmin();
  const adminPanel = document.getElementById("gpflAdminPanel");
  if (adminPanel) adminPanel.hidden = !state.isAdmin;
  fillMonthSelects();
  wire();
  await refresh();
}

main().catch((err) => setStatus(err?.message || String(err), false));
