import { initGlobal, supabase, getAuthUserFast } from "./global.js";
import { formatMoney } from "./competition.js";

let inventory = [];

function setStatus(msg, kind = "") {
  const el = document.getElementById("prizeStatus");
  if (!el) return;
  el.textContent = msg || "";
  el.className = "status" + (kind === "ok" ? " ok" : kind === "err" ? " err" : "");
}

function labelItem(it) {
  if (it.prize_type === "medical_token") {
    const named =
      it.metadata?.label ||
      it.metadata?.consultancy_label ||
      it.label;
    if (named) return `${named} (−${it.param_int})`;
    return `Specialist consult −${it.param_int} matches`;
  }
  if (it.prize_type === "fee_discount") return `Fee discount ${it.param_int}%`;
  if (it.prize_type === "appeal_card") return "Red card appeal card";
  if (it.prize_type === "draft_token") return "Draft token (sign free agent at MV)";
  return it.prize_type;
}

function renderInventory() {
  const el = document.getElementById("prizeInventory");
  if (!inventory.length) {
    el.innerHTML =
      '<p class="meta">No prize items yet. Win a period bonus by completing all challenges in a window.</p>';
    return;
  }
  el.innerHTML = inventory
    .map((it) => {
      const ctx =
        it.status === "locked" && it.locked_context
          ? ` · locked to ${it.locked_context.kind} #${it.locked_context.id}`
          : it.status === "pending_review"
            ? " · appeal pending review"
            : "";
      return `<div class="prize-row">
        <div>
          <div class="prize-label">${labelItem(it)}</div>
          <div class="prize-meta">${it.status}${ctx}${it.source ? ` · ${it.source}` : ""}</div>
        </div>
      </div>`;
    })
    .join("");

  const discSel = document.getElementById("discountTokenSelect");
  const appealSel = document.getElementById("appealCardSelect");
  const draftSel = document.getElementById("draftTokenSelect");
  const discounts = inventory.filter((i) => i.prize_type === "fee_discount" && i.status === "available");
  const locked = inventory.filter((i) => i.prize_type === "fee_discount" && i.status === "locked");
  const appeals = inventory.filter((i) => i.prize_type === "appeal_card" && i.status === "available");
  const drafts = inventory.filter((i) => i.prize_type === "draft_token" && i.status === "available");

  discSel.innerHTML =
    (locked.length
      ? locked.map((i) => `<option value="${i.id}">${i.param_int}% (locked)</option>`).join("")
      : "") +
    (discounts.length
      ? discounts.map((i) => `<option value="${i.id}">${i.param_int}%</option>`).join("")
      : '<option value="">No available discounts</option>');

  appealSel.innerHTML = appeals.length
    ? appeals.map((i) => `<option value="${i.id}">Appeal card #${i.id}</option>`).join("")
    : '<option value="">No appeal cards</option>';

  if (draftSel) {
    draftSel.innerHTML = drafts.length
      ? drafts.map((i) => `<option value="${i.id}">Draft token #${i.id}</option>`).join("")
      : '<option value="">No draft tokens</option>';
  }
}

let medicalConsultOptions = [];

async function refreshMedicalConsultOptions() {
  const medicalTokSel = document.getElementById("medicalTokenSelect");
  if (!medicalTokSel) return;

  const { data, error } = await supabase.rpc("medical_list_available_consults", {
    p_club: null,
  });
  if (error) {
    // Fallback to inventory medical tokens only
    const medicals = inventory.filter(
      (i) => i.prize_type === "medical_token" && i.status === "available"
    );
    medicalConsultOptions = medicals.map((i) => ({
      key: i.metadata?.consult_id
        ? `consult:${i.metadata.consult_id}`
        : `prize:${i.id}`,
      consultId: i.metadata?.consult_id ? Number(i.metadata.consult_id) : null,
      inventoryId: Number(i.id),
      tier: Number(i.param_int) || 2,
      label:
        i.metadata?.label ||
        i.metadata?.consultancy_label ||
        `Specialist consult −${i.param_int} matches`,
    }));
  } else {
    medicalConsultOptions = (Array.isArray(data) ? data : []).map((t) => ({
      key: `consult:${t.consult_id}`,
      consultId: Number(t.consult_id),
      inventoryId: t.inventory_id != null ? Number(t.inventory_id) : null,
      tier: Number(t.param_int ?? t.matches_removed) || 2,
      label: t.label || t.consultancy_label || `Specialist consult (−${t.param_int})`,
    }));
  }

  medicalTokSel.innerHTML = medicalConsultOptions.length
    ? medicalConsultOptions
        .map((c) => `<option value="${c.key}">${c.label} (−${c.tier})</option>`)
        .join("")
    : '<option value="">No specialist consults available</option>';
}

