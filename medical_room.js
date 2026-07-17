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

function renderHero() {
  const stats = document.getElementById("heroStats");
  if (!stats || !state) return;
  const tokens = Number(state.specialist_tokens) || 0;
  stats.innerHTML = `
    <div class="med-stat"><div class="label">Injury chance</div><div class="value">−${state.injury_chance_reduction_pct ?? 0}%</div></div>
    <div class="med-stat"><div class="label">Doctor</div><div class="value">${state.has_doctor ? "Hired" : "Vacant"}</div></div>
    <div class="med-stat"><div class="label">Physios</div><div class="value">${state.physio_count ?? 0}/5</div></div>
    <div class="med-stat"><div class="label">Tokens</div><div class="value">${tokens}</div></div>
    <div class="med-stat"><div class="label">Balance</div><div class="value">${formatMoney(state.balance)}</div></div>
  `;
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

function renderTokens() {
  const vault = document.getElementById("tokenVault");
  const list = document.getElementById("injuryList");
  if (!vault || !list || !state) return;

  const tokens = Number(state.specialist_tokens) || 0;
  const prizeTokens = state.prize_medical_tokens || [];
  const hasPrize = prizeTokens.length > 0;
  const maxTokens = Number(state.max_specialist_tokens) || 20;
  let chips = "";
  for (let i = 0; i < maxTokens; i++) {
    chips += `<div class="token-chip${i < tokens ? "" : " empty"}" title="${i < tokens ? "Specialist token" : "Empty slot"}"></div>`;
  }
  const prizeLabel = hasPrize
    ? ` · Prize tokens: ${prizeTokens.map((t) => `−${t.param_int}`).join(", ")}`
    : "";
  vault.innerHTML =
    chips +
    `<span style="color:#9ab;font-size:13px;">${tokens} / ${maxTokens} stored${prizeLabel} · <a href="club_prizes.html" style="color:#7ec8e8;">Rewards Centre</a></span>`;

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
        state.has_doctor && (tokens > 0 || hasPrize) && !used && (out > 0 || rec > 0);
      const tokenOpts = [];
      for (const t of prizeTokens) {
        tokenOpts.push(
          `<option value="prize:${t.id}">Prize −${t.param_int} matches</option>`
        );
      }
      if (tokens > 0) {
        tokenOpts.push(
          `<option value="specialist">Specialist consult (−${
            state.specialist_matches_removed || 2
          })</option>`
        );
      }
      const selectHtml = canUse
        ? `<select class="med-token-pick" data-token-injury="${inj.injury_id}" style="max-width:200px;">${tokenOpts.join(
            ""
          )}</select>`
        : "";
      return `
        <div class="injury-row">
          <div>
            <strong>${inj.player_name || inj.player_id}</strong>
            <div class="meta">${inj.label || "Injury"} · ${inj.severity || ""}</div>
            <div class="meta">${phase}</div>
            ${used ? `<div class="meta">Specialist consult already used</div>` : ""}
          </div>
          <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;">
            ${selectHtml}
            <button type="button" class="med-btn" data-token-injury="${inj.injury_id}"
              ${canUse ? "" : "disabled"}>
              Apply token
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
    const { data: prizeTok } = await supabase.rpc("medical_room_prize_tokens", {
      p_club: data.club_short_name || null,
    });
    state.prize_medical_tokens = Array.isArray(prizeTok) ? prizeTok : [];
  } catch {
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
  let inventoryId = null;
  let tier = state?.specialist_matches_removed || 2;
  const prizeTokens = state?.prize_medical_tokens || [];

  if (pickValue?.startsWith("prize:")) {
    inventoryId = Number(pickValue.slice(6));
    const match = prizeTokens.find((t) => Number(t.id) === inventoryId);
    tier = match?.param_int || tier;
  } else if (pickValue === "specialist") {
    inventoryId = null;
    tier = state?.specialist_matches_removed || 2;
  } else {
    // Default: best prize token, else specialist
    const prize = prizeTokens[0];
    if (prize?.id) {
      inventoryId = prize.id;
      tier = prize.param_int || tier;
    }
  }

  if (
    !confirm(
      `Use a medical consult to remove up to ${tier} match(es) from this injury? (One consult per injury.)`
    )
  ) {
    return;
  }
  setStatus("Applying medical consult…");
  const payload = { p_injury_id: injuryId };
  if (inventoryId) {
    payload.p_inventory_id = inventoryId;
  } else if (pickValue === "specialist") {
    payload.p_prefer_specialist = true;
  }
  const { data, error } = await supabase.rpc("medical_apply_specialist_token", payload);
  if (error) {
    setStatus("❌ " + error.message, "error");
    return;
  }
  setStatus(
    `Removed ${data?.matches_removed ?? 0} match(es) (tier −${data?.token_tier ?? tier}).`,
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
