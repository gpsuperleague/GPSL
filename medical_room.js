import { initGlobal, supabase, getAuthUserFast } from "./global.js";
import { initGpslInfoTips } from "./gpsl_info_tips.js";
import { renderMedicalRoomIntros } from "./medical_room_rules.js?v=20261024-half-cap";

let state = null;

function hireWindowOpen() {
  return state?.hire_window_open !== false;
}

function hireWindowMessage() {
  return (
    state?.hire_window?.message ||
    "Medical staff hiring is closed from September through May. Open again in June–August."
  );
}

function setStatus(msg, kind = "") {
  const el = document.getElementById("medStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.className = "med-status" + (kind ? ` ${kind}` : "");
}

function formatMoney(n) {
  const v = Number(n) || 0;
  return `€${Math.round(v).toLocaleString("en-GB")}`;
}

function silhouetteSvg(gender, filled) {
  const fill = filled
    ? gender === "female"
      ? "#c89ad4"
      : "#7eb8d4"
    : "#2a353c";
  const stroke = filled ? "#e8f4ff" : "#44555e";
  // Simple gender-tinted silhouette
  if (gender === "female") {
    return `<svg viewBox="0 0 64 90" aria-hidden="true">
      <circle cx="32" cy="16" r="11" fill="${fill}" stroke="${stroke}" stroke-width="1.5"/>
      <path d="M18 32 Q32 28 46 32 L48 58 Q32 70 16 58 Z" fill="${fill}" stroke="${stroke}" stroke-width="1.5"/>
      <path d="M22 58 L18 86 M42 58 L46 86" stroke="${stroke}" stroke-width="4" stroke-linecap="round"/>
    </svg>`;
  }
  return `<svg viewBox="0 0 64 90" aria-hidden="true">
    <circle cx="32" cy="15" r="11" fill="${fill}" stroke="${stroke}" stroke-width="1.5"/>
    <path d="M20 30 Q32 26 44 30 L46 62 Q32 58 18 62 Z" fill="${fill}" stroke="${stroke}" stroke-width="1.5"/>
    <path d="M24 62 L22 86 M40 62 L42 86" stroke="${stroke}" stroke-width="4" stroke-linecap="round"/>
  </svg>`;
}

function availableConsults() {
  const list = [];
  const rows = state?.prize_medical_tokens || [];
  for (const t of rows) {
    const tier = Number(t.param_int ?? t.matches_removed) || 2;
    const id = t.consult_id ?? t.id;
    const label =
      t.label ||
      t.consultancy_label ||
      `Specialist consult (−${tier} matches)`;
    list.push({
      key: id != null ? `consult:${id}` : `tier:${tier}:${list.length}`,
      consultId: id != null ? Number(id) : null,
      inventoryId: t.inventory_id != null ? Number(t.inventory_id) : null,
      tier,
      label,
      noDoctorOk: !!t.no_doctor_ok,
    });
  }

  // Fallback when named-consult RPC missing/empty but vault chips still exist
  if (!list.length) {
    const n = Number(state?.specialist_tokens) || 0;
    const tier = Number(state?.specialist_matches_removed) || 2;
    for (let i = 0; i < n; i++) {
      list.push({
        key: i === 0 ? "specialist" : `specialist:${i}`,
        consultId: null,
        inventoryId: null,
        tier,
        label: `Specialist consult (−${tier} matches)`,
      });
    }
  }

  list.sort((a, b) => b.tier - a.tier || (a.consultId || 0) - (b.consultId || 0));
  return list;
}

/** Without a doctor, only Supporters' lottery treatments can be used. */
function usableConsults() {
  const all = availableConsults();
  return state?.has_doctor ? all : all.filter((c) => c.noDoctorOk);
}

function totalConsultCount() {
  return availableConsults().length;
}

function renderHero() {
  const stats = document.getElementById("heroStats");
  if (!stats || !state) return;
  const consults = totalConsultCount();
  stats.innerHTML = `
    <div class="med-stat"><div class="label">Injury chance</div><div class="value">−${state.injury_chance_reduction_pct ?? 0}%</div></div>
    <div class="med-stat"><div class="label">Doctor</div><div class="value">${state.has_doctor ? "Hired" : "Vacant"}</div></div>
    <div class="med-stat"><div class="label">Physios</div><div class="value">${state.physio_count ?? 0}/5</div></div>
    <div class="med-stat"><div class="label">Consults</div><div class="value">${consults}</div></div>
    <div class="med-stat"><div class="label">Balance</div><div class="value">${formatMoney(state.balance)}</div></div>
  `;
}

const FITNESS_WATCH_LABELS = {
  1: "Fully Fit",
  2: "Match Ready",
  3: "Managing Load",
  4: "Fitness Concern",
  5: "Injury Risk",
};

function fitnessWatchMeterHtml(level) {
  const lvl = Math.max(1, Math.min(5, Number(level) || 1));
  const pips = [1, 2, 3, 4, 5]
    .map(
      (n) =>
        `<span class="med-fit-pip med-fit-pip-${n}${n === lvl ? " is-on" : ""}"></span>`
    )
    .join("");
  return `<div class="med-fit-meter" aria-hidden="true">${pips}</div>`;
}

async function renderFitnessWatch() {
  const host = document.getElementById("fitnessWatchList");
  if (!host) return;

  host.innerHTML = `<p class="med-muted">Loading match fitness…</p>`;

  try {
    const { data, error } = await supabase.rpc("club_match_fitness_map", {
      p_club: null,
    });
    if (error) {
      if (/club_match_fitness_map|schema cache|Could not find/i.test(error.message || "")) {
        host.innerHTML = `<p class="med-muted">Match fitness not installed yet — run match_fitness_injury_weights_20261026.sql.</p>`;
        return;
      }
      throw error;
    }

    const by = data?.by_player && typeof data.by_player === "object" ? data.by_player : {};
    // Fitness watch = load management, not injury timeline (those have their own list).
    const injuredIds = new Set(
      (state?.active_injuries || [])
        .filter(
          (i) =>
            i &&
            ((Number(i.matches_out_remaining) || 0) > 0 ||
              (Number(i.recovery_remaining) || 0) > 0 ||
              i.phase === "out" ||
              i.phase === "recovery")
        )
        .map((i) => String(i.player_id))
    );
    const elevated = Object.entries(by)
      .map(([pid, v]) => ({
        playerId: String(pid),
        level: Math.max(1, Math.min(5, Number(v?.level) || 1)),
        label: v?.label || FITNESS_WATCH_LABELS[Number(v?.level) || 1],
        consecutive: Number(v?.consecutive) || 0,
      }))
      .filter((r) => r.level >= 3 && !injuredIds.has(r.playerId))
      .sort(
        (a, b) =>
          b.level - a.level ||
          b.consecutive - a.consecutive ||
          a.playerId.localeCompare(b.playerId)
      );

    if (!elevated.length) {
      host.innerHTML = `<p class="med-muted">No players at Managing Load or above — squad load looks fine.</p>`;
      return;
    }

    const ids = elevated.map((r) => r.playerId);
    const nameMap = new Map();
    const { data: players, error: pErr } = await supabase
      .from("Players")
      .select("Konami_ID, Name, Position")
      .in("Konami_ID", ids);
    if (!pErr) {
      for (const p of players || []) {
        nameMap.set(String(p.Konami_ID), {
          name: p.Name || String(p.Konami_ID),
          position: p.Position || "",
        });
      }
    }

    host.innerHTML = elevated
      .map((r) => {
        const info = nameMap.get(r.playerId) || {
          name: r.playerId,
          position: "",
        };
        const streak =
          r.consecutive > 0
            ? `${r.consecutive} consecutive`
            : "elevated load";
        return `
          <div class="fitness-watch-row med-fit-l${r.level}">
            <div class="fitness-watch-main">
              <strong>${info.name}</strong>
              ${info.position ? `<span class="meta">${info.position}</span>` : ""}
              <div class="meta">${streak}</div>
            </div>
            <div class="fitness-watch-level">
              ${fitnessWatchMeterHtml(r.level)}
              <span class="fitness-watch-label">${r.label}</span>
            </div>
          </div>`;
      })
      .join("");
  } catch (err) {
    console.warn("renderFitnessWatch:", err);
    host.innerHTML = `<p class="med-muted">Could not load match fitness.</p>`;
  }
}

function renderTokens() {
  const vault = document.getElementById("tokenVault");
  const list = document.getElementById("injuryList");
  if (!vault || !list || !state) return;

  const consults = availableConsults();
  const maxSlots = Math.max(Number(state.max_specialist_tokens) || 20, consults.length);
  let chips = "";
  for (let i = 0; i < maxSlots; i++) {
    const c = consults[i];
    const title = c
      ? `${c.label}`
      : "Empty consult slot";
    chips += `<div class="token-chip${c ? "" : " empty"}" title="${title}"></div>`;
  }
  const summary = consults.length
    ? consults.map((c) => `−${c.tier}`).join(", ")
    : "none";
  vault.innerHTML =
    chips +
    `<span style="color:#9ab;font-size:13px;">${consults.length} specialist consult${
      consults.length === 1 ? "" : "s"
    } ready (${summary}) · <a href="club_prizes.html" style="color:#7ec8e8;">Rewards Centre</a></span>`;

  const injuries = state.active_injuries || [];
  if (!injuries.length) {
    list.innerHTML = `<p class="med-intro" style="margin:0;">No active injuries to treat.</p>`;
    return;
  }

  list.innerHTML = injuries
    .map((inj) => {
      const out = Number(inj.matches_out_remaining) || 0;
      const rec = Number(inj.recovery_remaining) || 0;
      const phase =
        out > 0
          ? `Injured — returning to light training in ${out} match${out === 1 ? "" : "es"}${
              rec > 0
                ? `; then ${rec} match${rec === 1 ? "" : "es"} of light training before available`
                : "; then available"
            }`
          : `Building fitness — match availability in ${rec} match${rec === 1 ? "" : "es"}`;
      const used = !!inj.token_used;
      const usable = usableConsults();
      const rem = out > 0 ? out : rec;
      const halfCap = Math.floor(rem / 2);
      const canUse =
        usable.length > 0 && !used && rem > 0 && halfCap >= 1;
      const tokenOpts = usable.map(
        (c) => `<option value="${c.key}">${c.label}</option>`
      );
      const selectHtml = canUse
        ? `<select class="med-token-pick" data-token-injury="${inj.injury_id}" style="max-width:min(100%,420px);">${tokenOpts.join(
            ""
          )}</select>`
        : "";
      const disabledReason = !state.has_doctor && !usable.length
        ? "Hire a club doctor first"
        : used
          ? "Consult already used"
          : rem > 0 && halfCap < 1
            ? "Too short to shorten further (half-cap is 0)"
            : !consults.length
              ? "No consults available"
              : "";
      return `
        <div class="injury-row">
          <div>
            <strong>${inj.player_name || inj.player_id}</strong>
            <div class="meta">${inj.label || "Injury"} · ${inj.severity || ""}</div>
            <div class="meta">${phase}</div>
            ${used ? `<div class="meta">Specialist consult already used on this injury</div>` : ""}
            ${
              !used && rem > 0
                ? `<div class="meta">Consult cap: max −${halfCap} (half of ${rem} left)</div>`
                : ""
            }
            ${!canUse && disabledReason ? `<div class="meta">${disabledReason}</div>` : ""}
          </div>
          <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;">
            ${selectHtml}
            <button type="button" class="med-btn" data-token-injury="${inj.injury_id}"
              ${canUse ? "" : "disabled"}>
              Refer to specialist
            </button>
          </div>
        </div>`;
    })
    .join("");

  list.querySelectorAll("button[data-token-injury]").forEach((btn) => {
    btn.onclick = () => {
      const injuryId = Number(btn.dataset.tokenInjury);
      const pick = list.querySelector(
        `select.med-token-pick[data-token-injury="${injuryId}"]`
      );
      applyToken(injuryId, pick?.value || null);
    };
  });
}

function staffName(row, fallback) {
  const n = (row?.display_name || "").trim();
  if (n && n !== "Club doctor" && n !== "Club physiotherapist") return n;
  return fallback;
}

function physioGradeMeta(slot) {
  const fromApi = (state?.physio_grades || []).find((g) => Number(g.slot) === Number(slot));
  if (fromApi) return fromApi;
  const titles = {
    1: "Trainee physiotherapist",
    2: "Physiotherapist",
    3: "Senior physiotherapist",
    4: "Advanced physiotherapist",
    5: "Consultant physiotherapist",
  };
  const effects = { 1: 0.2, 2: 0.35, 3: 0.6, 4: 1, 5: 2 };
  const costs = state?.physio_hire_costs || {};
  return {
    slot,
    title: titles[slot] || `Physio ${slot}`,
    effect_pct: effects[slot] ?? 0.5,
    hire_cost: costs[String(slot)] ?? costs[slot],
    hireable: Number(state?.next_physio_slot) === Number(slot),
  };
}

function effectLabel(pct) {
  const n = Number(pct);
  if (!Number.isFinite(n)) return "";
  const t = Number.isInteger(n) ? String(n) : String(n);
  return `−${t}% injury chance`;
}

function renderDoctor() {
  const el = document.getElementById("doctorSlot");
  if (!el || !state) return;
  const doc = state.doctor;
  if (doc) {
    el.innerHTML = `
      <div class="staff-card doctor-card">
        <div class="staff-slot-label">Club doctor</div>
        <div class="sil-wrap">${silhouetteSvg(doc.gender, true)}</div>
        <div class="staff-name">${staffName(doc, "Club doctor")}</div>
        <div class="staff-bonus">−1 match on new injuries</div>
        <div class="staff-contract">${doc.seasons_remaining} season${doc.seasons_remaining === 1 ? "" : "s"} left</div>
      </div>`;
    return;
  }
  const cost = state.doctor_hire_cost;
  const closed = !hireWindowOpen();
  el.innerHTML = `
    <div class="staff-card empty doctor-card${closed ? " locked" : ""}">
      <div class="staff-slot-label">Vacant — hire doctor</div>
      <div class="sil-wrap">${silhouetteSvg("male", false)}</div>
      <div class="staff-cost">${formatMoney(cost)}</div>
      <div class="staff-contract">3-season contract · name &amp; gender assigned on hire${
        closed ? " · hiring closed until June" : ""
      }</div>
      <div class="hire-row">
        <button type="button" data-hire-doctor="1" ${closed ? "disabled" : ""}>${
          closed ? "Closed" : "Hire"
        }</button>
      </div>
    </div>`;
  if (!closed) {
    el.querySelector("[data-hire-doctor]").onclick = () => hireDoctor();
  }
}

function physioBySlot(slot) {
  return (state.physios || []).find((p) => Number(p.slot_index) === slot) || null;
}

function renderPhysios() {
  const el = document.getElementById("physioSlots");
  if (!el || !state) return;
  let html = "";
  for (let slot = 1; slot <= 5; slot++) {
    const g = physioGradeMeta(slot);
    const p = physioBySlot(slot);
    if (p) {
      const title = p.title || g.title;
      const effect = p.effect_pct ?? g.effect_pct;
      html += `
        <div class="staff-card">
          <div class="staff-slot-label">Grade ${slot} · ${title}</div>
          <div class="sil-wrap">${silhouetteSvg(p.gender, true)}</div>
          <div class="staff-name">${staffName(p, title)}</div>
          <div class="staff-bonus">${effectLabel(effect)}</div>
          <div class="staff-contract">${p.seasons_remaining} season${p.seasons_remaining === 1 ? "" : "s"} left</div>
        </div>`;
    } else {
      const cost = g.hire_cost;
      const windowClosed = !hireWindowOpen();
      const locked = !g.hireable || windowClosed;
      const lockHint = windowClosed
        ? " · hiring closed until June"
        : !g.hireable
          ? " · hire previous grade first"
          : "";
      html += `
        <div class="staff-card empty${locked ? " locked" : ""}">
          <div class="staff-slot-label">Grade ${slot} · ${g.title}</div>
          <div class="sil-wrap">${silhouetteSvg("male", false)}</div>
          <div class="staff-cost">${formatMoney(cost)}</div>
          <div class="staff-bonus">${effectLabel(g.effect_pct)}${lockHint}</div>
          <div class="hire-row">
            <button type="button" data-hire-physio="${slot}" ${locked ? "disabled" : ""}>${
              windowClosed ? "Closed" : locked ? "Locked" : "Hire"
            }</button>
          </div>
        </div>`;
    }
  }
  el.innerHTML = html;
  el.querySelectorAll("[data-hire-physio]:not([disabled])").forEach((btn) => {
    btn.onclick = () => hirePhysio(Number(btn.dataset.hirePhysio));
  });
}

async function loadState() {
  const { data, error } = await supabase.rpc("medical_room_state", {
    p_club: null,
  });
  if (error) {
    if (/medical_room_state|schema cache|Could not find/i.test(error.message || "")) {
      setStatus(
        "Medical Room SQL not applied yet — run supabase/sql/patches/club_medical_room.sql (then re-run competition_injuries_engine.sql).",
        "error"
      );
      return;
    }
    setStatus("❌ " + error.message, "error");
    return;
  }
  if (!data?.ok) {
    setStatus(data?.error || "Could not load medical room.", "error");
    return;
  }
  state = data;
  if (data.hire_window_open === false) {
    setStatus(hireWindowMessage(), "");
  }
  try {
    const { data: prizeTok, error: prizeErr } = await supabase.rpc(
      "medical_room_prize_tokens",
      { p_club: data.club_short_name || null }
    );
    if (prizeErr) {
      console.warn("medical_room_prize_tokens", prizeErr);
      state.prize_medical_tokens = [];
      // Named consults SQL may not be applied yet — vault count still works via fallback
    } else if (Array.isArray(prizeTok)) {
      state.prize_medical_tokens = prizeTok;
    } else if (typeof prizeTok === "string") {
      try {
        const parsed = JSON.parse(prizeTok);
        state.prize_medical_tokens = Array.isArray(parsed) ? parsed : [];
      } catch {
        state.prize_medical_tokens = [];
      }
    } else {
      state.prize_medical_tokens = [];
    }
  } catch (e) {
    console.warn("medical_room_prize_tokens", e);
    state.prize_medical_tokens = [];
  }
  renderHero();
  renderDoctor();
  renderPhysios();
  renderTokens();
  await renderFitnessWatch();
}

async function hireDoctor() {
  if (!hireWindowOpen()) {
    setStatus(hireWindowMessage(), "error");
    return;
  }
  if (!confirm(`Hire a club doctor for ${formatMoney(state?.doctor_hire_cost)}?`)) {
    return;
  }
  setStatus("Hiring doctor…");
  const { data, error } = await supabase.rpc("medical_hire_doctor");
  if (error) {
    setStatus("❌ " + error.message, "error");
    return;
  }
  setStatus(
    `Doctor hired: ${data?.display_name || data?.gender || "assigned"} (−${formatMoney(data?.cost)}).`,
    "ok"
  );
  await loadState();
}

async function hirePhysio(slot) {
  if (!hireWindowOpen()) {
    setStatus(hireWindowMessage(), "error");
    return;
  }
  const g = physioGradeMeta(slot);
  if (!g.hireable) {
    setStatus("Hire the previous physio grade first (fixed ladder).", "error");
    return;
  }
  const cost = g.hire_cost ?? state?.physio_hire_costs?.[String(slot)];
  if (
    !confirm(
      `Hire ${g.title} (grade ${slot}) for ${formatMoney(cost)}?\n${effectLabel(g.effect_pct)} · 3-season contract`
    )
  ) {
    return;
  }
  setStatus("Hiring physio…");
  const { data, error } = await supabase.rpc("medical_hire_physio", {
    p_slot: Number(slot),
  });
  if (error) {
    const parts = [
      error.message,
      error.details,
      error.hint,
      error.code ? `(${error.code})` : "",
    ].filter(Boolean);
    const msg = parts.join(" — ") || "Hire failed";
    const hint = /Could not find|schema cache|PGRST202|function/i.test(msg)
      ? " — run club_medical_room_hire_fix.sql in Supabase"
      : /entry_type|check constraint/i.test(msg)
        ? " — ledger entry type missing; run club_medical_room_hire_fix.sql"
        : "";
    setStatus("❌ " + msg + hint, "error");
    console.error("medical_hire_physio", error);
    return;
  }
  if (!data?.ok && data?.error) {
    setStatus("❌ " + data.error, "error");
    return;
  }
  setStatus(
    `${data?.title || "Physio"} hired: ${data?.display_name || "assigned"} (${effectLabel(data?.effect_pct)}) − ${formatMoney(data?.cost)}.`,
    "ok"
  );
  await loadState();
}

function specialistEffectiveCut(tier, remaining) {
  const t = Math.max(0, Number(tier) || 0);
  const left = Math.max(0, Number(remaining) || 0);
  const cap = Math.floor(left / 2);
  return Math.min(t, cap, left);
}

async function applyToken(injuryId, pickValue = null) {
  const consults = usableConsults();
  const picked =
    (pickValue && consults.find((c) => c.key === pickValue)) || consults[0] || null;
  const tier = picked?.tier || state?.specialist_matches_removed || 2;
  const who = picked?.label || `specialist consult (−${tier})`;
  const inj = (state?.active_injuries || []).find(
    (i) => Number(i.injury_id) === Number(injuryId)
  );
  const remaining =
    (Number(inj?.matches_out_remaining) || 0) > 0
      ? Number(inj.matches_out_remaining)
      : Number(inj?.recovery_remaining) || 0;
  const effective = specialistEffectiveCut(tier, remaining);

  if (
    !confirm(
      `Doctor refers this injury to:\n${who}\n\n` +
        `Token −${tier} · max half of ${remaining} left → removes ${effective} ` +
        `(${remaining - effective} still remaining).\n` +
        `One consult per injury.`
    )
  ) {
    return;
  }
  setStatus("Referring to specialist…");
  const payload = { p_injury_id: injuryId };
  if (picked?.consultId) {
    payload.p_consult_id = picked.consultId;
  } else if (picked?.inventoryId) {
    payload.p_inventory_id = picked.inventoryId;
  } else {
    payload.p_prefer_specialist = true;
  }
  const { data, error } = await supabase.rpc("medical_apply_specialist_token", payload);
  if (error) {
    setStatus("❌ " + error.message, "error");
    return;
  }
  const removed = data?.matches_removed ?? 0;
  const after =
    data?.remaining_after != null
      ? data.remaining_after
      : Math.max(0, remaining - removed);
  setStatus(
    `${data?.label || who}: removed ${removed} match(es)` +
      (data?.token_tier != null && removed < Number(data.token_tier)
        ? ` (capped at half — ${after} still left)`
        : after != null
          ? ` · ${after} still left`
          : "") +
      `.`,
    "ok"
  );
  await loadState();
}

document.addEventListener("DOMContentLoaded", async () => {
  initGpslInfoTips();
  renderMedicalRoomIntros();
  await initGlobal();
  const user = await getAuthUserFast();
  if (!user) {
    window.location = "login.html";
    return;
  }
  await loadState();
});