async function loadInventory() {
  const { data, error } = await supabase.rpc("club_prize_inventory_state");
  if (error) {
    setStatus("❌ " + error.message + " — run competition_challenge_prize_packs SQL", "err");
    return;
  }
  inventory = data?.items || [];
  renderInventory();
  await refreshMedicalConsultOptions();
}

async function loadSuspensions() {
  const sel = document.getElementById("appealSuspensionSelect");
  const { data, error } = await supabase.rpc("club_appealable_red_suspensions");
  if (error) {
    sel.innerHTML = `<option value="">${error.message}</option>`;
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    sel.innerHTML = '<option value="">No active red-card bans</option>';
    return;
  }
  sel.innerHTML = rows
    .map(
      (s) =>
        `<option value="${s.suspension_id}">${s.player_name || s.player_id} (${s.pending_matches} left)</option>`
    )
    .join("");
}

async function loadMedicalInjuries() {
  const sel = document.getElementById("medicalInjurySelect");
  if (!sel) return;
  const { data, error } = await supabase.rpc("medical_room_state", { p_club: null });
  if (error) {
    sel.innerHTML = `<option value="">${error.message}</option>`;
    await refreshMedicalConsultOptions();
    return;
  }
  await refreshMedicalConsultOptions();

  if (!data?.has_doctor) {
    sel.innerHTML =
      '<option value="">Hire a club doctor in Medical Room first</option>';
    return;
  }
  const rows = (data?.active_injuries || []).filter((inj) => !inj.token_used);
  if (!rows.length) {
    sel.innerHTML = '<option value="">No injuries eligible for a consult</option>';
    return;
  }
  sel.innerHTML = rows
    .map((inj) => {
      const left =
        (Number(inj.matches_out_remaining) || 0) +
        (Number(inj.recovery_remaining) || 0);
      return `<option value="${inj.injury_id}">${inj.player_name || inj.player_id} — ${
        inj.label || "Injury"
      } (${left} left)</option>`;
    })
    .join("");
}

async function applyMedicalToken() {
  const raw = document.getElementById("medicalTokenSelect")?.value || "";
  const injuryId = Number(document.getElementById("medicalInjurySelect")?.value);
  const picked = medicalConsultOptions.find((c) => c.key === raw);
  if (!picked) {
    setStatus("Select a specialist consult.", "err");
    return;
  }
  if (!injuryId) {
    setStatus("Select an eligible injury.", "err");
    return;
  }
  if (
    !confirm(
      `Doctor refers this injury to:\n${picked.label}\n\n(−${picked.tier} matches; one consult per injury.)`
    )
  ) {
    return;
  }
  setStatus("Referring to specialist…");
  const payload = { p_injury_id: injuryId };
  if (picked.consultId) payload.p_consult_id = picked.consultId;
  else if (picked.inventoryId) payload.p_inventory_id = picked.inventoryId;
  else payload.p_prefer_specialist = true;

  const { data, error } = await supabase.rpc("medical_apply_specialist_token", payload);
  if (error) {
    setStatus("❌ " + error.message, "err");
    return;
  }
  setStatus(
    `✅ ${data?.label || picked.label}: removed ${data?.matches_removed ?? 0} match(es).`,
    "ok"
  );
  await loadInventory();
  await loadMedicalInjuries();
}

