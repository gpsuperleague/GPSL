import { initGlobal, supabase, getAuthUserFast } from "./global.js";

let state = null;

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
          ? `Injured — returning to light training in ${out} match${out === 1 ? "" : "es"}`
          : `Building fitness — match availability in ${rec} match${rec === 1 ? "" : "es"}`;
      const used = !!inj.token_used;
      const canUse =
        state.has_doctor && consults.length > 0 && !used && (out > 0 || rec > 0);
      const tokenOpts = consults.map(
        (c) => `<option value="${c.key}">${c.label}</option>`
      );
      const selectHtml = canUse
        ? `<select class="med-token-pick" data-token-injury="${inj.injury_id}" style="max-width:min(100%,420px);">${tokenOpts.join(
            ""
          )}</select>`
        : "";
      const disabledReason = !state.has_doctor
        ? "Hire a club doctor first"
        : used
          ? "Consult already used"
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
  el.innerHTML = `
    <div class="staff-card empty doctor-card">
      <div class="staff-slot-label">Vacant — hire doctor</div>
      <div class="sil-wrap">${silhouetteSvg("male", false)}</div>
      <div class="staff-cost">${formatMoney(cost)}</div>
      <div class="staff-contract">3-season contract · name &amp; gender assigned on hire</div>
      <div class="hire-row">
        <button type="button" data-hire-doctor="1">Hire</button>
      </div>
    </div>`;
  el.querySelector("[data-hire-doctor]").onclick = () => hireDoctor();
}

function physioBySlot(slot) {
  return (state.physios || []).find((p) => Number(p.slot_index) === slot) || null;
}

function renderPhysios() {
  const el = document.getElementById("physioSlots");
  if (!el || !state) return;
  const costs = state.physio_hire_costs || {};
  let html = "";
  for (let slot = 1; slot <= 5; slot++) {
    const p = physioBySlot(slot);
    if (p) {
      html += `
        <div class="staff-card">
          <div class="staff-slot-label">Physio ${slot}</div>
          <div class="sil-wrap">${silhouetteSvg(p.gender, true)}</div>
          <div class="staff-name">${staffName(p, `Physio ${slot}`)}</div>
          <div class="staff-bonus">−0.5% injury chance</div>
          <div class="staff-contract">${p.seasons_remaining} season${p.seasons_remaining === 1 ? "" : "s"} left</div>
        </div>`;
    } else {
      const cost = costs[String(slot)] ?? costs[slot];
      html += `
        <div class="staff-card empty">
          <div class="staff-slot-label">Slot ${slot}</div>
          <div class="sil-wrap">${silhouetteSvg("male", false)}</div>
          <div class="staff-cost">${formatMoney(cost)}</div>
          <div class="staff-bonus">−0.5% if hired</div>
          <div class="hire-row">
            <button type="button" data-hire-physio="${slot}">Hire</button>
          </div>
        </div>`;
    }
  }
  el.innerHTML = html;
  el.querySelectorAll("[data-hire-physio]").forEach((btn) => {
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
}

async function hireDoctor() {
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
  const cost = state?.physio_hire_costs?.[String(slot)];
  if (!confirm(`Hire physio for slot ${slot} (${formatMoney(cost)})?`)) {
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
    `Physio hired: ${data?.display_name || "assigned"} (slot ${slot}) − ${formatMoney(data?.cost)}.`,
    "ok"
  );
  await loadState();
}

async function applyToken(injuryId, pickValue = null) {
  const consults = availableConsults();
  const picked =
    (pickValue && consults.find((c) => c.key === pickValue)) || consults[0] || null;
  const tier = picked?.tier || state?.specialist_matches_removed || 2;
  const who = picked?.label || `specialist consult (−${tier})`;

  if (
    !confirm(
      `Doctor refers this injury to:\n${who}\n\n(−${tier} matches; one consult per injury.)`
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
  setStatus(
    `${data?.label || who}: removed ${data?.matches_removed ?? 0} match(es).`,
    "ok"
  );
  await loadState();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const user = await getAuthUserFast();
  if (!user) {
    window.location = "login.html";
    return;
  }
  await loadState();
});