async function loadDraftReleaseOptions() {
  const sel = document.getElementById("draftReleasePlayerSelect");
  if (!sel) return;
  const { data, error } = await supabase.rpc("prize_draft_token_squad_options");
  if (error) {
    sel.innerHTML = `<option value="">${error.message}</option>`;
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  sel.innerHTML =
    '<option value="">— none —</option>' +
    rows
      .map(
        (p) =>
          `<option value="${p.player_id}">${p.name || p.player_id} · ${p.rating || "?"} · ${formatMoney(
            Number(p.market_value || 0)
          )}</option>`
      )
      .join("");
}

async function lockDiscount() {
  const id = Number(document.getElementById("discountTokenSelect").value);
  const kind = document.getElementById("discountContextKind").value;
  const ctxId = Number(document.getElementById("discountContextId").value);
  if (!id || !ctxId) {
    setStatus("Pick a token and enter a listing/auction ID.", "err");
    return;
  }
  setStatus("Locking…");
  const { error } = await supabase.rpc("prize_lock_fee_discount", {
    p_inventory_id: id,
    p_context_kind: kind,
    p_context_id: ctxId,
  });
  if (error) {
    setStatus("❌ " + error.message, "err");
    return;
  }
  setStatus("Discount locked.", "ok");
  await loadInventory();
}

async function unlockDiscount() {
  setStatus("Unlocking…");
  const { error } = await supabase.rpc("prize_unlock_fee_discount", {});
  if (error) {
    setStatus("❌ " + error.message, "err");
    return;
  }
  setStatus("Discount unlocked.", "ok");
  await loadInventory();
}

async function submitAppeal() {
  const inv = Number(document.getElementById("appealCardSelect").value);
  const sus = Number(document.getElementById("appealSuspensionSelect").value);
  const note = document.getElementById("appealNote").value;
  if (!inv || !sus) {
    setStatus("Select an appeal card and a suspension.", "err");
    return;
  }
  if (!confirm("Submit appeal? Card is held pending admin review (consumed if rejected).")) return;
  setStatus("Submitting…");
  const { error } = await supabase.rpc("prize_submit_suspension_appeal", {
    p_suspension_id: sus,
    p_inventory_id: inv,
    p_owner_note: note || null,
  });
  if (error) {
    setStatus("❌ " + error.message, "err");
    return;
  }
  setStatus("Appeal submitted for admin review.", "ok");
  await loadInventory();
  await loadSuspensions();
}

async function previewDraftToken() {
  const preview = document.getElementById("draftPreview");
  const signId = document.getElementById("draftSignPlayerId")?.value?.trim();
  const releaseId = document.getElementById("draftReleasePlayerSelect")?.value || null;
  if (!signId) {
    setStatus("Enter the Konami ID of the free agent to sign.", "err");
    return;
  }
  setStatus("Previewing…");
  const { data, error } = await supabase.rpc("prize_draft_token_preview", {
    p_sign_player_id: signId,
    p_release_player_id: releaseId || null,
  });
  if (error) {
    setStatus("❌ " + error.message, "err");
    if (preview) preview.textContent = "";
    return;
  }
  setStatus("");
  if (preview) {
    const needRel = data.needs_release ? "Yes — squad full" : "No";
    preview.innerHTML = `
      <b>${data.sign_player_name || signId}</b>
      ${data.sign_is_free_agent ? "(free agent)" : "<span style='color:#f88'>(NOT free agent)</span>"}
      · sign cost ${formatMoney(Number(data.sign_market_value || 0))}<br>
      Squad ${data.squad_count}/${data.squad_max} · release required: ${needRel}
      ${
        data.release_player_id
          ? ` · releasing ${data.release_player_name} for ${formatMoney(Number(data.release_market_value || 0))}`
          : ""
      }<br>
      Balance ${formatMoney(Number(data.balance || 0))} · net cash needed ${formatMoney(
        Number(data.net_cash_needed || 0)
      )}
      ${data.can_afford ? " · can afford" : " · <span style='color:#f88'>cannot afford</span>"}
      · tokens available: ${data.draft_tokens_available ?? 0}
    `;
  }
}

async function useDraftToken() {
  const inv = Number(document.getElementById("draftTokenSelect")?.value);
  const signId = document.getElementById("draftSignPlayerId")?.value?.trim();
  const releaseId = document.getElementById("draftReleasePlayerSelect")?.value || null;
  if (!inv) {
    setStatus("Select a draft token.", "err");
    return;
  }
  if (!signId) {
    setStatus("Enter the Konami ID of the free agent to sign.", "err");
    return;
  }
  if (
    !confirm(
      `Use draft token to sign player ${signId} at market value?` +
        (releaseId ? `\nAlso release player ${releaseId} at market value first.` : "")
    )
  ) {
    return;
  }
  setStatus("Signing…");
  const { data, error } = await supabase.rpc("prize_use_draft_token", {
    p_inventory_id: inv,
    p_sign_player_id: signId,
    p_release_player_id: releaseId || null,
  });
  if (error) {
    setStatus("❌ " + error.message + " — run competition_challenge_draft_token_prize.sql if needed", "err");
    return;
  }
  setStatus(
    `✅ Signed ${data?.signed_player_name || signId} for ${formatMoney(Number(data?.sign_fee || 0))}.`,
    "ok"
  );
  const preview = document.getElementById("draftPreview");
  if (preview) preview.textContent = "";
  document.getElementById("draftSignPlayerId").value = "";
  await loadInventory();
  await loadDraftReleaseOptions();
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const user = await getAuthUserFast();
  if (!user) {
    window.location = "login.html";
    return;
  }
  document.getElementById("lockDiscountBtn").onclick = lockDiscount;
  document.getElementById("unlockDiscountBtn").onclick = unlockDiscount;
  document.getElementById("submitAppealBtn").onclick = submitAppeal;
  document.getElementById("applyMedicalTokenBtn")?.addEventListener("click", applyMedicalToken);
  document.getElementById("draftPreviewBtn")?.addEventListener("click", previewDraftToken);
  document.getElementById("draftUseBtn")?.addEventListener("click", useDraftToken);
  await loadInventory();
  await loadSuspensions();
  await loadMedicalInjuries();
  await loadDraftReleaseOptions();
});
